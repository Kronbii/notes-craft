#if NOTESCRAFT_DEV
// Development builds only (see Package.swift).
import AVFoundation
import CoreText
import Foundation
import NotesCraftCore
import PDFKit
import PencilKit
import SwiftUI
import UIKit

/// Development remote control. While the app is open it watches
/// Documents/Automation/command.json (written over USB); each command runs a
/// scripted tour that screenshots every step into Documents/Automation/out.
enum Automation {
    static let folder = StoragePaths.documents.appendingPathComponent("Automation", isDirectory: true)
    static var commandURL: URL { folder.appendingPathComponent("command.json") }
    static weak var libraryModel: LibraryModel?
    private static var timer: Timer?
    private static var running = false
    private static var runFolder: URL?
    static var currentRunFolder: URL? { runFolder }
    private static var shotIndex = 0
    private static var logLines: [String] = []

    struct Command: Decodable {
        var scenario: String
        var steps: [String]?
    }

    static func start() {
        guard timer == nil else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let t = Timer(timeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private static func poll() {
        guard !running, UIApplication.shared.applicationState == .active else { return }
        guard let data = try? Data(contentsOf: commandURL) else { return }
        try? FileManager.default.removeItem(at: commandURL)
        guard let command = try? JSONDecoder().decode(Command.self, from: data) else { return }
        running = true
        Task {
            await run(command)
            running = false
        }
    }

    // MARK: - Output

    static func log(_ text: String) {
        logLines.append(text)
        SelfTest.logger.error("NCTOUR \(text, privacy: .public)")
        flushLog()
    }

    private static func flushLog() {
        guard let runFolder else { return }
        try? logLines.joined(separator: "\n").data(using: .utf8)?.write(to: runFolder.appendingPathComponent("log.txt"))
    }

    static func wait(_ seconds: Double = 0.9) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private static var loggedWindows = false

    /// Captures the app's own windows (system windows such as the keyboard
    /// snapshot as opaque black and would cover everything).
    static func shot(_ name: String, scale: CGFloat = 1) async {
        await wait(0.15)
        guard let runFolder else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            log("no scene")
            return
        }
        let all = scene.windows.sorted { $0.windowLevel < $1.windowLevel }
        if !loggedWindows {
            loggedWindows = true
            for w in all {
                log("window \(type(of: w)) level=\(w.windowLevel.rawValue) hidden=\(w.isHidden) key=\(w.isKeyWindow) frame=\(w.frame)")
            }
        }
        let windows = all.filter { w in
            let cls = String(describing: type(of: w))
            return !w.isHidden && w.alpha > 0.01 && w.bounds.width > 100
                && !cls.contains("Keyboard") && !cls.contains("TextEffects") && !cls.contains("Remote") && !cls.contains("Snapshot")
        }
        guard let first = windows.first ?? scene.keyWindow else { return }
        let bounds = first.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        var drew: [Bool] = []
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { ctx in
            UIColor.black.setFill()
            ctx.fill(bounds)
            for w in windows {
                drew.append(w.drawHierarchy(in: w.frame, afterScreenUpdates: true))
            }
            if !drew.contains(true) {
                // Fallback: render the layer trees directly.
                for w in windows {
                    ctx.cgContext.saveGState()
                    ctx.cgContext.translateBy(x: w.frame.minX, y: w.frame.minY)
                    w.layer.render(in: ctx.cgContext)
                    ctx.cgContext.restoreGState()
                }
            }
        }
        shotIndex += 1
        let file = runFolder.appendingPathComponent(String(format: "%02d-%@.jpg", shotIndex, name))
        try? image.jpegData(compressionQuality: 0.72)?.write(to: file)
        log("shot \(file.lastPathComponent) windows=\(windows.count) drew=\(drew)")
    }

    // MARK: - Run

    /// While testing over USB, keep the screen on for a while after each tour so
    /// the next tour can run without someone unlocking the iPad.
    private static var awakeUntil = Date.distantPast
    private static func keepAwake(minutes: Double) {
        awakeUntil = Date().addingTimeInterval(minutes * 60)
        UIApplication.shared.isIdleTimerDisabled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + minutes * 60 + 1) {
            if Date() >= awakeUntil { UIApplication.shared.isIdleTimerDisabled = false }
        }
    }

    static func run(_ command: Command) async {
        if command.scenario == "quit" {
            // Sent by scripts/dev/install.sh: iOS will not replace an app that is
            // open on screen (the installer waits for it to exit), so save and quit.
            log("quit requested for install")
            if let editor = SelfTest.currentEditor, LibraryStore.shared.isOpen(editor.document.id) {
                editor.saveForBackground()
            }
            DiskWriter.shared.flushSync()
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("command.json"))
            UIApplication.shared.isIdleTimerDisabled = false
            try? await Task.sleep(for: .milliseconds(300))
            exit(0)
        }
        keepAwake(minutes: 30)
        defer { keepAwake(minutes: 30) }
        let stamp = Int(Date().timeIntervalSince1970)
        let out = folder.appendingPathComponent("out/\(command.scenario)-\(stamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        runFolder = out
        shotIndex = 0
        logLines = []
        log("start \(command.scenario) iOS \(UIDevice.current.systemVersion) screen \(UIScreen.main.bounds.size)")
        let started = Date()
        let steps = command.steps ?? Tour.steps(for: command.scenario)
        for step in steps {
            let t0 = Date()
            await Tour.perform(step)
            log(String(format: "step %@ %.2fs", step, Date().timeIntervalSince(t0)))
        }
        log(String(format: "done in %.1fs", Date().timeIntervalSince(started)))
        try? Data("done".utf8).write(to: out.appendingPathComponent("DONE"))
        runFolder = nil
    }
}

// MARK: - Tour steps

enum Tour {
    static let tourPrefix = "Tour · "

    static func steps(for scenario: String) -> [String] {
        switch scenario {
        case "setup": return ["setup"]
        case "cleanup": return ["cleanup"]
        case "selftest": return ["selftest"]
        case "library": return ["setup", "light", "library"]
        case "editor": return ["setup", "light", "editor"]
        case "pdf": return ["setup", "light", "pdf"]
        case "inklab": return ["setup", "light", "inklab"]
        case "dark": return ["setup", "dark", "library", "editor-dark", "light"]
        case "board": return ["light", "board", "dark", "board-dark", "light"]
        case "stress": return ["light", "stress"]
        case "transcribe": return ["light", "transcribe", "dark", "transcribe", "light"]
        default: return ["setup", "light", "inklab", "library", "editor", "pdf", "board", "dark", "library-dark", "editor-dark", "board-dark", "light"]
        }
    }

    static var library: LibraryStore { LibraryStore.shared }

