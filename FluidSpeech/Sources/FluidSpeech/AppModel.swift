import AVFoundation
import Foundation
import Observation

struct TranscriptionItem: Identifiable, Codable, Hashable {
    enum Status: Codable, Hashable {
        case queued
        case decoding
        case transcribing(Double)
        case done
        case failed(String)

        var isFinished: Bool {
            switch self {
            case .done, .failed: true
            default: false
            }
        }
    }

    var id = UUID()
    var source: URL
    var name: String
    var createdAt = Date()
    var isRecording = false
    var status: Status = .queued
    var duration: Double?
    var text = ""
    var segments: [Segment] = []
    var processingSeconds: Double?
    var variant: ModelVariant?
    var cleanMode: Bool?
}

@MainActor @Observable
final class AppModel {
    enum Engine: Equatable {
        case stopped
        case starting
        case loading
        case ready(String)
        case failed(String)
    }

    let environment = PythonEnvironment()
    let models = ModelStore()
    let playback = Playback()

    private(set) var items: [TranscriptionItem] = []
    var selection: TranscriptionItem.ID?
    private(set) var engine: Engine = .stopped

    private(set) var isRecording = false
    private(set) var recordingLevel: Float = 0
    private(set) var recordingSeconds: Double = 0
    var alert: String?

    var variant: ModelVariant {
        didSet { UserDefaults.standard.set(variant.rawValue, forKey: "variant") }
    }
    var cleanMode: Bool {
        didSet { UserDefaults.standard.set(cleanMode, forKey: "cleanMode") }
    }
    /// Files longer than this are transcribed in overlapping chunks (seconds; 0 turns chunking off).
    var chunkDuration: Double {
        didSet { UserDefaults.standard.set(chunkDuration, forKey: "chunkDuration") }
    }

