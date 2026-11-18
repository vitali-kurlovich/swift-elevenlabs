import Foundation
import Observation

/// Downloads and tracks the model files in Application Support.
@MainActor @Observable
final class ModelStore {
    struct Download: Equatable {
        var file: String
        var received: Int64
        var total: Int64
        var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }
    }

    private(set) var presentFiles: Set<String> = []
    private(set) var download: Download?
    var errorMessage: String?

    @ObservationIgnored private let downloader = FileDownloader()
    @ObservationIgnored private var task: Task<Void, Never>?

    let directory = AppPaths.models

    init() { refresh() }

    var isDownloading: Bool { download != nil }

    func refresh() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        presentFiles = Set(names.filter { !$0.hasSuffix(".part") })
    }

    func missingFiles(_ variant: ModelVariant, cleanMode: Bool) -> [String] {
        ModelRepo.files(for: variant, cleanMode: cleanMode).filter { !presentFiles.contains($0) }
    }

    func isReady(_ variant: ModelVariant, cleanMode: Bool) -> Bool {
        missingFiles(variant, cleanMode: cleanMode).isEmpty
    }

    func size(of file: String) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(file).path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    func fetch(_ variant: ModelVariant, cleanMode: Bool) {
        guard task == nil else { return }
        let files = missingFiles(variant, cleanMode: cleanMode)
        guard !files.isEmpty else { return }
        errorMessage = nil
        download = Download(file: files[0], received: 0, total: ModelRepo.approximateSize(of: files[0]))
        task = Task {
            defer { task = nil; download = nil; refresh() }
            do {
                try AppPaths.ensure(directory)
                for file in files {
                    download = Download(file: file, received: 0, total: ModelRepo.approximateSize(of: file))
                    try await downloader.download(ModelRepo.url(for: file), to: directory.appendingPathComponent(file)) { received, total in
                        Task { @MainActor in
                            self.download = Download(file: file, received: received, total: total > 0 ? total : ModelRepo.approximateSize(of: file))
                        }
                    }
                    refresh()
                }
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                errorMessage = "Download failed: \(error.localizedDescription)"
            }
        }
    }

    func cancel() {
        downloader.cancel()
        task?.cancel()
    }

    func delete(_ file: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        refresh()
    }
}

/// URLSession download with byte progress. The finished file is moved into place before the call returns.
final class FileDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private struct Job {
        let destination: URL
        let progress: @Sendable (Int64, Int64) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    private var tasks: [URLSessionTask] = []
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = session.downloadTask(with: url)
            lock.withLock {
                jobs[task.taskIdentifier] = Job(destination: destination, progress: progress, continuation: continuation)
                tasks.append(task)
            }
            task.resume()
        }
    }

    func cancel() {
        let running = lock.withLock { tasks }
        running.forEach { $0.cancel() }
    }

    private func finish(_ task: URLSessionTask, _ result: Result<Void, Error>) {
        let job = lock.withLock { () -> Job? in
            tasks.removeAll { $0 === task }
            return jobs.removeValue(forKey: task.taskIdentifier)
        }
        job?.continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let job = lock.withLock { jobs[downloadTask.taskIdentifier] }
        job?.progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = lock.withLock({ jobs[downloadTask.taskIdentifier] }) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            finish(downloadTask, .failure(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(status)"])))
            return
        }
        do {
            let fm = FileManager.default
            try? fm.removeItem(at: job.destination)
            try fm.moveItem(at: location, to: job.destination)
            finish(downloadTask, .success(()))
        } catch {
            finish(downloadTask, .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(task, .failure(error)) }
    }
}