    static func notebook(_ title: String) -> NotebookMeta? {
        library.index.activeNotebooks.first { $0.title == tourPrefix + title }
    }

    static func perform(_ step: String) async {
        switch step {
        case "setup": await TourContent.setUp()
        case "cleanup": TourContent.cleanUp()
        case "selftest": await SelfTest.run()
        case "light": AppSettings.shared.appearance = .light; await Automation.wait(0.6)
        case "dark": AppSettings.shared.appearance = .dark; await Automation.wait(0.6)
        case "library": await libraryTour(dark: false)
        case "library-dark": await libraryTour(dark: true)
        case "editor": await editorTour(dark: false)
        case "editor-dark": await editorTour(dark: true)
        case "pdf": await pdfTour()
        case "inklab": await InkLab.run()
        case "board": await boardTour(dark: false)
        case "stress": await StressTest.run()
        case "transcribe": await TranscriptionTest.run()
        case "board-dark": await boardTour(dark: true)
        default: Automation.log("unknown step \(step)")
        }
    }

    static func closeEditorIfOpen() async {
        if let editor = SelfTest.currentEditor, LibraryStore.shared.isOpen(editor.document.id) {
            NotificationCenter.default.post(name: SelfTest.closeEditor, object: nil)
            await Automation.wait(1.0)
        }
    }

    // MARK: Library

    static func libraryTour(dark: Bool) async {
        await closeEditorIfOpen()
        guard let model = Automation.libraryModel else {
            Automation.log("no library model")
            return
        }
        let suffix = dark ? "-dark" : ""
        model.searchText = ""
        model.selection = .all
        AppSettings.shared.libraryLayout = .grid
        await Automation.wait(1.5)
        await Automation.shot("library-grid" + suffix)
        if dark { return }
        AppSettings.shared.libraryLayout = .list
        await Automation.wait()
        await Automation.shot("library-list")
        AppSettings.shared.libraryLayout = .grid
        if let folder = library.index.folders.first(where: { $0.name == "Tour Physics" }) {
            model.selection = .folder(folder.id)
            await Automation.wait()
            await Automation.shot("library-folder")
        }
        model.selection = .all
        model.searchText = "entropy"
        await Automation.wait(1.2)
        await Automation.shot("library-search-entropy")
        model.searchText = "thermodynamics"
        await Automation.wait(1.2)
        await Automation.shot("library-search-thermo")
        model.searchText = ""
        model.selection = .favorites
        await Automation.wait()
        await Automation.shot("library-favorites")
        model.selection = .trash
        await Automation.wait()
        await Automation.shot("library-trash")
        model.selection = .audio
        await Automation.wait()
        await Automation.shot("library-audio")
        model.selection = .all
        model.isSelecting = true
        for nb in library.index.activeNotebooks.prefix(2) { model.selectedIDs.insert(nb.id) }
        await Automation.wait()
        await Automation.shot("library-select-mode")
        model.endSelecting()
        model.showNewNotebook = true
        await Automation.wait(1.2)
        await Automation.shot("new-notebook-sheet")
        model.showNewNotebook = false
        await Automation.wait()
        model.showSettings = true
        await Automation.wait(1.2)
        await Automation.shot("settings-sheet")
        model.showSettings = false
        await Automation.wait()
    }

    // MARK: Editor

    static func open(_ title: String) async -> EditorModel? {
        await closeEditorIfOpen()
        guard let meta = notebook(title), let model = Automation.libraryModel else {
            Automation.log("missing notebook \(title)")
            return nil
        }
        AppSettings.shared.hasSeenEditorTips = true
        model.open(meta.id)
        for _ in 0 ..< 30 {
            await Automation.wait(0.2)
            if let editor = SelfTest.currentEditor, editor.document.id == meta.id { break }
        }
        await Automation.wait(1.2)
        return SelfTest.currentEditor
    }

    // MARK: Whiteboard and the New panel

    static func boardTour(dark: Bool) async {
        guard let model = Automation.libraryModel else { return }
        let suffix = dark ? "-dark" : ""
        await closeEditorIfOpen()
        model.newPanelShowsBoards = false
        model.showNewPanel = true
        await Automation.wait(1.0)
        await Automation.shot("new-panel" + suffix)
        model.newPanelShowsBoards = true
        await Automation.wait(0.8)
        await Automation.shot("new-panel-canvas" + suffix)
        model.showNewPanel = false
        await Automation.wait(0.8)

        // A fresh board each run, so opening it for the first time is what gets checked.
        library.deletePermanently(library.index.notebooks.filter { $0.title == Tour.tourPrefix + "Canvas" }.map(\.id))
        do { try await makeBoard() } catch { Automation.log("board setup failed \(error.localizedDescription)") }
        await Automation.shot("library-with-board" + suffix)
        guard let editor = await open("Canvas") else { return }
        let canvas = editor.canvas!
        await Automation.wait(0.8)
        await Automation.shot("board-100" + suffix)
        Automation.log("board zoom=\(canvas.zoom) min=\(canvas.canvas.minimumZoomScale) content=\(canvas.canvas.contentSize)")
        canvas.zoomToFit(animated: false)
        await Automation.wait(1.2)
        await Automation.shot("board-everything" + suffix)
        let center = CGPoint(x: canvas.layout.pageFrames[0].midX, y: canvas.layout.pageFrames[0].midY)
        canvas.setZoom(canvas.canvas.minimumZoomScale, keeping: center, at: CGPoint(x: canvas.canvas.bounds.width / 2, y: canvas.canvas.bounds.height / 2))
        await Automation.wait(1.5)
        await Automation.shot("board-min-zoom" + suffix)
        // Jump to the far top-left corner, as if scrolled there: the board must
        // grow that way, moving the content but not the view.
        if !dark {
            let before = editor.document.pages[0].size
            let corner = CGPoint(x: -canvas.canvas.contentInset.left, y: -canvas.canvas.contentInset.top)
            canvas.canvas.setContentOffset(corner, animated: false)
            canvas.ensureBoardRoom(allowShift: true)
            await Automation.wait(1.0)
            let after = editor.document.pages[0].size
            let visible = canvas.visibleDocRect
            let frame = canvas.layout.pageFrames[0]
            Automation.log("board grew \(Int(before.width))x\(Int(before.height)) -> \(Int(after.width))x\(Int(after.height)) origin=\(canvas.boardOrigin) roomLeft=\(Int(visible.minX - frame.minX)) roomTop=\(Int(visible.minY - frame.minY))")
            await Automation.shot("board-far-corner")
            canvas.fitBoardContent(maxZoom: 1, animated: false)
            await Automation.wait(1.0)
            await Automation.shot("board-after-growth")
        }
        canvas.centerBoard()
        await Automation.wait(0.8)
        if !dark {
            for tool in [ToolKind.text, .eraser, .lasso, .laser, .pen] {
                editor.selectTool(tool)
                await Automation.wait(0.6)
                await Automation.shot("board-toolbar-\(tool.rawValue)")
            }
        }
        await closeEditorIfOpen()
    }

