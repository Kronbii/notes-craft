import NotesCraftCore
import SwiftUI

/// Playback controls for the notebook's recordings.
struct AudioBar: View {
    @Bindable var model: EditorModel
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @Environment(\.horizontalSizeClass) private var hSize

    var body: some View {
        let audio = model.audio
        let recording = model.selectedRecording
        let isThis = recording.map { audio.playingID == $0.id } ?? false
        let duration = isThis ? max(audio.playDuration, 0.1) : (recording?.duration ?? 0)
        let time = scrubbing ? scrubValue : (isThis ? audio.playTime : 0)

        HStack(spacing: 10) {
            Menu {
                ForEach(model.recordings) { rec in
                    Button {
                        model.selectedRecordingID = rec.id
                        model.play(rec)
                    } label: {
                        Label("\(rec.title) · \(rec.duration.clock)", systemImage: rec.id == recording?.id ? "checkmark" : "waveform")
                    }
                }
                Divider()
                Button {
                    model.sheet = .recordings
                } label: {
                    Label("Manage recordings…", systemImage: "list.bullet")
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                    if hSize != .compact {
                        Text(recording?.title ?? "No recording")
                            .lineLimit(1)
                            .frame(maxWidth: 150, alignment: .leading)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
            }

            if hSize != .compact {
            Button {
                audio.skip(-15)
            } label: {
                Image(systemName: "gobackward.15")
            }
            .buttonStyle(IconButtonStyle(size: 34))
            .disabled(!isThis)
            .accessibilityLabel("Back 15 seconds")
            }

            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: isThis && audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .bold))
            }
            .buttonStyle(IconButtonStyle(isSelected: true, size: 40))
            .disabled(recording == nil)
            .accessibilityLabel(isThis && audio.isPlaying ? "Pause" : "Play")

            if hSize != .compact {
            Button {
                audio.skip(15)
            } label: {
                Image(systemName: "goforward.15")
            }
            .buttonStyle(IconButtonStyle(size: 34))
            .disabled(!isThis)
            .accessibilityLabel("Forward 15 seconds")
            }

            Text(time.clock)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.ink2)
                .frame(width: hSize == .compact ? 40 : 52, alignment: .trailing)
            Slider(value: Binding(get: { min(time, duration) }, set: { v in
                scrubValue = v
                if !scrubbing { scrubbing = true }
            }), in: 0 ... max(duration, 0.1)) { editing in
                if !editing {
                    scrubbing = false
                    if isThis { audio.seek(to: scrubValue) } else if let recording { model.play(recording); audio.seek(to: scrubValue) }
                }
            }
            .frame(minWidth: 80)
            if hSize != .compact {
                Text(duration.clock)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 52, alignment: .leading)
            }

            Menu {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                    Button {
                        audio.rate = Float(r)
                    } label: {
                        Label(rateLabel(r), systemImage: abs(Double(audio.rate) - r) < 0.01 ? "checkmark" : "")
                    }
                }
            } label: {
                Text(rateLabel(Double(audio.rate)))
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 46, height: 30)
                    .background(Theme.hair, in: Capsule())
            }
            .accessibilityLabel("Playback speed")

            Button {
                withAnimation(.spring(duration: 0.3)) { model.showTranscript.toggle() }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "text.quote")
                    if let id = recording?.id, model.transcriptionStatus[id] != nil {
                        Circle().fill(Theme.accent).frame(width: 7, height: 7).offset(x: 4, y: -3)
                    }
                }
            }
            .buttonStyle(IconButtonStyle(isSelected: model.showTranscript, size: 34))
            .accessibilityLabel(model.showTranscript ? "Hide transcript" : "Show transcript")
            .help("What was said, as text")

            Button {
                model.setReplayEnabled(!model.replayEnabled)
            } label: {
                Image(systemName: "pencil.and.scribble")
            }
            .buttonStyle(IconButtonStyle(isSelected: model.replayEnabled, size: 34))
            .accessibilityLabel(model.replayEnabled ? "Stop replaying notes" : "Replay notes with audio")
            .help("Replay notes in sync with the audio")

            Button {
                model.closeAudioBar()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle(size: 34))
            .accessibilityLabel("Close player")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .glassBackground(cornerRadius: 22)
        .overlay(alignment: .top) {
            if model.isReplaying {
                Text("Replaying · tap ink to jump there · pick a pen to write")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .glassCapsule()
                    .offset(y: -34)
            }
        }
    }

    private func rateLabel(_ r: Double) -> String {
        r == 1 ? "1×" : String(format: "%g×", r)
    }
}
