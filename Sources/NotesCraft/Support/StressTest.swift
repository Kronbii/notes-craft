#if NOTESCRAFT_DEV
// Development builds only (see Package.swift).
import Foundation
import NotesCraftCore
import os
import PencilKit
import UIKit

/// Deep on-device test of writing and erasing in the live editor. It drives the
/// canvas the way PencilKit does (tool begins, drawing changes, tool ends), runs
/// targeted edge cases and a seeded random mix of operations, and checks:
/// - after every step, that what PencilKit shows is exactly the notebook's ink;
/// - that zooming and scrolling never bring erased or undone ink back;
/// - that undo walks back through every recorded state exactly, and redo forward;
/// - that saving and reopening keeps every stroke, page and text box.
/// Results go to the system log as "NCSTRESS ..." (scenario `stress`).
enum StressTest {
    static let logger = Logger(subsystem: "com.kronbii.NotesCraft", category: "stress")
    private static var passed = 0
    private static var failed = 0

    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failed += 1 }
        if !ok || name.hasPrefix("*") {
            let d = detail()
            logger.error("NCSTRESS \(ok ? "PASS" : "FAIL", privacy: .public) \(name, privacy: .public) \(d, privacy: .public)")
        }
    }

    static func note(_ text: String) {
        logger.error("NCSTRESS INFO \(text, privacy: .public)")
    }

    static func pause(_ ms: Int = 90) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    // MARK: - Run

    static func run() async {
        passed = 0
        failed = 0
        note("starting")
        let scribbleSetting = AppSettings.shared.scribbleToErase
        AppSettings.shared.scribbleToErase = true
        defer { AppSettings.shared.scribbleToErase = scribbleSetting }
        let library = LibraryStore.shared
        for title in ["Stress notebook", "Stress canvas"] {
            library.deletePermanently(library.index.notebooks.filter { $0.title == Tour.tourPrefix + title }.map(\.id))
        }
        do {
            let notebook = try library.createNotebook(title: Tour.tourPrefix + "Stress notebook", paper: PaperStyle(kind: .collegeRuled),
                                                      cover: .design(color: .slate, pattern: .plain), folder: nil)
            let board = try library.createBoard(paper: .dotted, color: .white, folder: nil)
            library.rename(board.id, to: Tour.tourPrefix + "Stress canvas")

            if let editor = await Tour.open("Stress notebook") {
                editor.addPageAtEnd()
                editor.addPageAtEnd()
                await pause(300)
                await edgeCases(editor, label: "notebook")
                await pageCases(editor)
                await fuzz(editor, label: "notebook", steps: 160, seed: 0x5EED_0001)
                await saveReload(editor, label: "notebook")
            } else {
                check(false, "open.notebook")
            }
            if let editor = await Tour.open("Stress canvas") {
                await pause(300)
                await edgeCases(editor, label: "canvas")
                await canvasCases(editor)
                await fuzz(editor, label: "canvas", steps: 160, seed: 0x5EED_0002)
                await saveReload(editor, label: "canvas")
            } else {
                check(false, "open.canvas")
            }
            await Tour.closeEditorIfOpen()
            library.deletePermanently([notebook.id, board.id])
        } catch {
            check(false, "setup", error.localizedDescription)
        }
        note("done passed=\(passed) failed=\(failed)")
    }

    // MARK: - Driving the canvas like PencilKit

    /// A hand-written-looking stroke inside `rect` (document coordinates).
    static func stroke(in rect: CGRect, rng: inout SeededRandom, color: UIColor = .black, ink: PKInk.InkType = .monoline, date: Date = Date()) -> PKStroke {
        let n = 12 + Int(rng.next() % 30)
        var points: [PKStrokePoint] = []
        var p = CGPoint(x: rect.minX + rect.width * rng.unit(), y: rect.minY + rect.height * rng.unit())
        for i in 0 ..< n {
            p.x = min(max(p.x + CGFloat(rng.unit() * 16 - 6), rect.minX), rect.maxX)
            p.y = min(max(p.y + CGFloat(rng.unit() * 10 - 5), rect.minY), rect.maxY)
            points.append(PKStrokePoint(location: p, timeOffset: Double(i) * 0.012, size: CGSize(width: 4.6, height: 4.6),
                                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
        }
        return PKStroke(ink: PKInk(ink, color: color), path: PKStrokePath(controlPoints: points, creationDate: date))
    }

    /// A quick back-and-forth scribble covering `rect`.
    static func scribble(over rect: CGRect) -> PKStroke {
        var points: [PKStrokePoint] = []
        let r = rect.insetBy(dx: -8, dy: -6)
        let sweeps = 8
        for s in 0 ..< sweeps {
            let y = r.minY + r.height * CGFloat(s) / CGFloat(sweeps - 1)
            for k in 0 ... 10 {
                let t = CGFloat(k) / 10
                let x = s % 2 == 0 ? r.minX + r.width * t : r.maxX - r.width * t
                points.append(PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: Double(points.count) * 0.004,
                                            size: CGSize(width: 4.6, height: 4.6), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
            }
        }
        return PKStroke(ink: PKInk(.monoline, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    /// One tool use: begin, the canvas drawing changes, end — like PencilKit.
    static func toolUse(_ c: CanvasController, tool: ToolKind, _ change: (inout [PKStroke]) -> Void) async {
        c.currentTool = tool
        c.canvasViewDidBeginUsingTool(c.canvas)
        var strokes = c.canvas.drawing.strokes
        change(&strokes)
        c.canvas.drawing = PKDrawing(strokes: strokes)
        c.canvasViewDidEndUsingTool(c.canvas)
        await pause(110)
    }

    static func write(_ c: CanvasController, _ s: PKStroke, tool: ToolKind = .pen) async {
        await toolUse(c, tool: tool) { $0.append(s) }
    }

    /// Stroke-eraser: removes whole strokes.
    static func erase(_ c: CanvasController, where match: (PKStroke) -> Bool) async {
        await toolUse(c, tool: .eraser) { $0.removeAll(where: match) }
    }

    /// Partial eraser: splits a stroke into two pieces (same date, like PencilKit).
    static func split(_ c: CanvasController, at index: Int) async {
        await toolUse(c, tool: .eraser) { strokes in
            guard strokes.indices.contains(index) else { return }
            let s = strokes[index]
            let pts = Array(s.path)
            guard pts.count >= 6 else { return }
            let a = PKStroke(ink: s.ink, path: PKStrokePath(controlPoints: Array(pts[0 ..< pts.count / 2 - 1]), creationDate: s.path.creationDate), transform: s.transform, mask: s.mask)
            let b = PKStroke(ink: s.ink, path: PKStrokePath(controlPoints: Array(pts[pts.count / 2 + 1 ..< pts.count]), creationDate: s.path.creationDate), transform: s.transform, mask: s.mask)
            strokes.replaceSubrange(index ... index, with: [a, b])
        }
    }

    /// Zooms and scrolls somewhere, then lets things settle like a real gesture.
    static func wander(_ c: CanvasController, rng: inout SeededRandom) async {
        let lo = c.canvas.minimumZoomScale, hi = min(c.canvas.maximumZoomScale, c.fitZoom * 3)
        let z = lo + (hi - lo) * CGFloat(rng.unit())
        let target = c.boardContentRect.map { CGPoint(x: $0.midX, y: $0.midY) }
            ?? CGPoint(x: c.layout.contentSize.width * CGFloat(rng.unit()), y: c.layout.contentSize.height * CGFloat(rng.unit()))
        let jitter = CGPoint(x: target.x + CGFloat(rng.unit() * 600 - 300), y: target.y + CGFloat(rng.unit() * 600 - 300))
        c.setZoom(z, keeping: jitter, at: CGPoint(x: c.canvas.bounds.width / 2, y: c.canvas.bounds.height / 2))
        c.scrollViewDidEndDecelerating(c.canvas)
        await pause(160)
    }

    // MARK: - Invariants

    /// What PencilKit shows must be exactly the notebook's ink.
    static func checkShown(_ c: CanvasController, _ name: String) {
        let shown = c.canvas.drawing
        let ok = shown.strokes.count == c.baseline.strokes.count && InkFingerprint.of(shown) == InkFingerprint.of(c.baseline)
        check(ok, name, "shown=\(shown.strokes.count) ink=\(c.baseline.strokes.count)")
    }

    /// A comparable picture of the notebook, independent of how far a canvas
    /// has been shifted by growing.
    struct Snapshot {
        var strokes: [[Double]]
        var pages: [String]
        var elements: [[Double]]

        func matches(_ other: Snapshot, tolerance: Double = 1.5) -> Bool {
            guard strokes.count == other.strokes.count, pages == other.pages, elements.count == other.elements.count else { return false }
            for (a, b) in zip(strokes, other.strokes) where a.count != b.count || zip(a, b).contains(where: { abs($0 - $1) > tolerance }) { return false }
            for (a, b) in zip(elements, other.elements) where a.count != b.count || zip(a, b).contains(where: { abs($0 - $1) > tolerance }) { return false }
            return true
        }
    }

    static func snapshot(_ c: CanvasController) -> Snapshot {
        let o = c.boardOrigin
        let strokes = c.baseline.strokes.map { s -> [Double] in
            let b = s.renderBounds
            let col = s.ink.color.rgba
            return [s.path.creationDate.timeIntervalSinceReferenceDate * 1000, Double(s.path.count),
                    Double(b.minX - o.x), Double(b.minY - o.y), Double(b.width), Double(b.height),
                    Double(col.r * 255).rounded(), Double(col.g * 255).rounded(), Double(col.b * 255).rounded()]
        }.sorted { $0.lexicographicallyPrecedes($1) }
        let pages = c.document.pages.map { "\($0.id)|\($0.background)|\($0.elements.map { e in "\(e.id):\(e.textContent?.plainText ?? "-")" }.joined(separator: ","))" }
        var elements: [[Double]] = []
        for page in c.document.pages {
            for e in page.elements {
                elements.append([Double(e.frame.minX - o.x), Double(e.frame.minY - o.y), Double(e.frame.width), Double(e.frame.height)])
            }
        }
        return Snapshot(strokes: strokes, pages: pages, elements: elements)
    }

    // MARK: - Targeted edge cases

    static func edgeCases(_ editor: EditorModel, label: String) async {
        let c = editor.canvas!
        var rng = SeededRandom(seed: label == "canvas" ? 11 : 7)
        let area = workArea(c)
        // Three words to work with.
        var words: [PKStroke] = []
        for i in 0 ..< 3 {
            let s = stroke(in: CGRect(x: area.minX + 40, y: area.minY + 60 + CGFloat(i) * 70, width: 160, height: 26), rng: &rng)
            words.append(s)
            await write(c, s)
        }
        checkShown(c, "\(label).write")
        check(c.baseline.strokes.count >= 3, "\(label).writeCount", "\(c.baseline.strokes.count)")

        // Scribble out the first word, then zoom and scroll: it must stay gone.
        let before = c.baseline.strokes.count
        await write(c, scribble(over: words[0].renderBounds))
        check(c.baseline.strokes.count == before - 1, "\(label).scribbleErases", "\(before) -> \(c.baseline.strokes.count)")
        checkShown(c, "\(label).scribbleShown")
        for _ in 0 ..< 4 { await wander(c, rng: &rng) }
        await pause(450)
        checkShown(c, "\(label).scribbleStaysGoneAfterZoom")
        check(c.baseline.strokes.count == before - 1, "\(label).scribbleCountAfterZoom", "\(c.baseline.strokes.count)")

        // PencilKit reports a stale copy (the erased word comes back with a new stroke).
        let stale = c.baseline.strokes + [words[0]]
        let fresh = stroke(in: CGRect(x: area.minX + 300, y: area.minY + 60, width: 120, height: 26), rng: &rng)
        await toolUse(c, tool: .pen) { strokes in strokes = stale + [fresh] }
        check(!c.baseline.strokes.contains { StrokeKey($0) == StrokeKey(words[0]) }, "\(label).staleCopyDropped")
        check(c.baseline.strokes.contains { StrokeKey($0) == StrokeKey(fresh) }, "\(label).freshStrokeKept")
        checkShown(c, "\(label).staleShown")

        // Stroke eraser, then zoom: erased word stays gone.
        await erase(c) { StrokeKey($0) == StrokeKey(words[1]) }
        check(!c.baseline.strokes.contains { StrokeKey($0) == StrokeKey(words[1]) }, "\(label).eraserRemoves")
        for _ in 0 ..< 3 { await wander(c, rng: &rng) }
        await pause(400)
        checkShown(c, "\(label).eraserStaysGoneAfterZoom")
        check(!c.baseline.strokes.contains { StrokeKey($0) == StrokeKey(words[1]) }, "\(label).eraserCountAfterZoom")
        // ... and a stale report after erasing doesn't bring it back either.
        await toolUse(c, tool: .pen) { strokes in strokes.append(words[1]) }
        check(!c.baseline.strokes.contains { StrokeKey($0) == StrokeKey(words[1]) }, "\(label).eraserStaleDropped")

        // Partial eraser splits a stroke; undo puts it back whole.
        if let i = c.baseline.strokes.firstIndex(where: { StrokeKey($0) == StrokeKey(words[2]) }) {
            let n = c.baseline.strokes.count
            await split(c, at: i)
            check(c.baseline.strokes.count == n + 1, "\(label).partialSplit", "\(n) -> \(c.baseline.strokes.count)")
            editor.undo()
            await pause(300)
            check(c.baseline.strokes.contains { StrokeKey($0) == StrokeKey(words[2]) } && c.baseline.strokes.count == n, "\(label).partialUndo")
            checkShown(c, "\(label).partialUndoShown")
        }

        // Undo the scribble erase brings the word back; redo removes it again; zoom in between.
        var undone = 0
        while editor.undoManager.canUndo, !c.baseline.strokes.contains(where: { StrokeKey($0) == StrokeKey(words[0]) }), undone < 12 {
            editor.undo()
            undone += 1
            await pause(150)
        }
        check(c.baseline.strokes.contains { StrokeKey($0) == StrokeKey(words[0]) }, "\(label).undoBringsScribbledBack", "after \(undone) undos")
        await wander(c, rng: &rng)
        checkShown(c, "\(label).undoShownAfterZoom")
        for _ in 0 ..< undone {
            editor.redo()
            await pause(150)
        }
        await wander(c, rng: &rng)
        await pause(400)
        checkShown(c, "\(label).redoShownAfterZoom")
        check(!c.baseline.strokes.contains { StrokeKey($0) == StrokeKey(words[0]) }, "\(label).redoRemovesAgain")

        // Two-finger undo while a finger stroke had started.
        let n = c.baseline.strokes.count
        let last = stroke(in: CGRect(x: area.minX + 40, y: area.minY + 320, width: 150, height: 26), rng: &rng)
        await write(c, last)
        c.toolInUse = true
        c.historyWillChange(fromTouch: true)
        c.toolInUse = false
        editor.undo()
        await pause(150)
        // PencilKit finishes the cancelled stroke on its stale copy.
        await toolUse(c, tool: .pen) { strokes in strokes.append(last) }
        check(c.baseline.strokes.count == n && !c.baseline.strokes.contains { StrokeKey($0) == StrokeKey(last) }, "\(label).tapUndoNoResurrect", "\(c.baseline.strokes.count) vs \(n)")
        checkShown(c, "\(label).tapUndoShown")

        // Shapes and the highlighter.
        c.currentTool = .shape
        let rough = rectangleStroke(CGRect(x: area.minX + 260, y: area.minY + 200, width: 160, height: 100))
        await write(c, rough, tool: .shape)
        check(c.baseline.strokes.last.map { StrokeKey($0) != StrokeKey(rough) } ?? false, "\(label).shapeSnaps")
        checkShown(c, "\(label).shapeShown")
        editor.undo()
        await pause(150)
        check(!c.baseline.strokes.contains { $0.path.creationDate == rough.path.creationDate }, "\(label).shapeUndo")
        checkShown(c, "\(label).shapeUndoShown")

        // Text: an empty box adds nothing; a typed one is one undo step.
        let elementsBefore = c.document.pages.reduce(0) { $0 + $1.elements.count }
        editor.selectTool(.text)
        c.createTextBox(at: CGPoint(x: area.minX + 60, y: area.minY + 420), pageIndex: c.isBoard ? 0 : 0)
        await pause(200)
        c.endTextEditing()
        await pause(200)
        check(c.document.pages.reduce(0) { $0 + $1.elements.count } == elementsBefore, "\(label).emptyTextAddsNothing")
        c.createTextBox(at: CGPoint(x: area.minX + 60, y: area.minY + 420), pageIndex: 0)
        await pause(200)
        c.textEditor?.insertText("Stress text")
        await pause(120)
        c.endTextEditing()
        await pause(200)
        check(c.document.pages.reduce(0) { $0 + $1.elements.count } == elementsBefore + 1, "\(label).textAdded")
        editor.undo()
        await pause(200)
        check(c.document.pages.reduce(0) { $0 + $1.elements.count } == elementsBefore, "\(label).textUndo")
        editor.redo()
        await pause(200)
        check(c.document.pages.reduce(0) { $0 + $1.elements.count } == elementsBefore + 1, "\(label).textRedo")
        editor.selectTool(.pen)
        await pause(150)

        // Lasso: move, then undo puts it back; delete and undo.
        if !c.baseline.strokes.isEmpty {
            let index = c.baseline.strokes.count - 1
            let original = c.baseline.strokes[index].renderBounds
            c.selectStrokes([index])
            c.beginDrag(.move)
            c.updateDrag(translation: CGPoint(x: 80 * c.zoom, y: 40 * c.zoom))
            c.endDrag()
            await pause(200)
            let moved = c.baseline.strokes.contains { near($0.renderBounds, original.offsetBy(dx: 80, dy: 40)) }
            check(moved, "\(label).lassoMove")
            checkShown(c, "\(label).lassoMoveShown")
            c.clearSelection()
            editor.undo()
            await pause(200)
            let restored = c.baseline.strokes.contains { near($0.renderBounds, original) }
            check(restored, "\(label).lassoMoveUndo")
            let count = c.baseline.strokes.count
            c.selectStrokes([0])
            c.deleteSelection()
            await pause(200)
            check(c.baseline.strokes.count == count - 1, "\(label).lassoDelete")
            await wander(c, rng: &rng)
            checkShown(c, "\(label).lassoDeleteShownAfterZoom")
            editor.undo()
            await pause(200)
            check(c.baseline.strokes.count == count, "\(label).lassoDeleteUndo")
            checkShown(c, "\(label).lassoDeleteUndoShown")
        }

        // Rapid undo/redo spam ends where it should.
        let target = snapshot(c)
        for i in 0 ..< 30 {
            if i % 2 == 0 { editor.undo() } else { editor.redo() }
            await pause(40)
        }
        await pause(500)
        check(snapshot(c).matches(target), "\(label).undoRedoSpam")
        checkShown(c, "\(label).undoRedoSpamShown")

        // Erase everything, zoom around, undo brings it all back.
        let all = c.baseline.strokes.count
        await erase(c) { _ in true }
        check(c.baseline.strokes.isEmpty, "\(label).eraseAll")
        await wander(c, rng: &rng)
        await pause(300)
        checkShown(c, "\(label).eraseAllShownAfterZoom")
        editor.undo()
        await pause(250)
        check(c.baseline.strokes.count == all, "\(label).eraseAllUndo", "\(c.baseline.strokes.count) vs \(all)")
        checkShown(c, "\(label).eraseAllUndoShown")
        note("\(label) edge cases done")
    }

    /// Two rectangles in the same place (within 1.5 points).
    static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        let dx: CGFloat = abs(a.minX - b.minX)
        let dy: CGFloat = abs(a.minY - b.minY)
        return dx < 1.5 && dy < 1.5
    }

    static func rectangleStroke(_ r: CGRect) -> PKStroke {
        let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY + 2), CGPoint(x: r.maxX + 1, y: r.maxY),
                       CGPoint(x: r.minX - 1, y: r.maxY + 1), CGPoint(x: r.minX + 1, y: r.minY + 2)]
        var pts: [PKStrokePoint] = []
        for i in 0 ..< corners.count - 1 {
            for k in 0 ..< 20 {
                let t = CGFloat(k) / 20
                let a = corners[i], b = corners[i + 1]
                pts.append(PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), timeOffset: Double(pts.count) * 0.01,
                                         size: CGSize(width: 4.6, height: 4.6), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
            }
        }
        return PKStroke(ink: PKInk(.monoline, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
    }

    /// Where to write: the first page, or around the middle of a canvas.
    static func workArea(_ c: CanvasController) -> CGRect {
        guard let frame = c.layout.frame(of: 0) else { return CGRect(x: 100, y: 100, width: 500, height: 600) }
        if c.isBoard {
            return CGRect(x: frame.midX - 300, y: frame.midY - 300, width: 600, height: 600)
        }
        return CGRect(x: frame.minX + 20, y: frame.minY + 40, width: min(560, frame.width - 40), height: min(700, frame.height - 60))
    }

    // MARK: - Pages (notebooks)

    static func pageCases(_ editor: EditorModel) async {
        let c = editor.canvas!
        var rng = SeededRandom(seed: 99)
        guard c.layout.pageCount >= 3 else {
            check(false, "pages.setup", "\(c.layout.pageCount)")
            return
        }
        // Ink on page 3, then delete page 2: page 3's ink moves up with it.
        let f3 = c.layout.pageFrames[2]
        let s = stroke(in: CGRect(x: f3.minX + 60, y: f3.minY + 100, width: 200, height: 30), rng: &rng)
        await write(c, s)
        let page3 = c.document.pages[2].id
        editor.deletePages([c.document.pages[1].id])
        await pause(250)
        c.flushInkToDocument()
        check(c.document.drawing(for: page3).strokes.contains { $0.path.creationDate == s.path.creationDate }, "pages.inkFollowsPage")
        checkShown(c, "pages.deleteShown")
        editor.undo()
        await pause(250)
        check(c.document.pages.count == 3, "pages.deleteUndo", "\(c.document.pages.count)")
        checkShown(c, "pages.deleteUndoShown")
        // Move the page with ink to the front, then undo.
        editor.movePage(from: 2, to: 0)
        await pause(250)
        c.flushInkToDocument()
        check(c.document.pages[0].id == page3 && c.document.drawing(for: page3).strokes.count >= 1, "pages.move")
        checkShown(c, "pages.moveShown")
        editor.undo()
        await pause(250)
        check(c.document.pages[2].id == page3, "pages.moveUndo")
        checkShown(c, "pages.moveUndoShown")
        note("page cases done")
    }

    // MARK: - Canvas growth

    static func canvasCases(_ editor: EditorModel) async {
        let c = editor.canvas!
        var rng = SeededRandom(seed: 1234)
        let area = workArea(c)
        let s = stroke(in: CGRect(x: area.minX, y: area.minY, width: 200, height: 30), rng: &rng)
        await write(c, s)
        let before = snapshot(c)
        // Grow left and up (moves everything), then erase and undo across it.
        c.growBoard(left: 7000, top: 7000, right: 0, bottom: 0)
        await pause(200)
        check(snapshot(c).matches(before), "canvas.growKeepsContent")
        checkShown(c, "canvas.growShown")
        await erase(c) { $0.path.creationDate == s.path.creationDate }
        await wander(c, rng: &rng)
        await pause(300)
        checkShown(c, "canvas.eraseAfterGrowShown")
        check(!c.baseline.strokes.contains { $0.path.creationDate == s.path.creationDate }, "canvas.eraseAfterGrow")
        editor.undo()
        await pause(250)
        check(snapshot(c).matches(before), "canvas.undoAfterGrow")
        checkShown(c, "canvas.undoAfterGrowShown")
        note("canvas cases done")
    }

    // MARK: - Random mix

    static func fuzz(_ editor: EditorModel, label: String, steps: Int, seed: UInt64) async {
        let c = editor.canvas!
        var rng = SeededRandom(seed: seed)
        let area = workArea(c)
        var history: [Snapshot] = [snapshot(c)]
        var mismatches = 0
        for step in 0 ..< steps {
            let roll = rng.next() % 100
            let beforeOp = snapshot(c)
            var op = ""
            switch roll {
            case 0 ..< 38:
                op = "write"
                let r = CGRect(x: area.minX + area.width * CGFloat(rng.unit()) * 0.8, y: area.minY + area.height * CGFloat(rng.unit()) * 0.9,
                               width: 60 + 120 * CGFloat(rng.unit()), height: 20 + 20 * CGFloat(rng.unit()))
                let colors: [UIColor] = [.black, .systemBlue, .systemRed]
                await write(c, stroke(in: r, rng: &rng, color: colors[Int(rng.next() % 3)]))
            case 38 ..< 50:
                guard !c.baseline.strokes.isEmpty else { continue }
                op = "erase"
                let victim = StrokeKey(c.baseline.strokes[Int(rng.next() % UInt64(c.baseline.strokes.count))])
                await erase(c) { StrokeKey($0) == victim }
            case 50 ..< 56:
                guard !c.baseline.strokes.isEmpty else { continue }
                op = "split"
                await split(c, at: Int(rng.next() % UInt64(c.baseline.strokes.count)))
            case 56 ..< 64:
                guard !c.baseline.strokes.isEmpty else { continue }
                op = "scribble"
                let target = c.baseline.strokes[Int(rng.next() % UInt64(c.baseline.strokes.count))].renderBounds
                await write(c, scribble(over: target))
            case 64 ..< 72:
                guard !c.baseline.strokes.isEmpty else { continue }
                op = "move"
                c.selectStrokes([Int(rng.next() % UInt64(c.baseline.strokes.count))])
                c.beginDrag(.move)
                // At least 10 points, so every move is a visible change.
                func offset() -> CGFloat { CGFloat((rng.next() % 2 == 0 ? 1.0 : -1.0) * (10 + rng.unit() * 50)) }
                c.updateDrag(translation: CGPoint(x: offset() * c.zoom, y: offset() * c.zoom))
                c.endDrag()
                c.clearSelection()
                await pause(150)
            case 72 ..< 76:
                guard c.baseline.strokes.count >= 2 else { continue }
                op = "delete"
                c.selectStrokes([0, 1])
                c.deleteSelection()
                await pause(150)
            case 76 ..< 80:
                guard !c.baseline.strokes.isEmpty else { continue }
                op = "duplicate"
                c.selectStrokes([Int(rng.next() % UInt64(c.baseline.strokes.count))])
                c.duplicateSelection()
                c.clearSelection()
                await pause(150)
            default:
                op = "wander"
                await wander(c, rng: &rng)
            }
            await pause(60)
            checkShown(c, "\(label).fuzz.\(step).\(op).shown")
            let after = snapshot(c)
            if !after.matches(beforeOp) {
                history.append(after)
            }
        }
        await pause(500)
        checkShown(c, "\(label).fuzz.settledShown")
        note("\(label) fuzz: \(history.count - 1) changes recorded; undoing all")

        // Undo walks back through every recorded state exactly (zooming now and
        // then), as far as the undo history goes (80 steps).
        let depth = min(history.count - 1, editor.undoManager.levelsOfUndo)
        let oldest = history.count - 1 - depth
        for k in stride(from: history.count - 1, to: oldest, by: -1) {
            guard editor.undoManager.canUndo else {
                check(false, "\(label).fuzz.undoAvailable", "ran out at \(k)")
                break
            }
            editor.undo()
            await pause(120)
            if k % 9 == 0 { await wander(c, rng: &rng) }
            let ok = snapshot(c).matches(history[k - 1])
            if !ok { mismatches += 1 }
            check(ok, "\(label).fuzz.undo.\(k)", "strokes=\(c.baseline.strokes.count) expected=\(history[k - 1].strokes.count)")
            checkShown(c, "\(label).fuzz.undo.\(k).shown")
        }
        if history.count - 1 > depth {
            check(!editor.undoManager.canUndo, "\(label).fuzz.undoLimit", "history is limited to \(depth) steps")
        }
        // ... and redo forward again.
        for k in (oldest + 1) ..< history.count {
            guard editor.undoManager.canRedo else {
                check(false, "\(label).fuzz.redoAvailable", "ran out at \(k)")
                break
            }
            editor.redo()
            await pause(120)
            if k % 11 == 0 { await wander(c, rng: &rng) }
            let ok = snapshot(c).matches(history[k])
            if !ok { mismatches += 1 }
            check(ok, "\(label).fuzz.redo.\(k)", "strokes=\(c.baseline.strokes.count) expected=\(history[k].strokes.count)")
            checkShown(c, "\(label).fuzz.redo.\(k).shown")
        }
        check(mismatches == 0, "*\(label).fuzz.history", "\(history.count - 1) states, \(mismatches) mismatches")
    }

    // MARK: - Saving

    static func saveReload(_ editor: EditorModel, label: String) async {
        let c = editor.canvas!
        editor.saveNow()
        await DiskWriter.shared.flush()
        do {
            let reopened = try await NotebookDocument.open(id: editor.document.id)
            check(reopened.pages.map(\.id) == editor.document.pages.map(\.id), "\(label).save.pages")
            var same = true
            for page in editor.document.pages {
                let a = editor.document.drawing(for: page.id), b = reopened.drawing(for: page.id)
                if a.strokes.count != b.strokes.count || InkFingerprint.of(a) != InkFingerprint.of(b) { same = false }
            }
            check(same, "\(label).save.ink")
            check(reopened.pages.map { $0.elements.count } == editor.document.pages.map { $0.elements.count }, "\(label).save.elements")
            let total = editor.document.pages.reduce(0) { $0 + editor.document.drawing(for: $1.id).strokes.count }
            check(total == c.baseline.strokes.count, "\(label).save.allInkSaved", "\(total) vs \(c.baseline.strokes.count)")
        } catch {
            check(false, "\(label).save.reopen", error.localizedDescription)
        }
        note("\(label) save checked")
    }
}

/// Small deterministic random generator (SplitMix64), so a failing run can be repeated.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
#endif