    static func makeBoard() async throws {
        let meta = try library.createBoard(paper: .dotted, color: .white, folder: nil)
        library.rename(meta.id, to: Tour.tourPrefix + "Canvas")
        let doc = try await NotebookDocument.open(id: meta.id)
        guard var page = doc.pages.first else { return }
        let base = Date().addingTimeInterval(-300)
        var clock = 0.0
        func next() -> Date {
            clock += 0.6
            return base.addingTimeInterval(clock)
        }
        let ink = UIColor(red: 0.07, green: 0.08, blue: 0.08, alpha: 1)
        let blue = UIColor(red: 0.12, green: 0.31, blue: 0.75, alpha: 1)
        let red = UIColor(red: 0.84, green: 0.18, blue: 0.30, alpha: 1)
        let c = CGPoint(x: page.size.width / 2, y: page.size.height / 2)
        var strokes: [PKStroke] = []
        // A small mind map around the middle of the board.
        strokes += Handwriting.strokes("Launch plan", at: CGPoint(x: c.x - 150, y: c.y - 230), size: 44, color: ink, type: .fountainPen, width: 1.8, clock: next)
        strokes.append(Handwriting.ellipse(center: c, rx: 120, ry: 62, width: 2, color: blue, date: next()))
        strokes += Handwriting.strokes("Q3 launch", at: CGPoint(x: c.x - 80, y: c.y + 10), size: 26, color: blue, type: .monoline, width: 1.3, clock: next)
        let nodes: [(String, CGPoint)] = [("Design", CGPoint(x: c.x - 420, y: c.y + 220)), ("Build", CGPoint(x: c.x, y: c.y + 300)), ("Test", CGPoint(x: c.x + 420, y: c.y + 220))]
        for (word, p) in nodes {
            strokes.append(Handwriting.line(from: CGPoint(x: c.x + (p.x - c.x) * 0.25, y: c.y + 60), to: CGPoint(x: p.x, y: p.y - 40), width: 1.6, color: ink, type: .monoline, date: next()))
            strokes += Handwriting.strokes(word, at: CGPoint(x: p.x - 50, y: p.y), size: 26, color: ink, type: .monoline, width: 1.3, clock: next)
        }
        // Something far away, to check zooming out shows everything.
        strokes += Handwriting.strokes("Ideas for later", at: CGPoint(x: c.x + 1400, y: c.y - 900), size: 30, color: red, type: .monoline, width: 1.4, clock: next)
        page.elements.append(PageElement(frame: CGRect(x: c.x - 700, y: c.y - 700, width: 300, height: 90),
                                         content: .text(TextContent(runs: [TextRun(text: "Typed sticky: kickoff on Monday", family: .rounded, size: 18)], fill: RGBA(hex: "#FFF6C7")))))
        doc.replacePages([page], drawings: [page.id: PKDrawing(strokes: strokes)])
        doc.save(force: true)
        await DiskWriter.shared.flush()
        await ThumbnailRenderer.renderLibraryThumbnail(notebookID: meta.id)
        library.thumbnailUpdated(meta.id)
    }

    static func editorTour(dark: Bool) async {
        guard let editor = await open("Lecture notes") else { return }
        let suffix = dark ? "-dark" : ""
        let canvas = editor.canvas!
        editor.selectTool(.pen)
        await Automation.wait()
        await Automation.shot("editor-default" + suffix)
        editor.palette = .pen
        await Automation.wait(1.0)
        await Automation.shot("palette-pen" + suffix)
        editor.palette = nil
        await Automation.wait(0.6)
        if !dark {
            for tool in [ToolKind.highlighter, .eraser, .shape, .lasso, .text, .laser] {
                editor.selectTool(tool)
                await Automation.wait(0.7)
                await Automation.shot("tool-\(tool.rawValue)")
            }
            editor.selectTool(.highlighter)
            editor.palette = .highlighter
            await Automation.wait(1.0)
            await Automation.shot("palette-highlighter")
            editor.palette = nil
            editor.selectTool(.eraser)
            editor.palette = .eraser
            await Automation.wait(1.0)
            await Automation.shot("palette-eraser")
            editor.palette = nil
            editor.selectTool(.pen)
            await Automation.wait(0.6)
        }

        // Navigator
        editor.showNavigator = true
        await Automation.wait(1.5)
        await Automation.shot("navigator" + suffix)
        editor.showNavigator = false
        await Automation.wait(0.6)

        // Lasso selection of the first page's ink
        editor.selectTool(.lasso)
        if let frame = canvas.layout.frame(of: 0) {
            canvas.scrollToPage(0, animated: false)
            await Automation.wait(0.5)
            let r = CGRect(x: frame.minX + 30, y: frame.minY + 90, width: frame.width * 0.75, height: 170)
            canvas.selectInside([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)])
            await Automation.wait(0.8)
            await Automation.shot("selection" + suffix)
            canvas.clearSelection()
            if let el = editor.document.pages[0].elements.first(where: { $0.isText }) {
                canvas.selectElement(el.id, pageID: editor.document.pages[0].id)
                await Automation.wait(0.8)
                await Automation.shot("selection-text" + suffix)
                canvas.clearSelection()
            }
        }

        // Text editing
        editor.selectTool(.text)
        if let frame = canvas.layout.frame(of: 0) {
            canvas.createTextBox(at: CGPoint(x: frame.minX + 70, y: frame.minY + 560), pageIndex: 0)
            await Automation.wait(0.6)
            canvas.textEditor?.insertText("Typed note: the entropy of an isolated system never decreases.")
            await Automation.wait(1.2)
            await Automation.shot("text-editing" + suffix)
            canvas.endTextEditing()
            await Automation.wait(0.8)
            await Automation.shot("text-committed" + suffix)
        }
        editor.selectTool(.pen)

