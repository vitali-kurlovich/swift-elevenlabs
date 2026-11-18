import SwiftUI

struct SetupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Set up Fluid Speech Pro").font(.title2.weight(.semibold))
                    Text("Speech-to-text that runs on this Mac with MLX. Two one-time steps, then everything stays offline.")
                        .foregroundStyle(.secondary)
                }

                StepCard(number: 1, title: "Python runtime", done: model.environment.state == .ready) {
                    PythonStep()
                }
                StepCard(number: 2, title: "Model weights", done: model.models.isReady(model.variant, cleanMode: model.cleanMode)) {
                    ModelStep()
                }

                Text("Fluid Speech Pro by FluidVoice, CC BY 4.0. Based on NVIDIA Parakeet TDT 0.6B v3, run with parakeet-mlx.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(32)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { model.environment.refresh(); model.models.refresh() }
        .onChange(of: model.isSetUp) { _, ready in if ready { model.resume() } }
    }
}

private struct StepCard<Content: View>: View {
    var number: Int
    var title: String
    var done: Bool
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.2)).frame(width: 28, height: 28)
                if done {
                    Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.callout.weight(.semibold))
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                content
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct PythonStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let environment = model.environment
        VStack(alignment: .leading, spacing: 10) {
            switch environment.state {
            case .ready:
                Text("mlx and parakeet-mlx are installed.").foregroundStyle(.secondary)
            case .needsUV:
                Text("FluidSpeech uses **uv** to make a private Python environment. Install it, then check again:")
                Text("brew install uv")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button("Check Again") { environment.refresh() }
                    Link("Other ways to install uv", destination: URL(string: "https://docs.astral.sh/uv/getting-started/installation/")!)
                }
            case .needsInstall:
                Text("Installs Python 3.12, mlx and parakeet-mlx (about 300 MB) into FluidSpeech's own folder.")
                    .foregroundStyle(.secondary)
                Button("Install") { Task { await environment.install() } }
                    .buttonStyle(.borderedProminent)
            case .installing:
                ProgressView("Installing…").controlSize(.small)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Button("Try Again") { Task { await environment.install() } }
            }
            if !environment.log.isEmpty, environment.state != .ready {
                LogView(lines: environment.log)
            }
        }
    }
}

private struct ModelStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let store = model.models
        VStack(alignment: .leading, spacing: 10) {
            Picker("Weights", selection: $model.variant) {
                ForEach(ModelVariant.allCases) { variant in
                    VStack(alignment: .leading) {
                        Text(variant.title)
                        Text(variant.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(variant)
                }
            }
            .pickerStyle(.radioGroup)
            .disabled(store.isDownloading)

            Toggle("Also get clean mode (55 MB): drops filler words and repeated words", isOn: $model.cleanMode)
                .disabled(store.isDownloading)

            if let download = store.download {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: download.fraction)
                    HStack {
                        Text(download.file).font(.caption.monospaced())
                        Spacer()
                        Text("\(bytes(download.received)) of \(bytes(download.total))").font(.caption.monospacedDigit())
                        Button("Cancel") { store.cancel() }.controlSize(.small)
                    }
                    .foregroundStyle(.secondary)
                }
            } else {
                let missing = store.missingFiles(model.variant, cleanMode: model.cleanMode)
                if missing.isEmpty {
                    Text("Downloaded to Application Support.").foregroundStyle(.secondary)
                } else {
                    let total = missing.map(ModelRepo.approximateSize(of:)).reduce(0, +)
                    Button("Download \(bytes(total))") { store.fetch(model.variant, cleanMode: model.cleanMode) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let error = store.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Link("Model card on Hugging Face", destination: ModelRepo.pageURL).font(.callout)
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

struct LogView: View {
    var lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line).font(.caption.monospaced()).id(index)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 140)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: lines.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
        }
    }
}
