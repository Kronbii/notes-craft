# Development notes

How NotesCraft is put together, how it is tested on a real iPad, and the hard-won findings behind
some of its less obvious code.

## Layout

- `Sources/NotesCraftCore`: platform-independent models (notebooks, pages, paper, library index),
  page layout, shape and scribble recognition, the archive format. No UIKit; tested on Linux.
- `Sources/NotesCraft`: the iPad app (SwiftUI, UIKit, PencilKit).
  - `Canvas/`: the canvas. One `PKCanvasView` spans every page; page backgrounds render below the
    ink in `CATiledLayer` tiles; a desk mask above the ink hides anything outside the pages; an
    overlay on top holds interactive UI. Canvases (whiteboards) draw their dots live
    (`BoardPattern.swift`) and show a minimap (`BoardMiniMap.swift`).
  - `Editor/`: editor state (`EditorModel`), toolbars, page navigator, audio bar, sheets.
  - `Library/`: library, sidebar, covers, New panel, settings.
  - `Services/`: storage, import, export, audio, handwriting recognition, search.
  - `Rendering/`: one renderer shared by thumbnails, exports and handwriting recognition.
  - `Support/`: app info, the self test (`SelfTest.swift`, also in release builds), and the
    development-only harness (`Automation.swift`, `StressTest.swift`, behind `NOTESCRAFT_DEV`).

Notebooks live in the app's private Application Support folder, one folder per notebook
(`document.json`, one PencilKit drawing per page, `assets/` for PDFs, images and audio). Writes are
atomic, and the library index is rebuilt from the notebook folders if it is ever damaged.

## Testing on the iPad

Debug builds watch `Documents/Automation/command.json` while the app is open in the foreground.
The scripts write that file over USB (house_arrest/AFC, `scripts/dev/afcpull.py` using
libimobiledevice), wait for the run and pull its screenshots and log.

Setup: put the app's on-device bundle ID in `scripts/dev/local.env` (not committed):

```bash
NC_APP_ID=XTL-<your Apple team ID>.com.kronbii.NotesCraft
```

- `scripts/dev/install.sh [ipa]`: builds a debug IPA (or takes one) and installs it, asking the
  running app to save and quit first. iOS doesn't allow launching the app remotely; open it by hand.
- `scripts/dev/tour.sh SCENARIO [TIMEOUT]`: runs a scenario and pulls the results into
  `$TOUR_OUT/tours/` (default `/tmp/notescraft-tours`). Scenarios:
  - `full`, `library`, `editor`, `pdf`, `dark`, `board`, `inklab`: screenshot tours.
  - `selftest`: the self test (also in release builds: Settings, tap the version 5 times).
  - `stress`: writing/erasing stress test (logs `NCSTRESS`): scribble, eraser and partial eraser
    with zoom and scroll, stale PencilKit reports, tap-undo during a stroke, shapes, text, lasso,
    pages, canvas growth, undo/redo spam, erase-all, and a seeded 160-step random mix per document
    whose undo/redo history is replayed state by state, plus save and reload.
  - `setup` / `cleanup`: create or delete the "Tour ·" test notebooks.
  - `quit`: save and exit (used by `install.sh`).
- Device log: `idevicesyslog --no-colors | grep -E "NotesCraft\[[0-9]+\] <(Error|Fault)>|NCTOUR|NCSELFTEST|NCSTRESS|NCUNDO|NCBOARD|NCGESTURE"`.

Not covered by the harness (test by hand): Apple Pencil feel and palm rejection, finger gestures,
Pencil double-tap, the microphone permission prompt, the Files/Photos/scanner pickers, the share sheet.

## Findings worth knowing

- **Installs hanging at "[Installing] 100%":** iOS won't replace an app that is open on screen. The
  installer's request to stop it fails ("termination resistance", in the installcoordinationd and
  runningboardd logs) and it waits for the app to exit. `install.sh` asks the app to quit first.
- **PencilKit and programmatic changes:** replacing `PKCanvasView.drawing` from inside PencilKit's
  own callbacks (stroke finished, drawing changed) leaves PencilKit with a stale copy of the
  drawing that it shows again on the next zoom or scroll and later reports back as ink. Ink is
  therefore committed on the next run loop (`scheduleCommit`). Every commit is reconciled against
  the saved ink (`reconcile`), and strokes that left the notebook are remembered so a stale report
  can't bring them back (`noteRemovedStrokes`).
- **Re-setting identical ink** makes PencilKit re-render every stroke (a visible flicker), so
  `setCanvasDrawing` skips identical drawings.
- **Two-finger taps vs pinches:** the tap recognizers wait for the scroll view's pinch and pan to
  fail, and ignore a "tap" during which the view zoomed or moved.
- **Synthetic strokes:** PencilKit point sizes are about 1.8× the toolbar width; very small point
  sizes are almost invisible on the live canvas.
- **Ink widths:** each ink has its own valid width range (crayon and watercolor start at 10 pt,
  calligraphy at 5 pt), so each pen type keeps its own three widths.
- **Canvases** are one page flagged `isBoard`, 100,000 pt square, that grows in 6,400 pt steps when
  you get near an edge (growing left or up shifts the content; undo snapshots carry the offset in
  `CanvasState.origin`). The dots follow GoodNotes' measured rule (`PaperKind.boardPitch`): 25 pt
  apart, halved until at least 7.5 pt apart on screen. Covers, exports and handwriting recognition
  crop to the drawn area (`BoardRegion`).
- **Undo** keeps 80 steps (`EditorModel`, `levelsOfUndo`).