        if !dark {
            // Zoom levels
            if let frame = canvas.layout.frame(of: 0) {
                let target = CGPoint(x: frame.minX + 200, y: frame.minY + 160)
                canvas.setZoom(canvas.fitZoom * 3, keeping: target, at: CGPoint(x: canvas.canvas.bounds.width / 2, y: canvas.canvas.bounds.height / 2))
                await Automation.wait(1.8)
                await Automation.shot("zoom-300", scale: 1.5)
                canvas.setZoom(canvas.fitZoom * 0.45, keeping: CGPoint(x: frame.midX, y: frame.maxY), at: CGPoint(x: canvas.canvas.bounds.width / 2, y: canvas.canvas.bounds.height / 2))
                await Automation.wait(1.5)
                await Automation.shot("zoom-45")
                canvas.zoomToFit(animated: false)
                canvas.scrollToPage(0, animated: false)
                await Automation.wait(0.8)
            }
            // Page 2 and 3 (templates, image, shapes)
            editor.goToPage(1, animated: false)
            await Automation.wait(1.0)
            await Automation.shot("page-2")
            editor.goToPage(2, animated: false)
            await Automation.wait(1.0)
            await Automation.shot("page-3")
            // End of document with the add-page button
            editor.goToPage(editor.pageCount - 1, animated: false)
            canvas.canvas.setContentOffset(CGPoint(x: canvas.canvas.contentOffset.x, y: canvas.clampOffsetY(.greatestFiniteMagnitude)), animated: false)
            await Automation.wait(1.0)
            await Automation.shot("document-end")
            editor.goToPage(0, animated: false)
            await Automation.wait(0.6)
        }

        // Sheets
        for (name, sheet) in [("export", EditorSheet.export), ("page-setup", .pageSetup(pageIDs: [editor.document.pages[0].id])),
                              ("new-page", .newPage(afterIndex: 0)), ("elements", .elements), ("recordings", .recordings)] {
            if dark && name != "export" && name != "page-setup" { continue }
            editor.sheet = sheet
            await Automation.wait(1.2)
            await Automation.shot("sheet-\(name)" + suffix)
            editor.sheet = nil
            await Automation.wait(0.7)
        }

        // Find (make sure handwriting has been recognized first)
        editor.saveNow()
        await Automation.wait(8)
        for (i, page) in editor.document.pages.enumerated() {
            let lines = page.recognition?.lines ?? []
            Automation.log("recognition page \(i + 1): \(lines.count) lines \(lines.prefix(3).map(\.text))")
        }
        editor.showFind = true
        editor.findQuery = "entropy"
        editor.runFind()
        await Automation.wait(1.2)
        await Automation.shot("find-entropy" + suffix)
        if let first = editor.findResults.first {
            editor.showFindResult(first)
            await Automation.wait(1.5)
            await Automation.shot("find-result" + suffix)
        }
        editor.clearFind()
        editor.showFind = false
        await Automation.wait(0.6)
        // Remove the typed note again so repeated tours stay the same.
        editor.undo()
        await Automation.wait(0.6)

        // Audio replay
        if let rec = editor.recordings.first {
            editor.goToPage(0, animated: false)
            editor.play(rec)
            await Automation.wait(0.3)
            editor.audio.seek(to: rec.duration * 0.45)
            await Automation.wait(1.2)
            editor.audio.pause()
            await Automation.wait(0.5)
            await Automation.shot("audio-replay" + suffix)
            editor.closeAudioBar()
            await Automation.wait(0.6)
        }
        await closeEditorIfOpen()
    }

    static func pdfTour() async {
        guard let editor = await open("Physics textbook") else { return }
        let canvas = editor.canvas!
        await Automation.shot("pdf-default")
        editor.showNavigator = true
        await Automation.wait(1.5)
        await Automation.shot("pdf-navigator")
        editor.showNavigator = false
        editor.showFind = true
        editor.findQuery = "entropy"
        editor.runFind()
        await Automation.wait(1.5)
        await Automation.shot("pdf-find")
        if let result = editor.findResults.first(where: { $0.source == .pdf }) {
            editor.showFindResult(result)
            await Automation.wait(2.0)
            await Automation.shot("pdf-find-result")
        }
        editor.findQuery = "second law heat"
        editor.runFind()
        await Automation.wait(1.5)
        await Automation.shot("pdf-find-multi")
        editor.clearFind()
        editor.showFind = false
        // Annotate the PDF
        if let frame = canvas.layout.frame(of: 0) {
            canvas.setZoom(canvas.fitZoom * 2, keeping: CGPoint(x: frame.minX + 150, y: frame.minY + 200), at: CGPoint(x: 300, y: 300))
            await Automation.wait(1.8)
            await Automation.shot("pdf-zoom-200", scale: 1.5)
            canvas.zoomToFit(animated: false)
        }
        await closeEditorIfOpen()
    }
}

// MARK: - Test content

enum TourContent {
    static var library: LibraryStore { LibraryStore.shared }

    static func cleanUp() {
        let ids = library.index.notebooks.filter { $0.title.hasPrefix(Tour.tourPrefix) }.map(\.id)
        library.deletePermanently(ids)
        if let folder = library.index.folders.first(where: { $0.name == "Tour Physics" }) { library.deleteFolder(folder.id) }
        library.emptyTrash()
    }

    static func setUp() async {
        if Tour.notebook("Lecture notes") != nil, Tour.notebook("Physics textbook") != nil,
           UserDefaults.standard.integer(forKey: "tourContentVersion") >= 3 {
            Automation.log("content exists")
            return
        }
        cleanUp()
        let folder = library.createFolder(name: "Tour Physics", parent: nil, color: .ocean)
        do {
            try await makeLectureNotes(folder: folder.id)
            try await makeTextbook(folder: folder.id)
            for (title, color, pattern) in [("Biology", CoverColor.forest, CoverPattern.dots), ("Sketchbook", .clay, .plain),
                                            ("Meeting minutes", .slate, .stripes), ("French vocabulary", .rose, .grid)] {
                let meta = try library.createNotebook(title: Tour.tourPrefix + title, paper: PaperStyle(kind: .collegeRuled), cover: .design(color: color, pattern: pattern), folder: nil)
                if title == "Biology" { library.setFavorite([meta.id], true) }
            }
            let trashMe = try library.createNotebook(title: Tour.tourPrefix + "Old draft", paper: .default, cover: .design(color: .stone, pattern: .linen), folder: nil)
            library.trash([trashMe.id])
            UserDefaults.standard.set(3, forKey: "tourContentVersion")
            Automation.log("content created")
        } catch {
            Automation.log("setup failed \(error.localizedDescription)")
        }
    }

    // MARK: Lecture notes: handwriting, highlighter, shapes, text, image, audio

