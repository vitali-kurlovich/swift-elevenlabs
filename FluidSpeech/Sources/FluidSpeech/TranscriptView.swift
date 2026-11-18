import SwiftUI

struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    var item: TranscriptionItem
    @State private var mode = Mode.sentences

    enum Mode: String, CaseIterable { case sentences = "Sentences", text = "Text" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onDisappear { model.playback.stop() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if item.status == .done {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Button {
                    model.playback.toggle(item.source)
                } label: {
                    Image(systemName: isPlayingThis ? "pause.fill" : "play.fill")
                }
                .help("Play the audio")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy the transcript")
                Button {
                    Export.save(item)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Save as text or subtitles")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder private var content: some View {
        switch item.status {
        case .queued, .decoding:
            ProgressView(item.status == .queued ? "Waiting for the model…" : "Reading audio…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .transcribing(value):
            VStack(spacing: 12) {
                ProgressView(value: value > 0 ? value : nil) {
                    Text(progressLabel)
                }
                .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                Text("Transcription failed").font(.headline)
                ScrollView {
                    Text(message).font(.callout.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: 560, maxHeight: 200)
                Button("Try Again") { model.retry(item.id) }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done where item.text.isEmpty:
            Text("No speech found.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done:
            if mode == .text {
                ScrollView {
                    Text(item.text)
                        .font(.body)
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            } else {
                sentences
            }
        }
    }

    private var sentences: some View {
        ScrollViewReader { proxy in
            List(Array(item.segments.enumerated()), id: \.offset) { index, segment in
                SentenceRow(segment: segment, isCurrent: isCurrent(segment)) {
                    model.playback.play(item.source, from: segment.start)
                }
                .id(index)
            }
            .listStyle(.inset)
            .onChange(of: currentIndex) { _, index in
                if let index { withAnimation { proxy.scrollTo(index, anchor: .center) } }
            }
        }
    }

    private var isPlayingThis: Bool { model.playback.isPlaying && model.playback.url == item.source }

    private var currentIndex: Int? {
        guard isPlayingThis else { return nil }
        return item.segments.firstIndex(where: isCurrent)
    }

    private func isCurrent(_ segment: Segment) -> Bool {
        isPlayingThis && model.playback.time >= segment.start && model.playback.time < segment.end
    }

    private var progressLabel: String {
        if case .loading = model.engine { return "Loading the model…" }
        if case .starting = model.engine { return "Starting Python…" }
        return "Transcribing…"
    }

    private var summary: String {
        var parts: [String] = []
        if let duration = item.duration { parts.append(Export.timestamp(duration)) }
        if let seconds = item.processingSeconds, item.status == .done {
            var done = "transcribed in \(String(format: "%.1f", seconds)) s"
            if let duration = item.duration, seconds > 0 { done += " (\(Int(duration / seconds))× real time)" }
            parts.append(done)
        }
        if let variant = item.variant { parts.append(variant.title) }
        if item.cleanMode == true { parts.append("Clean mode") }
        parts.append(item.createdAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }
}

private struct SentenceRow: View {
    var segment: Segment
    var isCurrent: Bool
    var play: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(action: play) {
                Text(Export.timestamp(segment.start))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help("Play from here")
            Text(segment.text)
                .textSelection(.enabled)
                .foregroundStyle(segment.confidence < 0.6 ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
    }
}
