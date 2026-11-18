import Foundation

/// The Hugging Face repository this app runs, pinned to the revision the bundled loader script was copied from.
enum ModelRepo {
    static let id = "FluidVoice-Labs/fluid-speech-pro-mlx"
    static let revision = "aeb1d4e43487586b15d86c0a1dd4511e1cf6b7a0"
    static let configFile = "config.json"
    static let cleanModeFile = "clean-mode.safetensors"
    static let pageURL = URL(string: "https://huggingface.co/\(id)")!

    static func url(for file: String) -> URL {
        URL(string: "https://huggingface.co/\(id)/resolve/\(revision)/\(file)")!
    }

    static func files(for variant: ModelVariant, cleanMode: Bool) -> [String] {
        [configFile, variant.weightsFile] + (cleanMode ? [cleanModeFile] : [])
    }

    static func approximateSize(of file: String) -> Int64 {
        switch file {
        case ModelVariant.eightBit.weightsFile: 751_000_000
        case ModelVariant.full.weightsFile: 2_520_000_000
        case cleanModeFile: 55_000_000
        default: 300_000
        }
    }
}

enum ModelVariant: String, CaseIterable, Identifiable, Codable, Sendable {
    case eightBit = "8bit"
    case full = "fp32"

    var id: String { rawValue }

    var weightsFile: String {
        switch self {
        case .eightBit: "model.8bit.safetensors"
        case .full: "model.safetensors"
        }
    }

    /// Passed to `fluid_speech_mlx.load(bits:)`; nil loads the full-precision weights.
    var bits: Int? {
        switch self {
        case .eightBit: 8
        case .full: nil
        }
    }

    var title: String {
        switch self {
        case .eightBit: "8-bit"
        case .full: "Full precision"
        }
    }

    var detail: String {
        switch self {
        case .eightBit: "751 MB download, faster, less memory"
        case .full: "2.5 GB download, closest to the reference model"
        }
    }
}

enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FluidSpeech", isDirectory: true)
    }()

    static let models = support.appendingPathComponent("models/\(ModelRepo.revision)", isDirectory: true)
    static let pythonEnvironment = support.appendingPathComponent("python", isDirectory: true)
    static let recordings = support.appendingPathComponent("Recordings", isDirectory: true)
    static let history = support.appendingPathComponent("history.json")
    static let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("FluidSpeech", isDirectory: true)

    /// `Contents/Resources/Worker` in the built app; the source folder when run with `swift run`.
    static let worker: URL = {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Worker", isDirectory: true),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("fluid_worker.py").path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Worker", isDirectory: true)
    }()

    static func ensure(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