    static func makeLectureNotes(folder: UUID) async throws {
        let meta = try library.createNotebook(title: Tour.tourPrefix + "Lecture notes", paper: PaperStyle(kind: .collegeRuled, color: .white, size: .a4),
                                              cover: .design(color: .sage, pattern: .linen), folder: folder)
        library.setFavorite([meta.id], true)
        let doc = try await NotebookDocument.open(id: meta.id)
        let a4 = PageSizePreset.a4.portraitSize
        var pages = [
            Page(size: a4, background: .paper(kind: .collegeRuled, color: .white)),
            Page(size: a4, background: .paper(kind: .grid, color: .ivory)),
            Page(size: a4, background: .paper(kind: .cornell, color: .white)),
            Page(size: a4, background: .paper(kind: .dotted, color: .dark)),
        ]
        let base = Date().addingTimeInterval(-600)
        var clock = 0.0
        func next() -> Date {
            clock += 0.35
            return base.addingTimeInterval(clock)
        }
        let ink = UIColor(red: 0.07, green: 0.08, blue: 0.08, alpha: 1)
        let blue = UIColor(red: 0.12, green: 0.31, blue: 0.75, alpha: 1)
        let red = UIColor(red: 0.84, green: 0.18, blue: 0.3, alpha: 1)

        // Page 1
        var p1: [PKStroke] = []
        p1 += Handwriting.strokes("Thermodynamics", at: CGPoint(x: 90, y: 118), size: 34, color: blue, type: .fountainPen, width: 1.8, clock: next)
        p1 += Handwriting.underline(from: CGPoint(x: 90, y: 128), length: 260, color: blue, date: next())
        let lines = ["First law: energy is conserved", "dU = dQ - dW", "Second law: entropy increases",
                     "Heat flows from hot to cold", "Carnot efficiency = 1 - Tc/Th"]
        for (i, line) in lines.enumerated() {
            p1 += Handwriting.strokes(line, at: CGPoint(x: 92, y: 190 + Double(i) * 40.8), size: 21, color: i == 2 ? red : ink, type: .monoline, width: 1.25, clock: next)
        }
        // Highlight the second law
        p1.append(Handwriting.line(from: CGPoint(x: 88, y: 266), to: CGPoint(x: 360, y: 266), width: 15, color: UIColor(red: 1, green: 0.89, blue: 0.36, alpha: 1), type: .marker, date: next()))
        // Shapes: boxed formula and a circle
        p1.append(Handwriting.polygon([CGPoint(x: 84, y: 214), CGPoint(x: 230, y: 214), CGPoint(x: 230, y: 246), CGPoint(x: 84, y: 246)], width: 1.6, color: red, date: next()))
        p1.append(Handwriting.ellipse(center: CGPoint(x: 450, y: 360), rx: 52, ry: 52, width: 1.8, color: blue, date: next()))
        p1 += Handwriting.strokes("system", at: CGPoint(x: 420, y: 366), size: 17, color: blue, type: .monoline, width: 1.1, clock: next)
        p1.append(Handwriting.line(from: CGPoint(x: 330, y: 360), to: CGPoint(x: 396, y: 360), width: 1.6, color: ink, type: .monoline, date: next()))
        pages[0].elements.append(PageElement(frame: CGRect(x: 90, y: 430, width: 380, height: 60),
                                             content: .text(TextContent(runs: [TextRun(text: "Exam: Thursday 9:00, chapters 3–5", family: .system, size: 18, bold: true, color: RGBA(hex: "#4D6B40")!)],
                                                                        fill: RGBA(hex: "#FFF6C7")))))
        pages[0].elements[0].frame.size.height = TextStyling.measuredHeight(pages[0].elements[0].textContent!, width: 380)
        pages[0].bookmarked = true

        // Page 2: diagram image + labels
        var p2: [PKStroke] = []
        p2 += Handwriting.strokes("PV diagram", at: CGPoint(x: 80, y: 90), size: 28, color: ink, type: .fountainPen, width: 1.6, clock: next)
        let diagram = Handwriting.diagramImage()
        if let data = diagram.pngData(), let name = try? await doc.addAsset(data: data, ext: "png") {
            pages[1].elements.append(PageElement(frame: CGRect(x: 80, y: 130, width: 300, height: 220), content: .image(asset: name)))
        }
        p2 += Handwriting.strokes("isothermal", at: CGPoint(x: 400, y: 200), size: 17, color: red, type: .monoline, width: 1.1, clock: next)
        p2.append(Handwriting.line(from: CGPoint(x: 396, y: 195), to: CGPoint(x: 330, y: 230), width: 1.4, color: red, type: .monoline, date: next()))

        // Page 3: Cornell
        var p3: [PKStroke] = []
        p3 += Handwriting.strokes("Entropy", at: CGPoint(x: 30, y: 140), size: 20, color: ink, type: .monoline, width: 1.2, clock: next)
        p3 += Handwriting.strokes("S = Q / T", at: CGPoint(x: 200, y: 140), size: 20, color: ink, type: .monoline, width: 1.2, clock: next)
        p3 += Handwriting.strokes("measure of disorder", at: CGPoint(x: 200, y: 181), size: 18, color: blue, type: .monoline, width: 1.1, clock: next)
        p3 += Handwriting.strokes("Summary: entropy never decreases", at: CGPoint(x: 40, y: 720), size: 19, color: ink, type: .monoline, width: 1.2, clock: next)

        // Page 4: dark paper with light ink
        var p4: [PKStroke] = []
        p4 += Handwriting.strokes("Night study", at: CGPoint(x: 80, y: 120), size: 30, color: UIColor(red: 0.95, green: 0.95, blue: 0.92, alpha: 1), type: .fountainPen, width: 1.6, clock: next)
        p4 += Handwriting.strokes("ideal gas: PV = nRT", at: CGPoint(x: 80, y: 180), size: 20, color: UIColor(red: 0.72, green: 0.83, blue: 0.66, alpha: 1), type: .monoline, width: 1.2, clock: next)

        var drawings: [UUID: PKDrawing] = [:]
        for (i, strokes) in [p1, p2, p3, p4].enumerated() { drawings[pages[i].id] = PKDrawing(strokes: strokes) }
        doc.replacePages(pages, drawings: drawings)

        // A recording that covers the time the ink was written.
        let total = max(clock + 5, 30)
        let audioName = "rec-\(UUID().uuidString).caf"
        try Handwriting.silentAudio(url: doc.assets.url(for: audioName), seconds: total)
        doc.content.recordings = [Recording(asset: audioName, title: "Lecture 4", createdAt: base, duration: total,
                                            segments: [.init(wallStart: base, mediaStart: 0, duration: total)])]
        doc.markContentChanged()
        doc.save(force: true)
        await DiskWriter.shared.flush()
        await ThumbnailRenderer.renderLibraryThumbnail(notebookID: meta.id)
        library.thumbnailUpdated(meta.id)
    }

    // MARK: Textbook PDF with real text and an outline

