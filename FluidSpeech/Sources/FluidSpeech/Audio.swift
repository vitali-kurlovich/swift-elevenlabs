import AVFoundation
import Foundation

enum AudioDecoder {
    static let sampleRate = 16_000.0

    /// Decodes any audio or video file AVFoundation can read into raw little-endian float32 mono at 16 kHz,
    /// the format the worker reads directly. Returns the duration in seconds.
    static func decode(_ source: URL, to destination: URL) async throws -> Double {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw Failure("\(source.lastPathComponent) has no audio track.") }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure("Couldn't read \(source.lastPathComponent).") }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var bytes = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw Failure("Couldn't copy decoded audio (\(status)).") }
            try handle.write(contentsOf: data)
            bytes += length
        }
        if reader.status == .failed { throw reader.error ?? Failure("Decoding \(source.lastPathComponent) failed.") }
        let seconds = Double(bytes / MemoryLayout<Float>.size) / sampleRate
        guard seconds >= 0.05 else { throw Failure("\(source.lastPathComponent) is too short to transcribe.") }
        return seconds
    }
}

/// Microphone capture to a CAF file in the input device's native format. The tap runs on the audio thread,
/// so this type stays off the main actor and shares state through a lock.
final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var peak: Float = 0
    private var frames: AVAudioFramePosition = 0
    private var rate: Double = 48_000

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    func start(writingTo url: URL) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw Failure("No microphone input is available.") }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        lock.withLock {
            self.file = file
            self.frames = 0
            self.rate = format.sampleRate
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.receive(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock { file = nil }
    }

    /// Peak level since the last call (0...1) and seconds recorded so far.
    func poll() -> (level: Float, seconds: Double) {
        lock.withLock {
            defer { peak = 0 }
            return (peak, Double(frames) / rate)
        }
    }

    private func receive(_ buffer: AVAudioPCMBuffer) {
        var level: Float = 0
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) { level = max(level, abs(channel[i])) }
        }
        lock.withLock {
            try? file?.write(from: buffer)
            frames += AVAudioFramePosition(buffer.frameLength)
            peak = max(peak, level)
        }
    }
}
