import NotesCraftCore
import PencilKit
import UIKit

/// Notability-style replay: while a recording plays, ink written later in the
/// recording is shown faded and darkens as the audio reaches it. Tapping ink
/// jumps the audio to the moment it was written.
extension CanvasController {
    func startReplay(_ recording: Recording) {
        commitPendingInk()
        endTextEditing()
        clearSelection()
        replayRecordingStrokeTimes.removeAll()
        for (i, stroke) in baseline.strokes.enumerated() {
            if let t = recording.mediaTime(for: stroke.path.creationDate) {
                replayRecordingStrokeTimes[i] = t
            }
        }
        replayTime = 0
        lastReplayVisibleCount = -1
        if let tools = editor?.tools { applyTool(tools) }
        layoutOverlays()
        editor?.replayStateChanged(true)
    }

    var replayHasTimedInk: Bool { !replayRecordingStrokeTimes.isEmpty }

    func updateReplay(time: TimeInterval) {
        guard replayTime != nil else { return }
        replayTime = time
        let visible = replayRecordingStrokeTimes.values.filter { $0 <= time }.count
        if visible != lastReplayVisibleCount {
            lastReplayVisibleCount = visible
            setCanvasDrawing(replayDisplayDrawing())
        }
    }

    func stopReplay() {
        guard replayTime != nil else { return }
        replayTime = nil
        replayRecordingStrokeTimes.removeAll()
        setCanvasDrawing(baseline)
        if let tools = editor?.tools { applyTool(tools) }
        layoutOverlays()
        editor?.replayStateChanged(false)
    }

    func replayDisplayDrawing() -> PKDrawing {
        guard let t = replayTime else { return baseline }
        var strokes = baseline.strokes
        for (i, time) in replayRecordingStrokeTimes where time > t && i < strokes.count {
            let s = strokes[i]
            let faded = s.ink.color.withAlphaComponent(s.ink.inkType == .marker ? 0.25 : 0.16)
            strokes[i] = PKStroke(ink: PKInk(s.ink.inkType, color: faded), path: s.path, transform: s.transform, mask: s.mask)
        }
        return PKDrawing(strokes: strokes)
    }

    func replayTap(at p: CGPoint) {
        guard let index = strokeHit(at: p) else { return }
        if let time = replayRecordingStrokeTimes[index] {
            Haptics.tap()
            editor?.seekPlayback(to: max(0, time - 1.0))
        } else {
            editor?.showToast("This ink wasn't written during this recording")
        }
    }
}