    static func makeTextbook(folder: UUID) async throws {
        let url = StoragePaths.freshExportFolder().appendingPathComponent("Physics textbook.pdf")
        let chapters: [(String, [String])] = [
            ("1 Energy", ["Energy is the capacity to do work. The first law of thermodynamics states that energy cannot be created or destroyed, only converted from one form to another.",
                          "Internal energy U changes when heat Q flows into a system or the system does work W on its surroundings."]),
            ("2 Heat and temperature", ["Temperature measures the average kinetic energy of particles. Heat is energy transferred because of a temperature difference.",
                                        "Heat always flows spontaneously from a hotter body to a colder one; this observation is one statement of the second law."]),
            ("3 Entropy", ["Entropy is a measure of the number of microscopic arrangements consistent with a macroscopic state.",
                           "The second law of thermodynamics: the entropy of an isolated system never decreases. Reversible processes keep entropy constant.",
                           "For heat Q added reversibly at temperature T, the change in entropy is Q divided by T."]),
            ("4 Engines", ["A heat engine converts heat into work. The Carnot engine sets the upper limit on efficiency: one minus the ratio of cold to hot temperatures.",
                           "No real engine reaches Carnot efficiency because real processes generate entropy."]),
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { ctx in
            for (title, paragraphs) in chapters {
                ctx.beginPage()
                NSAttributedString(string: title, attributes: [.font: UIFont.systemFont(ofSize: 28, weight: .bold)]).draw(at: CGPoint(x: 72, y: 72))
                var y: CGFloat = 130
                for p in paragraphs {
                    let s = NSAttributedString(string: p, attributes: [.font: UIFont(name: "Georgia", size: 14) ?? UIFont.systemFont(ofSize: 14)])
                    let r = s.boundingRect(with: CGSize(width: 468, height: 1000), options: [.usesLineFragmentOrigin], context: nil)
                    s.draw(with: CGRect(x: 72, y: y, width: 468, height: r.height + 4), options: [.usesLineFragmentOrigin], context: nil)
                    y += r.height + 18
                }
                NSAttributedString(string: "Physics · \(title)", attributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.gray]).draw(at: CGPoint(x: 72, y: 750))
            }
        }
        guard let pdf = PDFDocument(data: data) else { return }
        let root = PDFOutline()
        for (i, chapter) in chapters.enumerated() {
            guard let page = pdf.page(at: i) else { continue }
            let item = PDFOutline()
            item.label = chapter.0
            item.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 792))
            root.insertChild(item, at: i)
        }
        pdf.outlineRoot = root
        pdf.write(to: url)
        let meta = try await library.importPDF(from: url, folder: folder)
        library.rename(meta.id, to: Tour.tourPrefix + "Physics textbook")
        await Automation.wait(1.5)
    }
}

// MARK: - Synthetic handwriting

enum Handwriting {
    /// Letter outlines of a string in a handwriting-style font, as pen strokes.
    static func strokes(_ text: String, at origin: CGPoint, size: CGFloat, color: UIColor, type: PKInk.InkType, width: CGFloat, clock: () -> Date) -> [PKStroke] {
        let font = CTFontCreateWithName(("Noteworthy-Light" as CFString), size, nil)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        var strokes: [PKStroke] = []
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        let ink = PKInk(type, color: color)
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for i in 0 ..< count {
                guard let path = CTFontCreatePathForGlyph(font, glyphs[i], nil) else { continue }
                // Glyph space is y-up; flip into page space.
                var t = CGAffineTransform(translationX: origin.x + positions[i].x, y: origin.y).scaledBy(x: 1, y: -1)
                guard let placed = path.copy(using: &t) else { continue }
                let date = clock()
                for poly in flatten(placed) where poly.count > 1 {
                    let jittered = poly.enumerated().map { j, p in
                        CGPoint(x: p.x + sin(Double(j) * 0.7) * 0.15, y: p.y + cos(Double(j) * 0.9) * 0.15)
                    }
                    strokes.append(stroke(jittered, width: width, ink: ink, date: date))
                }
            }
        }
        return strokes
    }

    static func flatten(_ path: CGPath) -> [[CGPoint]] {
        var polys: [[CGPoint]] = []
        var current: [CGPoint] = []
        var last = CGPoint.zero
        var start = CGPoint.zero
        path.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint:
                if current.count > 1 { polys.append(current) }
                current = [e.points[0]]
                last = e.points[0]
                start = last
            case .addLineToPoint:
                current.append(e.points[0])
                last = e.points[0]
            case .addQuadCurveToPoint:
                let c = e.points[0], p = e.points[1]
                for k in 1 ... 6 {
                    let t = CGFloat(k) / 6
                    let x = (1 - t) * (1 - t) * last.x + 2 * (1 - t) * t * c.x + t * t * p.x
                    let y = (1 - t) * (1 - t) * last.y + 2 * (1 - t) * t * c.y + t * t * p.y
                    current.append(CGPoint(x: x, y: y))
                }
                last = p
            case .addCurveToPoint:
                let c1 = e.points[0], c2 = e.points[1], p = e.points[2]
                for k in 1 ... 8 {
                    let t = CGFloat(k) / 8
                    let mt = 1 - t
                    let x = mt * mt * mt * last.x + 3 * mt * mt * t * c1.x + 3 * mt * t * t * c2.x + t * t * t * p.x
                    let y = mt * mt * mt * last.y + 3 * mt * mt * t * c1.y + 3 * mt * t * t * c2.y + t * t * t * p.y
                    current.append(CGPoint(x: x, y: y))
                }
                last = p
            case .closeSubpath:
                current.append(start)
                if current.count > 1 { polys.append(current) }
                current = []
            @unknown default:
                break
            }
        }
        if current.count > 1 { polys.append(current) }
        return polys
    }

    static func stroke(_ points: [CGPoint], width: CGFloat, ink: PKInk, date: Date) -> PKStroke {
        // Real Pencil strokes store point sizes well above the toolbar width
        // (about 1.8x); very small point sizes render almost invisibly live.
        let w = max(width * 1.8, 2.4)
        let pts = points.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: CGSize(width: w, height: w), opacity: 1, force: 1, azimuth: 0.8, altitude: 0.95)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: pts, creationDate: date))
    }

    static func line(from a: CGPoint, to b: CGPoint, width: CGFloat, color: UIColor, type: PKInk.InkType, date: Date) -> PKStroke {
        let n = max(4, Int(hypot(b.x - a.x, b.y - a.y) / 3))
        let pts = (0 ... n).map { i -> CGPoint in
            let t = CGFloat(i) / CGFloat(n)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t + sin(t * 9) * 0.6)
        }
        return stroke(pts, width: width, ink: PKInk(type, color: color), date: date)
    }

    static func underline(from a: CGPoint, length: CGFloat, color: UIColor, date: Date) -> [PKStroke] {
        [line(from: a, to: CGPoint(x: a.x + length, y: a.y + 2), width: 1.6, color: color, type: .monoline, date: date)]
    }

    static func polygon(_ corners: [CGPoint], width: CGFloat, color: UIColor, date: Date) -> PKStroke {
        let outline = RecognizedShape.polygon(corners).outline(spacing: 2)
        return stroke(outline, width: width, ink: PKInk(.monoline, color: color), date: date)
    }

    static func ellipse(center: CGPoint, rx: CGFloat, ry: CGFloat, width: CGFloat, color: UIColor, date: Date) -> PKStroke {
        let outline = RecognizedShape.ellipse(center: center, radiusX: rx, radiusY: ry, rotation: 0).outline(spacing: 2)
        return stroke(outline, width: width, ink: PKInk(.monoline, color: color), date: date)
    }

    static func diagramImage() -> UIImage {
        let size = CGSize(width: 600, height: 440)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let c = ctx.cgContext
            c.setStrokeColor(UIColor.darkGray.cgColor)
            c.setLineWidth(3)
            c.move(to: CGPoint(x: 60, y: 30)); c.addLine(to: CGPoint(x: 60, y: 400)); c.addLine(to: CGPoint(x: 570, y: 400)); c.strokePath()
            c.setStrokeColor(UIColor.systemBlue.cgColor)
            c.setLineWidth(5)
            c.move(to: CGPoint(x: 100, y: 60))
            c.addCurve(to: CGPoint(x: 520, y: 330), control1: CGPoint(x: 180, y: 300), control2: CGPoint(x: 330, y: 330))
            c.strokePath()
            c.setStrokeColor(UIColor.systemRed.cgColor)
            c.move(to: CGPoint(x: 140, y: 40))
            c.addCurve(to: CGPoint(x: 540, y: 260), control1: CGPoint(x: 230, y: 220), control2: CGPoint(x: 380, y: 260))
            c.strokePath()
            NSAttributedString(string: "P", attributes: [.font: UIFont.boldSystemFont(ofSize: 30)]).draw(at: CGPoint(x: 20, y: 30))
            NSAttributedString(string: "V", attributes: [.font: UIFont.boldSystemFont(ofSize: 30)]).draw(at: CGPoint(x: 540, y: 400))
        }
    }

    static func silentAudio(url: URL, seconds: Double) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100) else { return }
        buffer.frameLength = 44100
        if let ch = buffer.floatChannelData?[0] {
            for i in 0 ..< 44100 { ch[i] = Float(sin(Double(i) * 0.05) * 0.002) }
        }
        for _ in 0 ..< Int(seconds.rounded(.up)) { try file.write(from: buffer) }
    }
}


