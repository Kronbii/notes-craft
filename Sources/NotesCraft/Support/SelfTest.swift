import Foundation
import NotesCraftCore
import os
import PDFKit
import PencilKit
import SwiftUI
import UIKit

/// On-device self test, run when the app is launched with `-NCSelfTest`.
/// Exercises the real canvas, undo, page operations, saving, export and
/// recognition, and reports through the system log ("NCSELFTEST ...").
enum SelfTest {
    static let logger = Logger(subsystem: "com.kronbii.NotesCraft", category: "selftest")
    static var forced = false
    static var enabled: Bool { forced || ProcessInfo.processInfo.arguments.contains("-NCSelfTest") }
    static let runRequested = Notification.Name("NCSelfTestRun")
    static let openNotebook = Notification.Name("NCSelfTestOpen")
    static let closeEditor = Notification.Name("NCSelfTestClose")
    static weak var currentEditor: EditorModel?

    private static var passed = 0
    private static var failed = 0

    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failed += 1 }
        let d = detail()
        logger.error("NCSELFTEST \(ok ? "PASS" : "FAIL", privacy: .public) \(name, privacy: .public) \(d, privacy: .public)")
    }

    static func note(_ text: String) {
        logger.error("NCSELFTEST INFO \(text, privacy: .public)")
    }

    static func pause(_ ms: Int = 80) async {
        try? await Task.sleep(for: .milliseconds(ms))
    }

    static func stroke(from a: CGPoint, to b: CGPoint, width: CGFloat = 3, color: UIColor = .black, date: Date = Date()) -> PKStroke {
        var points: [PKStrokePoint] = []
        let n = 24
        for i in 0 ... n {
            let t = CGFloat(i) / CGFloat(n)
            points.append(PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                                        timeOffset: TimeInterval(i) * 0.01, size: CGSize(width: width, height: width),
                                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
        }
        return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: points, creationDate: date))
    }

    static func run() async {
        passed = 0
        failed = 0
        note("starting on iOS \(UIDevice.current.systemVersion)")
        let library = LibraryStore.shared
        var created: [UUID] = []
        do {
            // MARK: Library
            let meta = try library.createNotebook(title: "Self test", paper: PaperStyle(kind: .grid, color: .white, size: .a4, landscape: false),
                                                  cover: .default, folder: nil)
            created.append(meta.id)
            check(library.meta(meta.id) != nil, "library.create")

            let doc = try await NotebookDocument.open(id: meta.id)
            check(doc.pages.count == 1, "document.open", "pages=\(doc.pages.count)")
            let editor = EditorModel(document: doc)
            let canvas = editor.canvas!

            // MARK: Pages
            editor.addPageAtEnd()
            await pause()
            editor.insertPage(Page(size: CGSize(width: 842, height: 595), background: .paper(kind: .dotted, color: .ivory)), at: 2)
            await pause()
            check(doc.pages.count == 3, "pages.add", "count=\(doc.pages.count)")
            check(canvas.layout.pageCount == 3, "layout.count", "\(canvas.layout.pageCount)")
            check(abs(canvas.layout.contentSize.width - (842 + 2 * DocumentLayout.sidePadding)) < 0.01, "layout.width", "\(canvas.layout.contentSize.width)")

            // MARK: Ink as if drawn by the user
            var drawing = canvas.baseline
            for frame in canvas.layout.pageFrames {
                drawing.strokes.append(stroke(from: CGPoint(x: frame.minX + 60, y: frame.minY + 80), to: CGPoint(x: frame.minX + 260, y: frame.minY + 90)))
            }
            canvas.canvas.drawing = drawing // goes through the delegate like real ink
            await pause()
            check(canvas.baseline.strokes.count == 3, "ink.commit", "baseline=\(canvas.baseline.strokes.count)")
            check(editor.undoManager.canUndo, "undo.registered")
            canvas.flushInkToDocument()
            let perPage = doc.pages.map { doc.drawing(for: $0.id).strokes.count }
            check(perPage == [1, 1, 1], "ink.split", "\(perPage)")
            let local = doc.drawing(for: doc.pages[1].id).bounds
            check(local.minX > 40 && local.minX < 80 && local.minY > 60 && local.minY < 100, "ink.pageLocal", "\(local)")

            // MARK: Undo/redo of ink
            editor.undo()
            await pause()
            check(canvas.baseline.strokes.count == 0, "undo.ink", "\(canvas.baseline.strokes.count)")
            editor.redo()
            await pause()
            check(canvas.baseline.strokes.count == 3, "redo.ink", "\(canvas.baseline.strokes.count)")

            // MARK: Undone ink must not come back
            // PencilKit can finish a stroke on top of its stale copy of the
            // drawing (an undo landing while a finger stroke starts); that copy
            // still has the undone stroke.
            let f0 = canvas.layout.pageFrames[0]
            let startCount = canvas.baseline.strokes.count
            canvas.lastDrawingTool = .pen
            canvas.canvas.drawing = PKDrawing(strokes: canvas.baseline.strokes + [stroke(from: CGPoint(x: f0.minX + 60, y: f0.minY + 300), to: CGPoint(x: f0.minX + 260, y: f0.minY + 304))])
            await pause()
            let stale = canvas.canvas.drawing
            check(canvas.baseline.strokes.count == startCount + 1, "undo.stale.setup", "\(canvas.baseline.strokes.count)")
            editor.undo()
            await pause()
            check(canvas.baseline.strokes.count == startCount, "undo.stale.undo", "\(canvas.baseline.strokes.count)")
            let next = stroke(from: CGPoint(x: f0.minX + 60, y: f0.minY + 360), to: CGPoint(x: f0.minX + 260, y: f0.minY + 364))
            canvas.canvas.drawing = PKDrawing(strokes: stale.strokes + [next])
            await pause()
            check(canvas.baseline.strokes.count == startCount + 1, "undo.stale.dropped", "baseline=\(canvas.baseline.strokes.count) expected=\(startCount + 1)")
            check(canvas.canvas.drawing.strokes.count == canvas.baseline.strokes.count, "undo.stale.canvas", "\(canvas.canvas.drawing.strokes.count)")
            editor.undo()
            await pause(500)
            check(canvas.baseline.strokes.count == startCount && canvas.canvas.drawing.strokes.count == startCount, "undo.stale.clean",
                  "baseline=\(canvas.baseline.strokes.count) canvas=\(canvas.canvas.drawing.strokes.count)")

            // MARK: Scribble to erase
            let scribbleSetting = AppSettings.shared.scribbleToErase
            AppSettings.shared.scribbleToErase = true
            canvas.canvas.drawing = PKDrawing(strokes: canvas.baseline.strokes + [stroke(from: CGPoint(x: f0.minX + 80, y: f0.minY + 420), to: CGPoint(x: f0.minX + 200, y: f0.minY + 424))])
            await pause()
            check(canvas.baseline.strokes.count == startCount + 1, "scribble.setup", "\(canvas.baseline.strokes.count)")
            var scribblePoints: [PKStrokePoint] = []
            for sweep in 0 ..< 7 {
                for k in 0 ... 12 {
                    let x = sweep % 2 == 0 ? 70 + Double(k) * 12 : 214 - Double(k) * 12
                    scribblePoints.append(PKStrokePoint(location: CGPoint(x: f0.minX + x, y: f0.minY + 410 + Double(sweep) * 3 + Double(k % 3)),
                                                        timeOffset: Double(scribblePoints.count) * 0.004, size: CGSize(width: 4.6, height: 4.6),
                                                        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
                }
            }
            let scribble = PKStroke(ink: PKInk(.monoline, color: .black), path: PKStrokePath(controlPoints: scribblePoints, creationDate: Date()))
            canvas.canvas.drawing = PKDrawing(strokes: canvas.baseline.strokes + [scribble])
            await pause()
            check(canvas.baseline.strokes.count == startCount, "scribble.erase", "\(canvas.baseline.strokes.count) expected=\(startCount)")
            editor.undo()
            await pause()
            check(canvas.baseline.strokes.count == startCount + 1, "scribble.undo", "\(canvas.baseline.strokes.count)")
            editor.undo()
            await pause()
            // A scribble over empty paper is just ink.
            let emptyScribble = PKStroke(ink: PKInk(.monoline, color: .black), path: PKStrokePath(controlPoints: scribblePoints, creationDate: Date()))
            canvas.canvas.drawing = PKDrawing(strokes: canvas.baseline.strokes + [emptyScribble])
            await pause()
            check(canvas.baseline.strokes.count == startCount + 1, "scribble.emptyKeeps", "\(canvas.baseline.strokes.count)")
            editor.undo()
            await pause()
            AppSettings.shared.scribbleToErase = scribbleSetting
            check(canvas.baseline.strokes.count == startCount, "scribble.cleanup", "\(canvas.baseline.strokes.count)")

            // MARK: Move a page; its ink must follow
            let firstID = doc.pages[0].id
            editor.movePage(from: 0, to: 2)
            await pause()
            canvas.flushInkToDocument()
            check(doc.pages[2].id == firstID, "pages.move.order")
            check(doc.drawing(for: firstID).strokes.count == 1, "pages.move.ink", "\(doc.drawing(for: firstID).strokes.count)")
            let movedBounds = doc.drawing(for: firstID).bounds
            check(movedBounds.minY > 60 && movedBounds.minY < 100, "pages.move.local", "\(movedBounds)")
            editor.undo()
            await pause()
            check(doc.pages[0].id == firstID, "pages.move.undo")

            // MARK: Duplicate and delete
            editor.duplicatePage(doc.pages[0].id)
            await pause()
            check(doc.pages.count == 4 && canvas.baseline.strokes.count == 4, "pages.duplicate", "pages=\(doc.pages.count) strokes=\(canvas.baseline.strokes.count)")
            editor.deletePages([doc.pages[1].id])
            await pause()
            check(doc.pages.count == 3 && canvas.baseline.strokes.count == 3, "pages.delete", "pages=\(doc.pages.count) strokes=\(canvas.baseline.strokes.count)")
            editor.undo()
            await pause()
            check(doc.pages.count == 4, "pages.delete.undo", "\(doc.pages.count)")

            // MARK: Selection move and resize
            canvas.selectStrokes([0])
            let before = canvas.baseline.strokes[0].renderBounds
            canvas.beginDrag(.move)
            canvas.updateDrag(translation: CGPoint(x: 100 * canvas.zoom, y: 20 * canvas.zoom))
            canvas.endDrag()
            await pause()
            let after = canvas.baseline.strokes[0].renderBounds
            check(abs(after.minX - before.minX - 100) < 1 && abs(after.minY - before.minY - 20) < 1, "selection.move", "\(before) -> \(after)")
            canvas.beginDrag(.resize(corner: 2))
            canvas.updateDrag(translation: CGPoint(x: after.width * canvas.zoom, y: after.height * canvas.zoom))
            canvas.endDrag()
            await pause()
            let resized = canvas.baseline.strokes[0].renderBounds
            check(resized.width > after.width * 1.6, "selection.resize", "\(after.width) -> \(resized.width)")
            canvas.recolorSelection(RGBA(hex: "#D62E4D")!)
            await pause()
            check(canvas.baseline.strokes[0].ink.color.rgba.distance(to: RGBA(hex: "#D62E4D")!) < 0.05, "selection.recolor")
            canvas.duplicateSelection()
            await pause()
            check(canvas.baseline.strokes.count == 5, "selection.duplicate", "\(canvas.baseline.strokes.count)")
            canvas.deleteSelection()
            await pause()
            check(canvas.baseline.strokes.count == 4, "selection.delete", "\(canvas.baseline.strokes.count)")
            canvas.clearSelection()

            // MARK: Text box
            let content = TextContent(runs: [TextRun(text: "Thermodynamics lecture", size: 20)])
            let textFrame = CGRect(x: 40, y: 200, width: 300, height: TextStyling.measuredHeight(content, width: 300))
            let pageID = doc.pages[0].id
            canvas.performElementEdit("Add text", pageID: pageID) { $0.elements.append(PageElement(frame: textFrame, content: .text(content))) }
            await pause()
            check(doc.pages[0].elements.count == 1, "text.add")
            check(textFrame.height > 20 && textFrame.height < 60, "text.measure", "\(textFrame.height)")
            let round = TextStyling.content(from: TextStyling.attributedString(content, scale: 2), scale: 2, fill: nil)
            check(round.plainText == content.plainText && abs(round.runs[0].size - 20) < 0.01, "text.roundtrip", "\(round.runs.first?.size ?? -1)")

            // MARK: Image element
            let img = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { ctx in
                UIColor.systemTeal.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            }
            if let element = await ImageInsertion.element(for: img, document: doc, maxSize: CGSize(width: 300, height: 300)) {
                check(FileManager.default.fileExists(atPath: doc.assets.url(for: element.imageAsset ?? "").path), "image.asset")
                check(doc.assets.image(element.imageAsset ?? "") != nil, "image.decode")
            } else {
                check(false, "image.element")
            }

            // MARK: Shapes from real strokes
            canvas.currentTool = .shape
            let rectPoints = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 102), CGPoint(x: 301, y: 220), CGPoint(x: 99, y: 221), CGPoint(x: 101, y: 103)]
            var pts: [PKStrokePoint] = []
            for i in 0 ..< rectPoints.count - 1 {
                for k in 0 ..< 20 {
                    let t = CGFloat(k) / 20
                    let a = rectPoints[i], b = rectPoints[i + 1]
                    pts.append(PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), timeOffset: Double(pts.count) * 0.01,
                                             size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2))
                }
            }
            let rough = PKStroke(ink: PKInk(.monoline, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: Date()))
            let snapped = canvas.processNewStroke(rough)
            check(snapped != nil, "shape.snap")
            if let snapped {
                let b = snapped.renderBounds
                check(abs(b.minX - 100) < 6 && abs(b.maxX - 301) < 8, "shape.bounds", "\(b)")
            }
            canvas.currentTool = editor.tools.tool

            // MARK: Save and reload
            editor.saveNow()
            await DiskWriter.shared.flush()
            let reopened = try await NotebookDocument.open(id: meta.id)
            check(reopened.pages.count == doc.pages.count, "save.pages", "\(reopened.pages.count) vs \(doc.pages.count)")
            let a = doc.pages.map { doc.drawing(for: $0.id).strokes.count }
            let b = reopened.pages.map { reopened.drawing(for: $0.id).strokes.count }
            check(a == b, "save.ink", "\(a) vs \(b)")
            check(reopened.pages[0].elements.count == 1, "save.elements")
            check(library.meta(meta.id)?.pageCount == doc.pages.count, "save.meta", "\(library.meta(meta.id)?.pageCount ?? -1)")

            // MARK: Endless whiteboard: growing, and undo across a shift
            let boardMeta = try library.createBoard(paper: .dotted, color: .white, folder: nil)
            created.append(boardMeta.id)
            let boardDoc = try await NotebookDocument.open(id: boardMeta.id)
            let board = EditorModel(document: boardDoc)
            let bc = board.canvas!
            check(bc.isBoard && board.isBoard, "board.kind")
            let bf = bc.layout.pageFrames[0]
            bc.lastDrawingTool = .pen
            bc.canvas.drawing = PKDrawing(strokes: [stroke(from: CGPoint(x: bf.midX, y: bf.midY), to: CGPoint(x: bf.midX + 200, y: bf.midY + 10))])
            await pause()
            let firstInk = bc.baseline.strokes.first?.renderBounds ?? .null
            bc.growBoard(left: 3000, top: 2000, right: 1000, bottom: 500)
            await pause()
            let grown = boardDoc.pages[0].size
            let shift = bc.boardOrigin
            let movedInk = bc.baseline.strokes.first?.renderBounds ?? .null
            check(grown.width >= 12000 + 4000 && grown.height >= 12000 + 2500 && shift.x >= 3000 && shift.y >= 2000, "board.grow", "\(grown) shift=\(shift)")
            check(abs(movedInk.minX - firstInk.minX - shift.x) < 0.5 && abs(movedInk.minY - firstInk.minY - shift.y) < 0.5, "board.inkMoves", "\(firstInk) -> \(movedInk)")
            bc.canvas.drawing = PKDrawing(strokes: bc.baseline.strokes + [stroke(from: CGPoint(x: movedInk.minX, y: movedInk.maxY + 80), to: CGPoint(x: movedInk.maxX, y: movedInk.maxY + 90))])
            await pause()
            check(bc.baseline.strokes.count == 2, "board.inkAfterGrow")
            board.undo()
            await pause()
            let afterUndo = bc.baseline.strokes.first?.renderBounds ?? .null
            check(bc.baseline.strokes.count == 1 && abs(afterUndo.minX - movedInk.minX) < 0.5 && abs(afterUndo.minY - movedInk.minY) < 0.5, "board.undoAfterGrow", "\(afterUndo)")
            board.undo()
            await pause()
            check(bc.baseline.strokes.isEmpty, "board.undoAcrossGrow", "\(bc.baseline.strokes.count)")
            board.redo()
            await pause()
            let afterRedo = bc.baseline.strokes.first?.renderBounds ?? .null
            check(bc.baseline.strokes.count == 1 && abs(afterRedo.minX - movedInk.minX) < 0.5, "board.redoAcrossGrow", "\(afterRedo) vs \(movedInk)")
            check(boardDoc.pages[0].size == grown, "board.neverShrinks", "\(boardDoc.pages[0].size)")
            board.saveNow()
            await DiskWriter.shared.flush()
            let reopenedBoard = try await NotebookDocument.open(id: boardMeta.id)
            check(reopenedBoard.pages[0].isBoard && reopenedBoard.pages[0].size == grown, "board.reload", "\(reopenedBoard.pages[0].size)")
            let boardJob = board.exportJob()
            let boardPDF = try await ExportService.pdf(boardJob)
            if let pdf = PDFDocument(url: boardPDF), let first = pdf.page(at: 0) {
                let box = first.bounds(for: .mediaBox)
                check(box.width < 2000 && box.height < 2000, "board.exportCropped", "\(box.size)")
            } else {
                check(false, "board.export")
            }
            board.close()

            // MARK: Export
            let pdfURL = try await ExportService.pdf(editor.exportJob())
            let pdf = PDFDocument(url: pdfURL)
            check(pdf?.pageCount == doc.pages.count, "export.pdf", "pages=\(pdf?.pageCount ?? -1)")
            let size = (try? FileManager.default.attributesOfItem(atPath: pdfURL.path)[.size] as? Int) ?? 0
            check(size > 1000 && size < 5_000_000, "export.pdf.size", "\(size) bytes")
            if let page = pdf?.page(at: 0) {
                check(abs(page.bounds(for: .mediaBox).width - doc.pages[0].size.width) < 1, "export.pdf.pageSize")
            }
            let images = await ExportService.images(editor.exportJob(pageIndices: [0]))
            check(images.count == 1, "export.png")

            // MARK: Thumbnails
            let thumb = ThumbnailRenderer.render(page: doc.pages[0], drawing: doc.drawing(for: doc.pages[0].id), assets: doc.assets, maxWidth: 200)
            check(abs(thumb.size.width - 200) < 2, "thumbnail.size", "\(thumb.size)")

            // MARK: Handwriting recognition (Vision on rendered text)
            let textImage = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 200)).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 900, height: 200))
                NSAttributedString(string: "Hello NotesCraft", attributes: [.font: UIFont(name: "Noteworthy-Bold", size: 72) ?? UIFont.systemFont(ofSize: 72), .foregroundColor: UIColor.black])
                    .draw(at: CGPoint(x: 30, y: 40))
            }
            let recognized = await HandwritingRecognizer.text(from: textImage)
            check(recognized.lowercased().contains("hello"), "vision.recognize", recognized)

            // MARK: Archive round trip
            let archive = try await library.exportArchive(meta.id)
            let imported = try await library.importArchive(from: archive, folder: nil)
            created.append(contentsOf: imported.map(\.id))
            check(imported.count == 1 && imported.first?.pageCount == doc.pages.count, "archive.roundtrip", "\(imported.first?.pageCount ?? -1)")

            // MARK: Search index
            await pause(200)
            let hits = library.search.search("thermodynamics", in: library.index.activeNotebooks)
            check(hits.contains { $0.notebookID == meta.id && $0.source == .typed }, "search.typed", "\(hits.count) hits")

            // MARK: PDF import
            let pdfImported = try await library.importPDF(from: pdfURL, folder: nil)
            created.append(pdfImported.id)
            check(pdfImported.pageCount == doc.pages.count, "pdf.import", "\(pdfImported.pageCount)")
            let pdfDoc = try await NotebookDocument.open(id: pdfImported.id)
            if case let .pdf(asset, index) = pdfDoc.pages[0].background {
                check(pdfDoc.assets.pdfPage(asset, index: index) != nil, "pdf.page")
            } else {
                check(false, "pdf.background")
            }

            editor.close()
        } catch {
            check(false, "exception", error.localizedDescription)
        }

        // MARK: Live editor UI
        if let id = created.first {
            NotificationCenter.default.post(name: openNotebook, object: id)
            // Opening can take a few seconds right after launch.
            for _ in 0 ..< 40 {
                try? await Task.sleep(for: .milliseconds(200))
                if let editor = currentEditor, editor.document.id == id, editor.canvas.canvas.window != nil { break }
            }
            try? await Task.sleep(for: .seconds(1))
            if let editor = currentEditor, editor.document.id == id {
                let c = editor.canvas!
                note("ui zoom=\(c.zoom) fit=\(c.fitZoom) bounds=\(c.canvas.bounds) content=\(c.canvas.contentSize) inset=\(c.canvas.contentInset)")
                check(c.canvas.bounds.width > 300, "ui.canvasSize", "\(c.canvas.bounds)")
                check(abs(c.zoom - c.fitZoom) < 0.01, "ui.fitZoom", "\(c.zoom) vs \(c.fitZoom)")
                check(!c.pageViews.isEmpty, "ui.pageViews", "\(c.pageViews.count)")
                check(c.canvas.subviews.first === c.canvas.pageContainer, "ui.underlayOrder")
                check(c.canvas.subviews.last === c.canvas.overlay, "ui.overlayOrder")
                if let first = c.pageViews[editor.document.pages[0].id] {
                    let frameInCanvas = first.convert(first.bounds, to: c.canvas)
                    let expected = c.docToContent(c.layout.pageFrames[0])
                    check(abs(frameInCanvas.minX - expected.minX) < 1 && abs(frameInCanvas.width - expected.width) < 1, "ui.pageFrame", "\(frameInCanvas) vs \(expected)")
                }
                c.scrollToPage(2, animated: false)
                await pause(300)
                check(editor.currentPage == 2, "ui.scrollToPage", "\(editor.currentPage)")
                c.zoomToFit(animated: true)
                await pause(600)
                check(abs(c.zoom - c.fitZoom) < 0.01, "ui.zoomAnimation", "\(c.zoom)")

                // Two-finger tap: waits for a pinch to fail; a "tap" during which the
                // view zoomed (a pinch) never undoes.
                check(c.tapsWaitForPinch, "gesture.tapWaitsForPinch")
                let tf = c.layout.pageFrames[0]
                c.lastDrawingTool = .pen
                c.canvas.drawing = PKDrawing(strokes: c.baseline.strokes + [stroke(from: CGPoint(x: tf.minX + 80, y: tf.minY + 700), to: CGPoint(x: tf.minX + 260, y: tf.minY + 706))])
                await pause(200)
                let inkCount = c.baseline.strokes.count
                c.tapStart = (c.zoom * 0.6, c.canvas.contentOffset)
                c.handleTwoFingerTap()
                await pause(250)
                check(c.baseline.strokes.count == inkCount, "gesture.pinchIsNotUndo", "\(c.baseline.strokes.count) vs \(inkCount)")
                c.tapStart = (c.zoom, c.canvas.contentOffset)
                c.handleTwoFingerTap()
                await pause(250)
                check(c.baseline.strokes.count == inkCount - 1, "gesture.tapUndoes", "\(c.baseline.strokes.count)")
                check(editor.toast?.hasPrefix("Undo") == true, "gesture.undoToast", editor.toast ?? "none")

                // Typing undo: steps back through the typing, then the box; nothing undone comes back.
                func texts() -> [String] {
                    editor.document.pages[0].elements.compactMap { $0.textContent?.plainText }
                }
                editor.selectTool(.text)
                let f = c.layout.pageFrames[0]
                c.createTextBox(at: CGPoint(x: f.minX + 140, y: f.minY + 560), pageIndex: 0)
                await pause(400)
                if let tv = c.textEditor {
                    tv.insertText("Hello")
                    await pause(150)
                    tv.insertText(" world")
                    await pause(150)
                    let typingUndo = tv.undoManager?.canUndo ?? false
                    note("typing undo available: \(typingUndo) canUndo=\(editor.canUndo)")
                    check(editor.canUndo, "typing.undoButtonEnabled")
                    editor.undo()
                    await pause(150)
                    if typingUndo {
                        check(editor.isEditingText && c.textEditor?.text != "Hello world", "typing.undo", c.textEditor?.text ?? "closed")
                    }
                    for _ in 0 ..< 8 where editor.isEditingText {
                        editor.undo()
                        await pause(120)
                    }
                    check(!editor.isEditingText, "typing.undo.closes")
                    check(!texts().contains { $0.contains("Hello") }, "typing.undo.gone", "\(texts())")
                    c.createTextBox(at: CGPoint(x: f.minX + 140, y: f.minY + 620), pageIndex: 0)
                    await pause(300)
                    c.textEditor?.insertText("Again")
                    await pause(150)
                    c.endTextEditing()
                    await pause(200)
                    check(texts().contains("Again") && !texts().contains { $0.contains("Hello") }, "typing.noResurrect", "\(texts())")
                    editor.undo()
                    await pause(200)
                } else {
                    check(false, "typing.editorOpened")
                }
                editor.selectTool(.pen)
                await pause(200)

                NotificationCenter.default.post(name: closeEditor, object: nil)
                await pause(800)
            } else {
                check(false, "ui.editorOpened")
            }
        }

        library.deletePermanently(created)
        note("done passed=\(passed) failed=\(failed)")
        library.report("Diagnostics finished: \(passed) passed, \(failed) failed.")
    }
}
