import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Transcription") {
                Picker("Model weights", selection: $model.variant) {
                    ForEach(ModelVariant.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Clean mode", isOn: $model.cleanMode)
                Picker("Long files", selection: $model.chunkDuration) {
                    Text("Whole file at once").tag(0.0)
                    Text("1-minute chunks").tag(60.0)
                    Text("2-minute chunks").tag(120.0)
                    Text("5-minute chunks").tag(300.0)
                }
                Text("Chunks overlap by 15 seconds and are merged. Smaller chunks use less memory.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(model.isBusy)

            Section("Storage") {
                ForEach(ModelRepo.files(for: .full, cleanMode: true) + [ModelVariant.eightBit.weightsFile], id: \.self) { file in
                    if model.models.presentFiles.contains(file), file != ModelRepo.configFile {
                        LabeledContent(file) {
                            HStack {
                                Text(ByteCountFormatter.string(fromByteCount: model.models.size(of: file) ?? 0, countStyle: .file))
                                    .foregroundStyle(.secondary)
                                Button("Delete", role: .destructive) {
                                    model.stopEngine()
                                    model.models.delete(file)
                                }
                                .disabled(model.isBusy)
                            }
                        }
                    }
                }
                HStack {
                    Button("Show in Finder") {
                        try? AppPaths.ensure(AppPaths.support)
                        NSWorkspace.shared.open(AppPaths.support)
                    }
                    Button("Reinstall Python Environment") {
                        model.stopEngine()
                        model.environment.remove()
                    }
                    .disabled(model.isBusy)
                }
            }

            Section("Engine") {
                LabeledContent("Status", value: engineText)
                Button("Unload Model") { model.stopEngine() }
                    .disabled(model.isBusy || model.engine == .stopped)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.models.refresh() }
    }

    private var engineText: String {
        switch model.engine {
        case .stopped: "Not running"
        case .starting: "Starting"
        case .loading: "Loading model"
        case let .ready(name): "Loaded: \(name)"
        case let .failed(reason): reason
        }
    }
}