// MARK: - Ink lab

/// Renders strokes built in different ways side by side, to find which
/// stroke-point attributes the live canvas needs, and logs real strokes.
enum InkLab {
    static func run() async {
        await Tour.closeEditorIfOpen()
        let library = LibraryStore.shared
        // 1. Log attributes of real strokes the user drew.
        var logged = 0
        for meta in library.index.activeNotebooks where !meta.title.hasPrefix(Tour.tourPrefix) {
            guard let doc = try? await NotebookDocument.open(id: meta.id) else { continue }
            for page in doc.pages {
                for stroke in doc.drawing(for: page.id).strokes.prefix(6) where logged < 12 {
                    let pts = Array(stroke.path.prefix(3))
                    let desc = pts.map { p in
                        String(format: "size=%.2fx%.2f op=%.2f f=%.2f az=%.2f alt=%.2f ss=%.2f t=%.3f", p.size.width, p.size.height, p.opacity, p.force, p.azimuth, p.altitude, p.secondaryScale, p.timeOffset)
                    }.joined(separator: " | ")
                    let age = Int(Date().timeIntervalSince(stroke.path.creationDate))
                    Automation.log("realstroke ink=\(stroke.ink.inkType.rawValue) n=\(stroke.path.count) ageSeconds=\(age) \(desc)")
                    logged += 1
                }
            }
            if logged >= 12 { break }
        }
        if logged == 0 { Automation.log("realstroke none found") }

        for type in [PKInk.InkType.pen, .monoline, .fountainPen, .marker, .pencil, .crayon, .watercolor] {
            Automation.log("validWidthRange \(type.rawValue): \(type.validWidthRange)")
        }
        if #available(iOS 26, *) {
            Automation.log("validWidthRange reed: \(PKInk.InkType.reed.validWidthRange)")
        }
        // 2. Variants on a fresh page.
        let existing = library.index.activeNotebooks.filter { $0.title == Tour.tourPrefix + "Ink lab" }.map(\.id)
        library.deletePermanently(existing)
        guard let meta = try? library.createNotebook(title: Tour.tourPrefix + "Ink lab", paper: PaperStyle(kind: .blank), cover: .default, folder: nil),
              let doc = try? await NotebookDocument.open(id: meta.id) else { return }
        var page = Page(size: PageSizePreset.a4.portraitSize, background: .paper(kind: .blank, color: .white))
        var strokes: [PKStroke] = []
        func wave(_ y: CGFloat) -> [CGPoint] {
            (0 ... 80).map { i in CGPoint(x: 150 + CGFloat(i) * 5, y: y + sin(CGFloat(i) / 6) * 8) }
        }
        struct Variant { var label: String; var make: (CGFloat) -> PKStroke }
        let black = UIColor(red: 0.07, green: 0.08, blue: 0.08, alpha: 1)
        func pts(_ ps: [CGPoint], size: CGFloat, op: CGFloat, f: CGFloat, az: CGFloat, alt: CGFloat, ss: CGFloat?, dt: Double) -> [PKStrokePoint] {
            ps.enumerated().map { i, p in
                if let ss {
                    return PKStrokePoint(location: p, timeOffset: Double(i) * dt, size: CGSize(width: size, height: size), opacity: op, force: f, azimuth: az, altitude: alt, secondaryScale: ss)
                }
                return PKStrokePoint(location: p, timeOffset: Double(i) * dt, size: CGSize(width: size, height: size), opacity: op, force: f, azimuth: az, altitude: alt)
            }
        }
        let variants: [Variant] = [
            Variant(label: "1 monoline old-init alt90") { y in PKStroke(ink: PKInk(.monoline, color: black), path: PKStrokePath(controlPoints: pts(wave(y), size: 3, op: 1, f: 1, az: 0, alt: .pi / 2, ss: nil, dt: 0.01), creationDate: Date())) },
            Variant(label: "2 monoline ss=1") { y in PKStroke(ink: PKInk(.monoline, color: black), path: PKStrokePath(controlPoints: pts(wave(y), size: 3, op: 1, f: 1, az: 0, alt: .pi / 2, ss: 1, dt: 0.01), creationDate: Date())) },
            Variant(label: "3 monoline realistic") { y in PKStroke(ink: PKInk(.monoline, color: black), path: PKStrokePath(controlPoints: pts(wave(y), size: 3, op: 1, f: 0.9, az: 0.8, alt: 0.95, ss: 1, dt: 0.008), creationDate: Date())) },
            Variant(label: "4 monoline op=2") { y in PKStroke(ink: PKInk(.monoline, color: black), path: PKStrokePath(controlPoints: pts(wave(y), size: 3, op: 2, f: 1, az: 0.8, alt: 0.95, ss: 1, dt: 0.008), creationDate: Date())) },
            Variant(label: "5 pen old-init") { y in PKStroke(ink: PKInk(.pen, color: black), path: PKStrokePath(controlPoints: pts(wave(y), size: 3, op: 1, f: 1, az: 0, alt: .pi / 2, ss: nil, dt: 0.01), creationDate: Date())) },
            Variant(label: "6 fountain realistic") { y in PKStroke(ink: PKInk(.fountainPen, color: black), path: PKStrokePath(controlPoints: pts(wave(y), size: 3, op: 1, f: 1, az: 0.8, alt: 0.95, ss: 1, dt: 0.008), creationDate: Date())) },
            Variant(label: "7 pencil realistic") { y in PKStroke(ink: PKInk(.pencil, color: black), path: PKStrokePath(controlPoints: pts(wave(y), size: 3, op: 1, f: 1, az: 0.8, alt: 0.95, ss: 1, dt: 0.008), creationDate: Date())) },
            Variant(label: "8 marker") { y in PKStroke(ink: PKInk(.marker, color: .systemYellow), path: PKStrokePath(controlPoints: pts(wave(y), size: 14, op: 1, f: 1, az: 0, alt: .pi / 2, ss: nil, dt: 0.01), creationDate: Date())) },
            Variant(label: "9a monoline w=1.2") { y in PKStroke(ink: PKInk(.monoline, color: black), path: PKStrokePath(controlPoints: pts(wave(y), size: 1.2, op: 1, f: 1, az: 0.8, alt: 0.95, ss: 1, dt: 0.008), creationDate: Date())) },
            Variant(label: "9b monoline w=1.8") { y in PKStroke(ink: PKInk(.monoline, color: black), path: PKStrokePath(controlPoints: pts(wave(y), size: 1.8, op: 1, f: 1, az: 0.8, alt: 0.95, ss: 1, dt: 0.008), creationDate: Date())) },
            Variant(label: "9c monoline old date") { y in PKStroke(ink: PKInk(.monoline, color: black), path: PKStrokePath(controlPoints: pts(wave(y), size: 3, op: 1, f: 1, az: 0.8, alt: 0.95, ss: 1, dt: 0.008), creationDate: Date().addingTimeInterval(-86400))) },
            Variant(label: "9 monoline via tool ink") { y in
                let tool = PKInkingTool(.monoline, color: black, width: 3)
                return PKStroke(ink: tool.ink, path: PKStrokePath(controlPoints: pts(wave(y), size: 3, op: 1, f: 1, az: 0.8, alt: 0.95, ss: 1, dt: 0.008), creationDate: Date()))
            },
        ]
        for (i, v) in variants.enumerated() {
            let y = 60 + CGFloat(i) * 48
            strokes.append(v.make(y))
            let label = TextContent(runs: [TextRun(text: v.label, size: 10, color: RGBA(hex: "#666666")!)])
            page.elements.append(PageElement(frame: CGRect(x: 20, y: y - 10, width: 125, height: 30), content: .text(label)))
        }
        // 10. A real stroke cloned and rebuilt from its own points.
        var real: PKStroke?
        for m in library.index.activeNotebooks where !m.title.hasPrefix(Tour.tourPrefix) {
            guard let d = try? await NotebookDocument.open(id: m.id) else { continue }
            var all: [PKStroke] = []
            for pg in d.pages { all.append(contentsOf: d.drawing(for: pg.id).strokes) }
            let wanted: Set<PKInk.InkType> = [.monoline, .pen]
            if let s = all.first(where: { wanted.contains($0.ink.inkType) }) {
                real = s
                break
            }
        }
        if let real {
            let b = real.renderBounds
            let move = CGAffineTransform(translationX: 150 - b.minX, y: 700 - b.minY)
            var clone = real
            clone.transform = real.transform.concatenating(move)
            strokes.append(clone)
            let rebuilt = PKStroke(ink: real.ink, path: PKStrokePath(controlPoints: Array(real.path), creationDate: real.path.creationDate),
                                   transform: real.transform.concatenating(move).concatenating(CGAffineTransform(translationX: 200, y: 0)), mask: nil)
            strokes.append(rebuilt)
            page.elements.append(PageElement(frame: CGRect(x: 20, y: 690, width: 125, height: 30), content: .text(TextContent(runs: [TextRun(text: "10 real: clone | rebuilt", size: 10, color: RGBA(hex: "#666666")!)]))))
        }
        doc.replacePages([page], drawings: [page.id: PKDrawing(strokes: strokes)])
        doc.save(force: true)
        await DiskWriter.shared.flush()
        guard let editor = await Tour.open("Ink lab") else { return }
        await Automation.wait(2.5)
        await Automation.shot("inklab", scale: 1.5)
        // Where does PencilKit put its ink relative to our page tiles?
        let cv = editor.canvas.canvas
        func describe(_ v: UIView, depth: Int) {
            guard depth < 4 else { return }
            let pad = String(repeating: "  ", count: depth)
            Automation.log("view\(pad) \(type(of: v)) frame=\(v.frame.integral) hidden=\(v.isHidden) opaque=\(v.isOpaque) layers=\(v.layer.sublayers?.count ?? 0) layerClass=\(type(of: v.layer))")
            for sub in v.subviews { describe(sub, depth: depth + 1) }
        }
        describe(cv, depth: 0)
        for (i, l) in (cv.layer.sublayers ?? []).enumerated() {
            Automation.log("canvas sublayer \(i): \(type(of: l)) delegate=\(l.delegate.map { String(describing: type(of: $0)) } ?? "-") z=\(l.zPosition)")
        }
        cv.pageContainer.isHidden = true
        cv.deskMask.isHidden = true
        await Automation.wait(1.0)
        await Automation.shot("inklab-no-paper", scale: 1.5)
        cv.pageContainer.isHidden = false
        cv.deskMask.isHidden = false
        await Automation.wait(0.5)
        editor.canvas.setZoom(editor.canvas.fitZoom * 2.5, keeping: CGPoint(x: 300, y: 300), at: CGPoint(x: 500, y: 350))
        await Automation.wait(2.5)
        await Automation.shot("inklab-zoom", scale: 1.5)
        // Same drawing rendered as an image, for comparison.
        let image = PageRenderer.image(page: doc.pages[0], drawing: doc.drawing(for: doc.pages[0].id), assets: doc.assets, scale: 1.5)
        if let runFolder = Automation.currentRunFolder, let data = image.jpegData(compressionQuality: 0.8) {
            try? data.write(to: runFolder.appendingPathComponent("inklab-image-render.jpg"))
        }
        await Tour.closeEditorIfOpen()
    }
}
#endif
