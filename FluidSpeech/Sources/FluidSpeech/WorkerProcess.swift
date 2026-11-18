import Foundation

struct WorkerRequest: Encodable, Sendable {
    var id = 0
    var op: String
    var modelDir: String?
    var bits: Int?
    var clean: Bool?
    var path: String?
    var chunkDuration: Double?

    enum CodingKeys: String, CodingKey {
        case id, op, bits, clean, path
        case modelDir = "model_dir"
        case chunkDuration = "chunk_duration"
    }
}

struct Segment: Codable, Hashable, Sendable {
    var text: String
    var start: Double
    var end: Double
    var confidence: Double
}

struct WorkerReply: Decodable, Sendable {
    var id: Int?
    var type: String
    var value: Double?
    var message: String?
    var text: String?
    var seconds: Double?
    var sentences: [Segment]?
    var cached: Bool?
    var mlx: String?
    var parakeetMLX: String?

    enum CodingKeys: String, CodingKey {
        case id, type, value, message, text, seconds, sentences, cached, mlx
        case parakeetMLX = "parakeet_mlx"
    }
}

/// The long-lived Python process that holds the model. Requests run one after another in the worker.
final class WorkerProcess: @unchecked Sendable {
    private struct Pending {
        let continuation: CheckedContinuation<WorkerReply, Error>
        let progress: (@Sendable (Double) -> Void)?
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: Pending] = [:]
    private var stderrTail: [String] = []
    private var exited = false

    /// Called once, off the main thread, with a description of why the worker stopped.
    var onExit: (@Sendable (String) -> Void)?

    init(python: URL, script: URL) {
        process.executableURL = python
        process.arguments = ["-I", script.path]
        process.environment = Subprocess.environment
        process.currentDirectoryURL = AppPaths.support
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    var isRunning: Bool { lock.withLock { !exited } && process.isRunning }

    /// Launches Python and waits for the worker's hello line (imports take a few seconds).
    func start() async throws -> WorkerReply {
        let stdoutLines = LineSplitter { [weak self] line in self?.handle(line) }
        let stderrLines = LineSplitter { [weak self] line in self?.remember(line) }
        output.fileHandleForReading.readabilityHandler = { stdoutLines.feed($0.availableData) }
        errors.fileHandleForReading.readabilityHandler = { stderrLines.feed($0.availableData) }
        process.terminationHandler = { [weak self] process in self?.terminated(status: process.terminationStatus) }

        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[0] = Pending(continuation: continuation, progress: nil) }
            do {
                try process.run()
            } catch {
                _ = lock.withLock { pending.removeValue(forKey: 0) }
                continuation.resume(throwing: error)
            }
        }
    }

    func send(_ request: WorkerRequest, progress: (@Sendable (Double) -> Void)? = nil) async throws -> WorkerReply {
        var request = request
        let reply = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WorkerReply, Error>) in
            let failure: String? = lock.withLock {
                if exited { return "The transcription worker isn't running." }
                request.id = nextID
                nextID += 1
                pending[request.id] = Pending(continuation: continuation, progress: progress)
                return nil
            }
            if let failure { return continuation.resume(throwing: Failure(failure)) }
            do {
                var line = try JSONEncoder().encode(request)
                line.append(0x0A)
                try input.fileHandleForWriting.write(contentsOf: line)
            } catch {
                if let job = lock.withLock({ pending.removeValue(forKey: request.id) }) {
                    job.continuation.resume(throwing: error)
                }
            }
        }
        if reply.type == "error" { throw Failure(reply.message ?? "Unknown worker error") }
        return reply
    }

    func stop() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    var recentErrors: String { lock.withLock { stderrTail.suffix(12).joined(separator: "\n") } }

    private func handle(_ line: String) {
        guard let reply = try? JSONDecoder().decode(WorkerReply.self, from: Data(line.utf8)) else {
            remember(line)
            return
        }
        let id = reply.id ?? -1
        if reply.type == "progress" {
            let job = lock.withLock { pending[id] }
            if let value = reply.value { job?.progress?(value) }
            return
        }
        lock.withLock { pending.removeValue(forKey: id) }?.continuation.resume(returning: reply)
    }

    private func remember(_ line: String) {
        lock.withLock {
            stderrTail.append(line)
            if stderrTail.count > 200 { stderrTail.removeFirst(stderrTail.count - 200) }
        }
    }

    private func terminated(status: Int32) {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        let (jobs, tail) = lock.withLock { () -> ([Pending], String) in
            exited = true
            defer { pending.removeAll() }
            return (Array(pending.values), stderrTail.suffix(8).joined(separator: "\n"))
        }
        let reason = "The transcription worker stopped (status \(status))." + (tail.isEmpty ? "" : "\n\n\(tail)")
        jobs.forEach { $0.continuation.resume(throwing: Failure(reason)) }
        onExit?(reason)
    }
}