    @ObservationIgnored private var worker: WorkerProcess?
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var capture: MicrophoneCapture?
    @ObservationIgnored private var captureURL: URL?
    @ObservationIgnored private var meter: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        variant = defaults.string(forKey: "variant").flatMap(ModelVariant.init(rawValue:)) ?? .eightBit
        cleanMode = defaults.bool(forKey: "cleanMode")
        chunkDuration = defaults.object(forKey: "chunkDuration") as? Double ?? 120
        loadHistory()
    }

    var isSetUp: Bool { environment.state == .ready && models.isReady(variant, cleanMode: cleanMode) }
    var isBusy: Bool { items.contains { !$0.status.isFinished } }

    subscript(id: TranscriptionItem.ID) -> TranscriptionItem? { items.first { $0.id == id } }

    // MARK: Adding work

    func add(_ urls: [URL]) {
        let new = urls.map { TranscriptionItem(source: $0, name: $0.lastPathComponent) }
        guard !new.isEmpty else { return }
        items.insert(contentsOf: new.reversed(), at: 0)
        selection = new.first?.id
        saveHistory()
        runQueue()
    }

    func retry(_ id: TranscriptionItem.ID) {
        update(id) { item in
            item.status = .queued
            item.text = ""
            item.segments = []
        }
        runQueue()
    }

    func remove(_ id: TranscriptionItem.ID) {
        guard let item = self[id], item.status.isFinished else { return }
        if item.isRecording { try? FileManager.default.removeItem(at: item.source) }
        items.removeAll { $0.id == id }
        if selection == id { selection = items.first?.id }
        saveHistory()
    }

    // MARK: Recording

    func toggleRecording() async {
        if isRecording { return finishRecording() }
        guard await MicrophoneCapture.requestAccess() else {
            alert = "FluidSpeech doesn't have microphone access. Turn it on in System Settings → Privacy & Security → Microphone."
            return
        }
        do {
            try AppPaths.ensure(AppPaths.recordings)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let url = AppPaths.recordings.appendingPathComponent("Recording \(formatter.string(from: Date())).caf")
            let capture = MicrophoneCapture()
            try capture.start(writingTo: url)
            self.capture = capture
            captureURL = url
            isRecording = true
            meter = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    guard let self, let capture = self.capture else { return }
                    let (level, seconds) = capture.poll()
                    self.recordingLevel = level
                    self.recordingSeconds = seconds
                }
            }
        } catch {
            alert = "Couldn't start recording: \(error.localizedDescription)"
        }
    }

    private func finishRecording() {
        meter?.cancel()
        capture?.stop()
        capture = nil
        isRecording = false
        recordingLevel = 0
        guard let url = captureURL else { return }
        captureURL = nil
        var item = TranscriptionItem(source: url, name: url.deletingPathExtension().lastPathComponent)
        item.isRecording = true
        items.insert(item, at: 0)
        selection = item.id
        saveHistory()
        runQueue()
    }

    // MARK: Engine

    func stopEngine() {
        worker?.stop()
        worker = nil
        engine = .stopped
    }

    private func runQueue() {
        guard queue == nil, isSetUp else { return }
        queue = Task {
            while let item = items.last(where: { $0.status == .queued }) {
                await process(item)
            }
            queue = nil
        }
    }

    /// Called when setup finishes, so anything dropped in during setup starts.
    func resume() { runQueue() }

    private func process(_ item: TranscriptionItem) async {
        let id = item.id
        let variant = variant, cleanMode = cleanMode
        do {
            update(id) { $0.status = .decoding }
            try AppPaths.ensure(AppPaths.scratch)
            let raw = AppPaths.scratch.appendingPathComponent("\(id.uuidString).f32")
            defer { try? FileManager.default.removeItem(at: raw) }

            var audioPath = raw.path
            do {
                let duration = try await AudioDecoder.decode(item.source, to: raw)
                update(id) { $0.duration = duration }
            } catch {
                // Formats AVFoundation can't open (Ogg, WebM, …) go to parakeet-mlx's ffmpeg reader if it's installed.
                guard Subprocess.find("ffmpeg") != nil else { throw error }
                audioPath = item.source.path
            }

            update(id) { $0.status = .transcribing(0) }
            let worker = try await readyWorker(variant: variant, cleanMode: cleanMode)
            let chunk = chunkDuration > 0 ? chunkDuration : nil
            let reply = try await worker.send(WorkerRequest(op: "transcribe", path: audioPath, chunkDuration: chunk)) { [weak self] value in
                Task { @MainActor in
                    self?.update(id) { item in
                        if case .transcribing = item.status { item.status = .transcribing(value) }
                    }
                }
            }
            update(id) { item in
                item.status = .done
                item.text = reply.text ?? ""
                item.segments = reply.sentences ?? []
                item.processingSeconds = reply.seconds
                item.variant = variant
                item.cleanMode = cleanMode
            }
        } catch {
            update(id) { $0.status = .failed(error.localizedDescription) }
        }
        saveHistory()
    }

    private func readyWorker(variant: ModelVariant, cleanMode: Bool) async throws -> WorkerProcess {
        let worker: WorkerProcess
        if let running = self.worker, running.isRunning {
            worker = running
        } else {
            engine = .starting
            let started = WorkerProcess(python: environment.python, script: AppPaths.worker.appendingPathComponent("fluid_worker.py"))
            started.onExit = { [weak self, weak started] reason in
                Task { @MainActor in
                    guard let self, self.worker === started else { return }
                    self.worker = nil
                    self.engine = .failed(reason)
                }
            }
            self.worker = started
            do {
                _ = try await started.start()
            } catch {
                engine = .failed(error.localizedDescription)
                throw error
            }
            worker = started
        }
        engine = .loading
        do {
            _ = try await worker.send(WorkerRequest(op: "load", modelDir: models.directory.path, bits: variant.bits, clean: cleanMode))
        } catch {
            engine = .failed(error.localizedDescription)
            throw error
        }
        engine = .ready("\(variant.title)\(cleanMode ? " · Clean" : "")")
        return worker
    }

    // MARK: State

    private func update(_ id: TranscriptionItem.ID, _ change: (inout TranscriptionItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: AppPaths.history),
              let saved = try? JSONDecoder().decode([TranscriptionItem].self, from: data) else { return }
        items = saved.map { item in
            var item = item
            if !item.status.isFinished { item.status = .failed("Interrupted when the app quit.") }
            return item
        }
        selection = items.first?.id
    }

    private func saveHistory() {
        try? AppPaths.ensure(AppPaths.support)
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: AppPaths.history, options: .atomic)
    }
}

/// Plays a transcript's source so a sentence can be heard from where it starts.
@MainActor @Observable
final class Playback {
    private(set) var url: URL?
    private(set) var time: Double = 0
    private(set) var isPlaying = false

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var observer: Any?

    func play(_ url: URL, from start: Double) {
        if self.url != url { load(url) }
        player?.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player?.play()
        isPlaying = true
    }

    func toggle(_ url: URL) {
        if self.url != url { return play(url, from: 0) }
        if isPlaying { player?.pause() } else { player?.play() }
        isPlaying.toggle()
    }

    func stop() {
        player?.pause()
        isPlaying = false
    }

    private func load(_ url: URL) {
        if let observer { player?.removeTimeObserver(observer) }
        let player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = time.seconds
                if let item = self.player?.currentItem, time >= item.duration { self.isPlaying = false }
            }
        }
        self.player = player
        self.url = url
        time = 0
    }
}
