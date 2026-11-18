import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var importing = false
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            Group {
                if !model.isSetUp {
                    SetupView()
                } else if let id = model.selection, let item = model[id] {
                    TranscriptView(item: item)
                } else {
                    EmptyStateView(openFiles: { importing = true })
                }
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
        }
        .toolbar { toolbar }
        .navigationSubtitle(EngineBadge.label(model))
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            model.add(files)
            return !files.isEmpty
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .movie], allowsMultipleSelection: true) { result in
            if case let .success(urls) = result { model.add(urls) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAudio)) { _ in importing = true }
        .onReceive(NotificationCenter.default.publisher(for: .openFiles)) { note in
            model.add(note.object as? [URL] ?? [])
        }
        .alert("FluidSpeech", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        @Bindable var model = model
        ToolbarItemGroup {
            Menu {
                Picker("Model", selection: $model.variant) {
                    ForEach(ModelVariant.allCases) { Text("\($0.title) — \($0.detail)").tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(model.variant.title, systemImage: "cpu")
                    .labelStyle(.titleAndIcon)
            }
            .fixedSize()
            .help("Model weights")
            .disabled(model.isBusy)

            Toggle(isOn: $model.cleanMode) {
                Label("Clean mode", systemImage: "wand.and.stars")
            }
            .help("Clean mode drops filler words (“um”, “uh”) and repeated words. Don't use it where you need an exact record.")
            .disabled(model.isBusy)

            Button {
                importing = true
            } label: {
                Label("Open Audio", systemImage: "doc.badge.plus")
            }
            .help("Transcribe audio or video files (⌘O)")

            RecordButton()
        }
    }
}

struct RecordButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            Task { await model.toggleRecording() }
        } label: {
            if model.isRecording {
                Label {
                    Text("Stop")
                } icon: {
                    Image(systemName: "stop.circle.fill").foregroundStyle(.red)
                }
                .labelStyle(.titleAndIcon)
                .overlay(alignment: .bottom) {
                    LevelBar(level: model.recordingLevel).offset(y: 6)
                }
            } else {
                Label("Record", systemImage: "mic.circle")
            }
        }
        .help(model.isRecording ? "Stop and transcribe (⌘R)" : "Record from the microphone (⌘R)")
        .disabled(!model.isSetUp)
    }
}

private struct LevelBar: View {
    var level: Float
    var body: some View {
        Capsule()
            .fill(.red.opacity(0.8))
            .frame(width: max(2, CGFloat(min(level, 1)) * 40), height: 2)
            .animation(.linear(duration: 0.05), value: level)
    }
}

enum EngineBadge {
    @MainActor static func label(_ model: AppModel) -> String {
        if model.isRecording { return "Recording \(Export.timestamp(model.recordingSeconds))" }
        if !model.isSetUp { return "Setup" }
        switch model.engine {
        case .stopped: return "Ready"
        case .starting: return "Starting Python…"
        case .loading: return "Loading model…"
        case let .ready(name): return "Loaded · \(name)"
        case .failed: return "Worker stopped, restarts on next file"
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            ForEach(model.items) { item in
                SidebarRow(item: item)
                    .tag(item.id)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.source]) }
                        Button("Transcribe Again") { model.retry(item.id) }
                            .disabled(!item.status.isFinished || !model.isSetUp)
                        Divider()
                        Button(item.isRecording ? "Delete Recording" : "Remove", role: .destructive) { model.remove(item.id) }
                            .disabled(!item.status.isFinished)
                    }
            }
        }
        .overlay {
            if model.items.isEmpty {
                Text("Transcripts appear here").foregroundStyle(.tertiary)
            }
        }
    }
}

private struct SidebarRow: View {
    var item: TranscriptionItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isRecording ? "mic.fill" : "waveform")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1).truncationMode(.middle)
                status
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var status: some View {
        switch item.status {
        case .queued:
            Text("Waiting…").font(.caption).foregroundStyle(.secondary)
        case .decoding:
            Text("Reading audio…").font(.caption).foregroundStyle(.secondary)
        case let .transcribing(value):
            ProgressView(value: value > 0 ? value : nil).controlSize(.small)
        case .done:
            Text(item.text.isEmpty ? "No speech found" : item.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
        }
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model
    var openFiles: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop audio or video here").font(.title2.weight(.semibold))
            Text("Speech in English and 24 other European languages, transcribed on this Mac.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Audio…", action: openFiles)
                Button("Record") { Task { await model.toggleRecording() } }
            }
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
