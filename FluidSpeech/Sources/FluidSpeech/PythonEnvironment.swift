import Foundation
import Observation

/// A private Python environment (made with uv) holding mlx and parakeet-mlx.
@MainActor @Observable
final class PythonEnvironment {
    enum State: Equatable {
        case needsUV
        case needsInstall
        case installing
        case ready
        case failed(String)
    }

    private(set) var state: State = .needsInstall
    private(set) var log: [String] = []
    private(set) var uv: URL?

    let directory = AppPaths.pythonEnvironment
    var python: URL { directory.appendingPathComponent("bin/python") }

    private var marker: URL { directory.appendingPathComponent(".fluidspeech-requirements") }
    private var requirementsFile: URL { AppPaths.worker.appendingPathComponent("requirements.txt") }
    private var requirements: String { (try? String(contentsOf: requirementsFile, encoding: .utf8)) ?? "" }

    init() { refresh() }

    func refresh() {
        guard state != .installing else { return }
        uv = Subprocess.find("uv")
        let installed = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
        if FileManager.default.isExecutableFile(atPath: python.path), !requirements.isEmpty, installed == requirements {
            state = .ready
        } else {
            state = uv == nil ? .needsUV : .needsInstall
        }
    }

    func install() async {
        refresh()
        guard let uv, state != .ready, state != .installing else { return }
        state = .installing
        log = []
        let append: @Sendable (String) -> Void = { [weak self] line in Task { @MainActor in self?.append(line) } }
        do {
            try AppPaths.ensure(AppPaths.support)
            append("$ uv venv --python 3.12")
            var status = try await Subprocess.run(uv, ["venv", "--clear", "--python", "3.12", directory.path], onLine: append)
            guard status == 0 else { throw Failure("uv venv exited with status \(status)") }
            append("$ uv pip install -r requirements.txt")
            status = try await Subprocess.run(uv, ["pip", "install", "--python", python.path, "-r", requirementsFile.path], onLine: append)
            guard status == 0 else { throw Failure("uv pip install exited with status \(status)") }
            try requirements.write(to: marker, atomically: true, encoding: .utf8)
            state = .ready
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
        refresh()
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }
}

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
