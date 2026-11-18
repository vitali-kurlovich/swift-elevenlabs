import Foundation

enum Subprocess {
    /// GUI apps start with a minimal PATH; add the usual tool locations (uv, Homebrew's ffmpeg).
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.cargo/bin"]
        let current = env["PATH"].map { $0.split(separator: ":").map(String.init) } ?? ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = (extra + current).reduced().joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        return env
    }

    static func find(_ tool: String) -> URL? {
        for directory in environment["PATH", default: ""].split(separator: ":") {
            let url = URL(fileURLWithPath: String(directory)).appendingPathComponent(tool)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// Runs a tool to completion, reporting stdout and stderr line by line.
    static func run(_ executable: URL, _ arguments: [String], onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let splitter = LineSplitter(onLine)
        pipe.fileHandleForReading.readabilityHandler = { handle in splitter.feed(handle.availableData) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    splitter.feed(pipe.fileHandleForReading.readDataToEndOfFile())
                    splitter.flush()
                    continuation.resume(returning: process.terminationStatus)
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
    }
}

/// Splits a byte stream into lines (`\n` or `\r`, so progress bars come through too).
final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void

    init(_ onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [String] = lock.withLock {
            buffer.append(data)
            var out: [String] = []
            while let index = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = buffer[buffer.startIndex..<index]
                buffer.removeSubrange(buffer.startIndex...index)
                if !line.isEmpty { out.append(String(decoding: line, as: UTF8.self)) }
            }
            return out
        }
        lines.forEach(onLine)
    }

    func flush() {
        let rest: Data = lock.withLock { defer { buffer.removeAll() }; return buffer }
        if !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
    }
}

private extension Array where Element == String {
    func reduced() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
