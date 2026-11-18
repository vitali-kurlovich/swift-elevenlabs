import Foundation

@main
enum Main {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "--transcribe":
            Task { @MainActor in exit(await CommandLineTool.run(Array(arguments.dropFirst()))) }
        case "--download":
            Task { @MainActor in exit(await CommandLineTool.download(Array(arguments.dropFirst()))) }
        default:
            return FluidSpeechApp.main()
        }
        dispatchMain()
    }
}

/// `FluidSpeech --transcribe [--full] [--clean] [--srt] FILE...`: same pipeline as the app, prints transcripts.
@MainActor
enum CommandLineTool {
    static func run(_ arguments: [String]) async -> Int32 {
        let variant: ModelVariant = arguments.contains("--full") ? .full : .eightBit
        let clean = arguments.contains("--clean")
        let srt = arguments.contains("--srt")
        let files = arguments.filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
        guard !files.isEmpty else {
            log("usage: FluidSpeech --transcribe [--full] [--clean] [--srt] FILE...")
            return 64
        }

        let environment = PythonEnvironment()
        if environment.state != .ready {
            log("Installing the Python environment…")
            await environment.install()
            guard environment.state == .ready else {
                log(environment.log.suffix(20).joined(separator: "\n"))
                log("Python setup failed: \(environment.state)")
                return 1
            }
        }
        let store = ModelStore()
        let missing = store.missingFiles(variant, cleanMode: clean)
        guard missing.isEmpty else {
            log("Missing model files: \(missing.joined(separator: ", ")). Download them in the app first.")
            return 1
        }

        let worker = WorkerProcess(python: environment.python, script: AppPaths.worker.appendingPathComponent("fluid_worker.py"))
        defer { worker.stop() }
        do {
            let hello = try await worker.start()
            log("mlx \(hello.mlx ?? "?"), parakeet-mlx \(hello.parakeetMLX ?? "?")")
            _ = try await worker.send(WorkerRequest(op: "load", modelDir: store.directory.path, bits: variant.bits, clean: clean))
            try AppPaths.ensure(AppPaths.scratch)
            for file in files {
                let raw = AppPaths.scratch.appendingPathComponent("\(UUID().uuidString).f32")
                defer { try? FileManager.default.removeItem(at: raw) }
                let duration = try await AudioDecoder.decode(file, to: raw)
                let reply = try await worker.send(WorkerRequest(op: "transcribe", path: raw.path, chunkDuration: 120))
                log("\(file.lastPathComponent): \(String(format: "%.1f", duration)) s audio in \(reply.seconds ?? 0) s")
                print(srt ? Export.srt(reply.sentences ?? []) : reply.text ?? "")
            }
            return 0
        } catch {
            log("error: \(error.localizedDescription)\n\(worker.recentErrors)")
            return 1
        }
    }

    /// `FluidSpeech --download [--full] [--clean]`: fetches the model files the app would download.
    static func download(_ arguments: [String]) async -> Int32 {
        let variant: ModelVariant = arguments.contains("--full") ? .full : .eightBit
        let store = ModelStore()
        store.fetch(variant, cleanMode: arguments.contains("--clean"))
        var last = ""
        while store.isDownloading {
            if let d = store.download {
                let line = "\(d.file) \(Int(d.fraction * 100))%"
                if line != last { log(line); last = line }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if let error = store.errorMessage { log(error); return 1 }
        log("Model files are in \(store.directory.path)")
        return 0
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
