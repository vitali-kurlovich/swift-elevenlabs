import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct FluidSpeechApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("FluidSpeech", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Audio…") { NotificationCenter.default.post(name: .openAudio, object: nil) }
                    .keyboardShortcut("o")
                Button(model.isRecording ? "Stop Recording" : "Record") { Task { await model.toggleRecording() } }
                    .keyboardShortcut("r")
                    .disabled(!model.isSetUp)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a worker that just died must fail with an error, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        // Needed when launched with `swift run` (no app bundle).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Files opened from Finder ("Open With", Dock icon) or `open -a FluidSpeech file.m4a`.
    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        // The window may not exist yet on a cold launch; give SwiftUI a moment to subscribe.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .openFiles, object: files)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

extension Notification.Name {
    static let openAudio = Notification.Name("FluidSpeech.openAudio")
    static let openFiles = Notification.Name("FluidSpeech.openFiles")
}

enum Export {
    static func timestamp(_ seconds: Double, srt: Bool = false) -> String {
        let total = max(0, seconds)
        let h = Int(total) / 3600, m = Int(total) / 60 % 60, s = Int(total) % 60
        if srt {
            let ms = Int((total - total.rounded(.down)) * 1000)
            return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
        }
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func srt(_ segments: [Segment]) -> String {
        segments.enumerated().map { index, segment in
            "\(index + 1)\n\(timestamp(segment.start, srt: true)) --> \(timestamp(segment.end, srt: true))\n\(segment.text)\n"
        }.joined(separator: "\n")
    }

    @MainActor
    static func save(_ item: TranscriptionItem) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (item.name as NSString).deletingPathExtension
        let srtType = UTType(filenameExtension: "srt") ?? .plainText
        panel.allowedContentTypes = [.plainText, srtType]
        let format = NSPopUpButton()
        format.addItems(withTitles: ["Plain text (.txt)", "Subtitles (.srt)"])
        let accessory = NSStackView(views: [NSTextField(labelWithString: "Format:"), format])
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, var url = panel.url else { return }
        let asSRT = format.indexOfSelectedItem == 1
        url = url.deletingPathExtension().appendingPathExtension(asSRT ? "srt" : "txt")
        let contents = asSRT ? srt(item.segments) : item.text + "\n"
        try? contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
