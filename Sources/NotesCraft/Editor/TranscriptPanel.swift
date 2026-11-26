import NotesCraftCore
import SwiftUI
import UIKit

/// What was said in the notebook's recordings, beside the page. The sentence
/// being played is highlighted; tap any sentence to hear it.
struct TranscriptPanel: View {
    @Bindable var model: EditorModel
    var onClose: () -> Void
    @State private var languages: [Locale] = []
    @State private var copied = false

    private var recording: Recording? { model.selectedRecording }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Theme.background)
        .task { languages = await SpeechEngine.supportedLocales() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(model.recordings) { rec in
                    Button {
                        model.selectedRecordingID = rec.id
                    } label: {
                        Label("\(rec.title) · \(rec.duration.clock)", systemImage: rec.id == recording?.id ? "checkmark" : "waveform")
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(recording?.title ?? "Transcript")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if model.recordings.count > 1 {
                        Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(Theme.ink3)
                    }
                }
            }
            .disabled(model.recordings.count < 2)
            .accessibilityLabel("Recording")
            Spacer(minLength: 4)
            if let recording {
                Menu {
                    if let transcript = recording.transcript {
                        Button {
                            UIPasteboard.general.string = transcript.text
                            copied = true
                            model.showToast("Transcript copied")
                        } label: {
                            Label("Copy transcript", systemImage: "doc.on.doc")
                        }
                    }
                    Menu {
                        ForEach(languages, id: \.identifier) { locale in
                            Button(SpeechEngine.name(locale)) {
                                model.transcribe(recording.id, locale: locale)
                            }
                        }
                    } label: {
                        Label(recording.transcript == nil ? "Transcribe in…" : "Transcribe again in…", systemImage: "globe")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 18, weight: .medium))
                        .frame(width: 36, height: 36)
                }
                .accessibilityLabel("Transcript options")
            }
            Button("Done", action: onClose)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let recording {
            if let status = model.transcriptionStatus[recording.id] {
                statusView(status, recording: recording)
            } else if let transcript = recording.transcript {
                lines(transcript, recording: recording)
            } else {
                message(symbol: "text.quote", title: "Not transcribed yet",
                        detail: "Turn what was said into text you can read and search. It happens on this iPad; nothing is uploaded.") {
                    Button("Transcribe") { model.transcribe(recording.id) }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            message(symbol: "waveform", title: "No recordings yet",
                    detail: "Record with the microphone button. Recordings are transcribed on this iPad when you stop.") { EmptyView() }
        }
    }

    @ViewBuilder
    private func statusView(_ status: TranscriptionStatus, recording: Recording) -> some View {
        switch status {
        case .waiting:
            message(symbol: "hourglass", title: "Waiting to transcribe", detail: "Another recording is being transcribed first.") {
                ProgressView()
            }
        case let .downloading(fraction):
            message(symbol: "arrow.down.circle", title: "Getting the speech model",
                    detail: "A one-time download from Apple for this language. Your recording stays on this iPad.") {
                ProgressView(value: fraction).frame(maxWidth: 200)
            }
        case let .working(fraction):
            message(symbol: "text.quote", title: "Transcribing on this iPad",
                    detail: "You can keep writing; the transcript appears here when it's ready.") {
                ProgressView(value: max(fraction, 0.02)).frame(maxWidth: 200)
            }
        case let .failed(reason):
            message(symbol: "exclamationmark.triangle", title: "Couldn't transcribe", detail: reason) {
                Button("Try again") { model.transcribe(recording.id) }
                    .buttonStyle(.bordered)
            }
        }
    }

    private func lines(_ transcript: Transcript, recording: Recording) -> some View {
        let playing = model.audio.playingID == recording.id
        let current = playing ? transcript.segmentIndex(at: model.audio.playTime) : nil
        return ScrollViewReader { proxy in
            List {
                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, segment in
                    Button {
                        model.playRecording(recording.id, at: segment.start)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(segment.start.clock)
                                .font(Theme.mono(11))
                                .foregroundStyle(index == current ? Theme.accent : Theme.ink3)
                                .frame(width: 42, alignment: .leading)
                            Text(highlighted(segment.text))
                                .font(.callout)
                                .foregroundStyle(Theme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .id(index)
                    .listRowBackground(index == current ? Theme.accent.opacity(0.14) : Color.clear)
                    .accessibilityLabel("\(segment.start.clock): \(segment.text)")
                    .accessibilityHint("Plays from here")
                }
            }
            .listStyle(.plain)
            .onChange(of: current) { _, index in
                guard let index else { return }
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(index, anchor: .center) }
            }
        }
    }

    /// The text with the current search words emphasized.
    private func highlighted(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let q = model.findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let regex = SearchMatching.regex(for: q) else { return out }
        for range in SearchMatching.ranges(of: regex, in: text) {
            guard let r = Range(range, in: text),
                  let lower = AttributedString.Index(r.lowerBound, within: out),
                  let upper = AttributedString.Index(r.upperBound, within: out) else { continue }
            out[lower ..< upper].backgroundColor = Theme.accent.opacity(0.25)
            out[lower ..< upper].font = .callout.weight(.semibold)
        }
        return out
    }

    private func message(symbol: String, title: String, detail: String, @ViewBuilder action: () -> some View) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(title).font(Theme.serif(20)).foregroundStyle(Theme.ink)
            Text(detail)
                .font(.footnote)
                .foregroundStyle(Theme.ink3)
                .multilineTextAlignment(.center)
            action().padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 20)
    }
}
