#if NOTESCRAFT_DEV
// Development builds only (see Package.swift).
import Foundation
import NotesCraftCore
import os
import PencilKit
import UIKit

/// On-device test of the zoom window and favorite pens (scenario `features`).
/// Logs "NCFEATURE ...".
enum FeatureTest {
    static let logger = Logger(subsystem: "com.kronbii.NotesCraft", category: "features")
    private static var passed = 0
    private static var failed = 0

    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failed += 1 }
        let d = detail()
        logger.error("NCFEATURE \(ok ? "PASS" : "FAIL", privacy: .public) \(name, privacy: .public) \(d, privacy: .public)")
    }

    static func run() async {
        passed = 0
        failed = 0
        let library = LibraryStore.shared
        for title in ["Zoom notebook", "Zoom canvas"] {
            library.deletePermanently(library.index.notebooks.filter { $0.title == Tour.tourPrefix + title }.map(\.id))
        }
        do {
            let notebook = try library.createNotebook(title: Tour.tourPrefix + "Zoom notebook", paper: PaperStyle(kind: .collegeRuled),
                                                      cover: .design(color: .sage, pattern: .plain), folder: nil)
            let board = try library.createBoard(paper: .dotted, color: .white, folder: nil)
            library.rename(board.id, to: Tour.tourPrefix + "Zoom canvas")
            if let editor = await Tour.open("Zoom notebook") {
                await zoomWindow(editor, label: "notebook")
                await favorites(editor)
            } else {
                check(false, "open.notebook")
            }
            if let editor = await Tour.open("Zoom canvas") {
                await zoomWindow(editor, label: "canvas")
            } else {
                check(false, "open.canvas")
            }
            await Tour.closeEditorIfOpen()
            library.deletePermanently([notebook.id, board.id])
        } catch {
            check(false, "setup", error.localizedDescription)
        }
        logger.error("NCFEATURE INFO done passed=\(passed, privacy: .public) failed=\(failed, privacy: .public)")
    }

    /// A word-like stroke inside `rect` (document coordinates).
    static func stroke(in rect: CGRect) -> PKStroke {
        var points: [PKStrokePoint] = []
        for i in 0 ..< 30 {
            let t = CGFloat(i) / 29
            points.append(PKStrokePoint(location: CGPoint(x: rect.minX + rect.width * t, y: rect.midY + sin(t * 12) * rect.height * 0.3),
                                        timeOffset: Double(i) * 0.012, size: CGSize(width: 4.6, height: 4.6),
                                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
        }
        return PKStroke(ink: PKInk(.monoline, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    /// One tool use in the zoom window, the way PencilKit reports it.
    static func useZoom(_ zoom: ZoomWindowController, _ change: (inout [PKStroke]) -> Void) async {
        zoom.canvasViewDidBeginUsingTool(zoom.writing)
        var strokes = zoom.writing.drawing.strokes
        change(&strokes)
        zoom.writing.drawing = PKDrawing(strokes: strokes)
        zoom.canvasViewDidEndUsingTool(zoom.writing)
        try? await Task.sleep(for: .milliseconds(150))
    }

    static func shown(_ c: CanvasController) -> Bool {
        c.canvas.drawing.strokes.count == c.baseline.strokes.count && InkFingerprint.of(c.canvas.drawing) == InkFingerprint.of(c.baseline)
    }

    // MARK: Zoom window

    static func zoomWindow(_ editor: EditorModel, label: String) async {
        let c = editor.canvas!
        editor.selectTool(.pen)
        editor.showZoomWindow = true
        await Automation.wait(1.2)
        guard let zoom = c.zoomWindow else {
            check(false, "\(label).zoom.opens")
            return
        }
        check(true, "\(label).zoom.opens")
        let page = c.isBoard ? c.layout.frame(of: 0)! : c.layout.frame(of: c.layout.pageIndex(forY: zoom.target.midY) ?? 0)!
        check(page.contains(zoom.target), "\(label).zoom.boxOnPage", "\(zoom.target) in \(page)")
        check(c.zoomTargetView?.superview != nil, "\(label).zoom.boxShown")
        check(abs(zoom.target.width * zoom.magnification - zoom.view.bounds.width) < 2, "\(label).zoom.magnified",
              "\(zoom.target.width) x \(zoom.magnification) vs \(zoom.view.bounds.width)")
        await Automation.shot("zoom-window-\(label)")

        // Write in the zoom window: the ink lands in the box, on the page, at its real size.
        let before = c.baseline.strokes.count
        let box = zoom.target
        let word = stroke(in: CGRect(x: box.minX + box.width * 0.1, y: box.minY + box.height * 0.3, width: box.width * 0.25, height: box.height * 0.4))
        await useZoom(zoom) { $0.append(word) }
        check(c.baseline.strokes.count == before + 1, "\(label).zoom.writes", "\(before) -> \(c.baseline.strokes.count)")
        let landed = c.baseline.strokes.last?.renderBounds ?? .null
        check(box.insetBy(dx: -6, dy: -6).contains(landed), "\(label).zoom.landsInBox", "\(landed) in \(box)")
        check(abs(landed.width - word.renderBounds.width) < 1, "\(label).zoom.realSize")
        check(shown(c), "\(label).zoom.pageShowsIt")
        check(zoom.writing.drawing.strokes.count == c.baseline.strokes.count, "\(label).zoom.inSync")
        await Automation.shot("zoom-window-\(label)-written")

        // Undo takes it back from both.
        editor.undo()
        await Automation.wait(0.4)
        check(c.baseline.strokes.count == before && zoom.writing.drawing.strokes.count == before && shown(c), "\(label).zoom.undo")
        editor.redo()
        await Automation.wait(0.4)
        check(c.baseline.strokes.count == before + 1 && shown(c), "\(label).zoom.redo")

        // Erasing in the zoom window removes it from the page.
        let key = StrokeKey(c.baseline.strokes.last!)
        c.currentTool = .eraser
        await useZoom(zoom) { strokes in strokes.removeAll { StrokeKey($0) == key } }
        c.currentTool = .pen
        check(!c.baseline.strokes.contains { StrokeKey($0) == key } && shown(c), "\(label).zoom.erases")

        // Writing near the right edge moves the box along; "new line" goes back and down.
        let start = zoom.target
        let far = stroke(in: CGRect(x: start.minX + start.width * 0.6, y: start.minY + start.height * 0.3, width: start.width * 0.3, height: start.height * 0.4))
        await useZoom(zoom) { $0.append(far) }
        check(zoom.target.minX > start.minX + 1, "\(label).zoom.autoAdvance", "\(start.minX) -> \(zoom.target.minX)")
        zoom.newLine()
        await Automation.wait(0.3)
        check(zoom.target.minY > start.minY && abs(zoom.target.minX - start.minX) < 1, "\(label).zoom.newLine", "\(start) -> \(zoom.target)")
        check(shown(c), "\(label).zoom.shownAfterMoves")

        // Dragging the box moves it.
        let dragged = zoom.target
        zoom.moveTarget(to: dragged.offsetBy(dx: 30, dy: 40), scroll: false)
        check(abs(zoom.target.minX - dragged.minX - 30) < 1 && abs(zoom.target.minY - dragged.minY - 40) < 1, "\(label).zoom.drag")
        c.layoutZoomTarget()
        let boxOnScreen = c.zoomTargetView?.frame ?? .null
        check(abs(boxOnScreen.minX - zoom.target.minX * c.zoom) < 1, "\(label).zoom.boxFollowsZoom")

        // Magnification changes the box size.
        zoom.magnification = 4
        await Automation.wait(0.3)
        check(abs(zoom.target.width * 4 - zoom.view.bounds.width) < 2, "\(label).zoom.magnification")
        zoom.magnification = 2.5

        // The page leaves room above the panel.
        check(c.zoomPanelInset > 200, "\(label).zoom.inset", "\(c.zoomPanelInset)")

        editor.showZoomWindow = false
        await Automation.wait(0.6)
        check(c.zoomWindow == nil && c.zoomTargetView == nil && c.zoomPanelInset == 0, "\(label).zoom.closes")
    }

    // MARK: Favorites

    static func favorites(_ editor: EditorModel) async {
        let saved = editor.tools
        var t = editor.tools
        t.favorites = []
        t.activeFavoriteID = nil
        t.tool = .pen
        t.penStyle = .fountain
        t.pen.colorIndex = 1
        editor.tools = t
        editor.selectTool(.pen)
        editor.saveCurrentAsFavorite()
        check(editor.favorites.count == 1 && editor.tools.activeFavoriteID == editor.favorites.first?.id, "favorites.save")
        let fav = editor.favorites[0]
        check(fav.style == .fountain && fav.color == editor.tools.pen.colors[1], "favorites.capturesSetup")
        editor.saveCurrentAsFavorite()
        check(editor.favorites.count == 1, "favorites.noDuplicates")
        await Automation.wait(0.4)
        await Automation.shot("favorites-toolbar")

        // Picking a color slot leaves the favorite; picking the favorite comes back.
        var u = editor.tools
        u.activeFavoriteID = nil
        u.pen.colorIndex = 0
        u.penStyle = .ballpoint
        editor.tools = u
        check(editor.tools.activeFavorite == nil, "favorites.slotLeaves")
        editor.selectTool(.eraser)
        editor.useFavorite(fav)
        await Automation.wait(0.2)
        check(editor.tools.tool == .pen && editor.tools.activeFavorite?.id == fav.id, "favorites.use")
        if let ink = editor.canvas.canvas.tool as? PKInkingTool {
            check(ink.inkType == PKInk.InkType.fountainPen && ink.color.rgba.distance(to: fav.color) < 0.02, "favorites.drawsWithIt",
                  "\(ink.inkType.rawValue)")
        } else {
            check(false, "favorites.drawsWithIt", "no inking tool")
        }
        // Changing pen type while on a favorite leaves it.
        var v = editor.tools
        v.selectPenStyle(.pencil)
        editor.tools = v
        check(editor.tools.activeFavorite == nil, "favorites.penTypeLeaves")

        // Saved with the tools, and loaded back.
        editor.useFavorite(fav)
        let reloaded = ToolState.load()
        check(reloaded.favorites?.first?.matches(fav) == true && reloaded.activeFavoriteID == fav.id, "favorites.persist")
        // Settings saved before favorites existed still load.
        if let data = try? JSONEncoder().encode(saved), var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            json.removeValue(forKey: "favorites")
            json.removeValue(forKey: "activeFavoriteID")
            let legacy = try? JSONDecoder().decode(ToolState.self, from: JSONSerialization.data(withJSONObject: json))
            check(legacy != nil && legacy?.favorites == nil, "favorites.legacySettingsLoad")
        }

        editor.removeFavorite(fav.id)
        check(editor.favorites.isEmpty && editor.tools.activeFavoriteID == nil, "favorites.remove")
        editor.tools = saved
    }
}
#endif
