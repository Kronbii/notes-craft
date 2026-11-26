import NotesCraftCore
import Observation
import PencilKit
import SwiftUI
import UIKit

enum EditorSheet: Identifiable {
    case pageSetup(pageIDs: [UUID])
    case newPage(afterIndex: Int)
    case export
    case find
    case recordings
    case convertedText(String)
    case notebookSettings
    case elements

    var id: String {
        switch self {
        case .pageSetup: "pageSetup"
        case .newPage: "newPage"
        case .export: "export"
        case .find: "find"
        case .recordings: "recordings"
        case .convertedText: "convertedText"
        case .notebookSettings: "notebookSettings"
        case .elements: "elements"
        }
    }
}


@Observable
final class EditorModel {
    let document: NotebookDocument
    let undoManager = UndoManager()
    let audio: AudioController
    let thumbnails = PageThumbnailStore()

    @ObservationIgnored private(set) var canvas: CanvasController!
    @ObservationIgnored private var indexer: InkIndexer!
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var toastWork: DispatchWorkItem?
    @ObservationIgnored private var zoomBadgeWork: DispatchWorkItem?
    @ObservationIgnored private var closed = false

    var tools: ToolState {
        didSet {
            guard tools != oldValue else { return }
            tools.save()
            canvas?.applyTool(tools)
        }
    }

    var currentPage = 0
    var canUndo = false
    var canRedo = false
    var showNavigator = false
    var navigatorBookmarksOnly = false
    var hasSelection = false
    var isEditingText = false
    var zoomBadge: Int?
    var toast: String?
    var palette: ToolKind? {
        didSet { if palette != nil { editingColorSlot = nil; editingWidthSlot = nil } }
    }
    /// Which favorite color / thickness slot is being edited (popover).
    var editingColorSlot: Int?
    var editingWidthSlot: Int?
    var sheet: EditorSheet?
    var busyMessage: String?
    var errorMessage: String?
    var replayEnabled = true
    var showAudioBar = false {
        didSet {
            // The whiteboard minimap moves up to make room for the player.
            if oldValue != showAudioBar { canvas?.setMiniMapBottomInset(showAudioBar ? 84 : 16) }
        }
    }
    var selectedRecordingID: UUID?
    var findQuery = ""
    var findResults: [FindResult] = []
    var currentFindIndex: Int?
    var isSearching = false
    @ObservationIgnored private var findTask: Task<Void, Never>?
    @ObservationIgnored private lazy var pdfSearcher = PDFTextSearcher(folder: StoragePaths.assets(document.id))
    var isReadOnly = false
    var isReplaying = false
    var showFind = false
    var rulerActive = false {
        didSet { canvas?.canvas.isRulerActive = rulerActive }
    }

    init(document: NotebookDocument) {
        self.document = document
        self.tools = ToolState.load()
        self.audio = AudioController(assetsFolder: StoragePaths.assets(document.id))
        thumbnails.document = document
        undoManager.levelsOfUndo = 80
        undoManager.groupsByEvent = true
        canvas = CanvasController(document: document, editor: self, undoManager: undoManager)
        indexer = InkIndexer(document: document)
        canvas.applyTool(tools)
        currentPage = min(max(document.content.lastPageIndex, 0), max(document.pages.count - 1, 0))
        selectedRecordingID = document.content.recordings.last?.id
        configureAudio()
        SelfTest.currentEditor = self
        // Index any handwriting that isn't searchable yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.indexer.refresh()
        }
    }

    var title: String {
        LibraryStore.shared.meta(document.id)?.title ?? document.content.meta.title
    }

    var pageCount: Int { document.pages.count }

    // MARK: - Saving

    func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard !closed || canvas != nil else { return }
        canvas.flushInkToDocument()
        canvas.saveBoardViewport()
        document.content.lastPageIndex = currentPage
        document.save()
        indexer.refresh()
    }

    /// Called when the app moves to the background: save synchronously.
    func saveForBackground() {
        saveNow()
        DiskWriter.shared.flushSync()
    }

    // MARK: - Undo

    /// A whiteboard rather than a notebook of pages.
    var isBoard: Bool { document.pages.count == 1 && document.pages[0].isBoard }

    /// Typing history of the open text box, if any.
    private var typingUndo: UndoManager? {
        isEditingText ? canvas.textEditor?.undoManager : nil
    }

    func undo() {
        // While typing, undo steps back through the typing first.
        if let typing = typingUndo, typing.canUndo {
            typing.undo()
            undoStateChanged()
            return
        }
        canvas.historyWillChange()
        if isEditingText {
            canvas.endTextEditing()
        }
        guard undoManager.canUndo else {
            undoStateChanged()
            return
        }
        undoManager.undo()
        undoStateChanged()
        canvas.historyDidChange()
    }

    func redo() {
        if let typing = typingUndo, typing.canRedo {
            typing.redo()
            undoStateChanged()
            return
        }
        canvas.historyWillChange()
        // Committing the open box is a new change (which ends the redo history).
        if isEditingText {
            canvas.endTextEditing()
        }
        guard undoManager.canRedo else {
            undoStateChanged()
            return
        }
        undoManager.redo()
        undoStateChanged()
        canvas.historyDidChange()
    }

    func undoStateChanged() {
        let typing = typingUndo
        // Undo is possible while a box has unsaved typing: it steps back through
        // the typing, or closes the box and removes what it added.
        let typed = (typing?.canUndo ?? false) || (isEditingText && canvas.textEditor?.hasChanges == true)
        canUndo = undoManager.canUndo || typed
        canRedo = (typing?.canRedo ?? false) || (undoManager.canRedo && !typed)
    }

    // MARK: - Tools

    func selectTool(_ tool: ToolKind, remember: Bool = true) {
        dismissPopovers()
        if canvas.replayTime != nil, tool.usesCanvasDrawing || tool == .text || tool == .lasso {
            // Writing during replay: turn replay off and keep listening.
            replayEnabled = false
            canvas.stopReplay()
        }
        guard tools.tool != tool else { return }
        if isEditingText, tool != .text { canvas.endTextEditing() }
        var t = tools
        if remember { t.previousTool = t.tool }
        t.tool = tool
        tools = t
    }

    func toggleTool(_ tool: ToolKind) {
        if tools.tool == tool {
            // Tapping the active tool opens its options.
            palette = palette == tool ? nil : tool
        } else {
            selectTool(tool)
        }
    }

    func handlePencilDoubleTap(systemPreference: UIPencilPreferredAction) {
        let action: PencilDoubleTapAction
        switch AppSettings.shared.pencilDoubleTap {
        case .system:
            switch systemPreference {
            case .switchEraser: action = .eraser
            case .switchPrevious: action = .previous
            case .showColorPalette: action = .colors
            case .ignore: action = .off
            default: action = .eraser
            }
        default:
            action = AppSettings.shared.pencilDoubleTap
        }
        switch action {
        case .eraser:
            if tools.tool == .eraser { selectTool(tools.previousTool == .eraser ? .pen : tools.previousTool) } else { selectTool(.eraser) }
        case .previous:
            selectTool(tools.previousTool)
        case .colors:
            if !tools.tool.isInking { selectTool(.pen) }
            if editingColorSlot == nil {
                editingColorSlot = tools.activePreset?.colorIndex ?? 0
            } else {
                editingColorSlot = nil
            }
        case .off, .system:
            break
        }
    }

    func rememberTextStyle(_ run: TextRun) {
        var t = tools
        t.textFamily = run.family
        t.textSize = run.size
        t.textColor = run.color
        tools = t
    }

    func applyTextStyle(_ change: TextStyleChange) {
        canvas.applyTextStyle(change)
        var t = tools
        switch change {
        case let .family(f): t.textFamily = f
        case let .size(s): t.textSize = s
        case let .color(c): t.textColor = c
        default: break
        }
        tools = t
    }

    // MARK: - Canvas callbacks

    func canvasCurrentPageChanged(_ index: Int) {
        if currentPage != index { currentPage = index }
    }

    func canvasZoomChanged(percent: Int) {
        zoomBadge = percent
    }

    func canvasZoomBegan() {
        zoomBadgeWork?.cancel()
    }

    func canvasZoomEnded() {
        zoomBadgeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                withAnimation(.easeOut(duration: 0.25)) { self?.zoomBadge = nil }
            }
        }
        zoomBadgeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    func canvasBeganDrawing() {
        dismissPopovers()
    }

    func canvasTappedEmpty() {
        dismissPopovers()
    }

    func dismissPopovers() {
        if palette != nil { palette = nil }
        if editingColorSlot != nil { editingColorSlot = nil }
        if editingWidthSlot != nil { editingWidthSlot = nil }
    }

    func inkChanged(erased: Bool) {
        if erased, AppSettings.shared.eraserAutoDeselect, tools.tool == .eraser {
            selectTool(tools.previousTool == .eraser ? .pen : tools.previousTool)
        }
    }

    func selectionChanged(hasSelection: Bool) {
        self.hasSelection = hasSelection
    }

    func textEditingChanged(_ editing: Bool) {
        isEditingText = editing
        undoStateChanged()
    }

    func replayStateChanged(_ active: Bool) {
        if isReplaying != active { isReplaying = active }
    }

    func pagesChanged() {
        if currentPage >= document.pages.count { currentPage = max(0, document.pages.count - 1) }
    }

    func showToast(_ message: String) {
        toastWork?.cancel()
        withAnimation(.spring(duration: 0.3)) { toast = message }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                withAnimation(.easeOut(duration: 0.3)) { self?.toast = nil }
            }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    func showError(_ message: String) {
        errorMessage = message
    }

    // MARK: - Pages

    func goToPage(_ index: Int, animated: Bool = true) {
        guard index >= 0, index < document.pages.count else { return }
        canvas.scrollToPage(index, animated: animated)
        currentPage = index
    }

    func addPageAtEnd() {
        let template = document.pages.last?.continuation() ?? Page(style: AppSettings.shared.defaultPaper)
        insertPage(template, at: document.pages.count)
    }

    func addPage(after index: Int) {
        let base = document.pages.indices.contains(index) ? document.pages[index] : document.pages.last
        let page = base?.continuation() ?? Page(style: AppSettings.shared.defaultPaper)
        insertPage(page, at: min(index + 1, document.pages.count))
    }

    func addPage(before index: Int) {
        let base = document.pages.indices.contains(index) ? document.pages[index] : document.pages.first
        let page = base?.continuation() ?? Page(style: AppSettings.shared.defaultPaper)
        insertPage(page, at: max(0, index))
    }

    func insertPage(_ page: Page, at index: Int) {
        let i = min(max(index, 0), document.pages.count)
        canvas.performPageEdit("Add page") { pages, strokes in
            pages.insert(page, at: i)
            strokes.insert([], at: min(i, strokes.count))
        }
        Haptics.tap()
        DispatchQueue.main.async { [weak self] in self?.goToPage(i) }
    }

    func insertPages(_ newPages: [Page], at index: Int) {
        guard !newPages.isEmpty else { return }
        let i = min(max(index, 0), document.pages.count)
        canvas.performPageEdit(newPages.count == 1 ? "Add page" : "Add pages") { pages, strokes in
            pages.insert(contentsOf: newPages, at: i)
            strokes.insert(contentsOf: Array(repeating: [], count: newPages.count), at: min(i, strokes.count))
        }
        DispatchQueue.main.async { [weak self] in self?.goToPage(i) }
    }

    func duplicatePage(_ id: UUID) {
        guard let i = document.pageIndex(of: id) else { return }
        canvas.performPageEdit("Duplicate page") { pages, strokes in
            var copy = pages[i]
            copy.id = UUID()
            copy.bookmarked = false
            copy.recognition = nil
            for e in copy.elements.indices { copy.elements[e].id = UUID() }
            pages.insert(copy, at: i + 1)
            strokes.insert(strokes[i], at: i + 1)
        }
        DispatchQueue.main.async { [weak self] in self?.goToPage(i + 1) }
    }

    func deletePages(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let count = ids.count
        canvas.performPageEdit(count == 1 ? "Delete page" : "Delete pages") { pages, strokes in
            var keptPages: [Page] = []
            var keptStrokes: [[PKStroke]] = []
            for (i, page) in pages.enumerated() where !ids.contains(page.id) {
                keptPages.append(page)
                keptStrokes.append(i < strokes.count ? strokes[i] : [])
            }
            pages = keptPages
            strokes = keptStrokes
        }
        showToast(count == 1 ? "Page deleted" : "\(count) pages deleted")
    }

    func movePage(from source: Int, to destination: Int) {
        guard source != destination, document.pages.indices.contains(source) else { return }
        canvas.performPageEdit("Move page") { pages, strokes in
            let page = pages.remove(at: source)
            let s = strokes.remove(at: source)
            let d = min(max(destination, 0), pages.count)
            pages.insert(page, at: d)
            strokes.insert(s, at: d)
        }
    }

    func toggleBookmark(_ id: UUID) {
        guard let i = document.pageIndex(of: id) else { return }
        let value = !document.pages[i].bookmarked
        canvas.performElementEdit(value ? "Bookmark page" : "Remove bookmark", pageID: id) { $0.bookmarked = value }
        Haptics.tap()
    }

    func clearInk(on id: UUID) {
        guard let i = document.pageIndex(of: id) else { return }
        canvas.performPageEdit("Clear page") { _, strokes in
            if i < strokes.count { strokes[i] = [] }
        }
    }

    /// Changes paper (and optionally size) for pages; PDF/image pages keep their background.
    func applyPaper(_ kind: PaperKind, color: PaperColor, size: CGSize?, to ids: [UUID]) {
        let set = Set(ids)
        canvas.performPageEdit("Change template") { pages, _ in
            for i in pages.indices where set.contains(pages[i].id) {
                // PDF and scanned pages keep their content and size.
                if case .paper = pages[i].background {
                    pages[i].background = .paper(kind: kind, color: color)
                    if let size { pages[i].size = size }
                }
            }
        }
    }

    func importPDFPages(from url: URL, after index: Int) async {
        busyMessage = "Importing PDF…"
        defer { busyMessage = nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let assetName = UUID().uuidString + ".pdf"
        let dest = StoragePaths.assets(document.id).appendingPathComponent(assetName)
        do {
            let info = try await PDFImporter.importFile(from: url, to: dest, password: nil)
            let pages = info.pageSizes.enumerated().map { i, size in Page(size: size, background: .pdf(asset: assetName, index: i)) }
            insertPages(pages, at: index + 1)
            LibraryStore.shared.indexPDFText(notebook: document.id, pages: pages, pdfURL: dest)
            scheduleSave()
        } catch {
            showError(error.localizedDescription)
        }
    }

    func insertImage(_ image: UIImage) {
        canvas.insertImage(image)
    }

    func paste() {
        canvas.paste(at: nil)
    }

    func insertElement(_ payload: Clipboard.Payload) {
        canvas.paste(at: nil, payload: payload)
    }

    // MARK: - Selection

    func convertSelectionToText() {
        guard let (image, _) = canvas.selectionInkImageForRecognition() else {
            showToast("Select handwriting to convert")
            return
        }
        busyMessage = "Recognizing handwriting…"
        Task {
            let text = await HandwritingRecognizer.text(from: image)
            busyMessage = nil
            if text.isEmpty {
                showToast("No handwriting recognized")
            } else {
                sheet = .convertedText(text)
            }
        }
    }

    func shareSelectionImage() {
        guard let image = canvas.selectionImageForSharing(), let data = image.pngData() else { return }
        let url = StoragePaths.freshExportFolder().appendingPathComponent("Selection.png")
        do {
            try data.write(to: url)
            SharePresenter.share([url])
        } catch {
            showError("Couldn't share the selection: \(error.localizedDescription)")
        }
    }

    // MARK: - Audio

    private func configureAudio() {
        audio.onRecordingUpdated = { [weak self] recording in
            guard let self else { return }
            self.storeRecording(recording)
            self.scheduleSave()
        }
        audio.onRecordingFinished = { [weak self] recording in
            guard let self else { return }
            self.storeRecording(recording)
            self.selectedRecordingID = recording.id
            self.saveNow()
            self.showToast("Recording saved · \(recording.duration.clock)")
        }
        audio.onRecordingDiscarded = { [weak self] id in
            guard let self else { return }
            self.document.content.recordings.removeAll { $0.id == id }
            self.document.markContentChanged()
            self.scheduleSave()
        }
        audio.onError = { [weak self] message in self?.showError(message) }
        audio.onPlaybackTime = { [weak self] time in
            self?.canvas.updateReplay(time: time)
        }
        audio.onPlaybackEnded = { [weak self] in
            guard let self else { return }
            // Show all ink again at the end.
            self.canvas.updateReplay(time: .greatestFiniteMagnitude)
        }
    }

    private func storeRecording(_ recording: Recording) {
        if let i = document.content.recordings.firstIndex(where: { $0.id == recording.id }) {
            document.content.recordings[i] = recording
        } else {
            document.content.recordings.append(recording)
        }
        document.markContentChanged()
    }

    /// Recordings that are finished (the one being recorded is excluded).
    var recordings: [Recording] {
        let live = audio.recordState == .idle ? nil : document.content.recordings.last?.id
        return document.content.recordings.filter { $0.id != live }
    }

    var selectedRecording: Recording? {
        recordings.first { $0.id == selectedRecordingID } ?? recordings.last
    }

    func toggleRecording() {
        switch audio.recordState {
        case .idle:
            stopReplayIfNeeded()
            audio.startRecording()
            showAudioBar = false
        case .recording, .paused:
            audio.stopRecording()
        }
    }

    func play(_ recording: Recording) {
        selectedRecordingID = recording.id
        showAudioBar = true
        if replayEnabled {
            canvas.startReplay(recording)
            if !canvas.replayHasTimedInk { canvas.stopReplay() }
        }
        audio.play(recording)
        canvas.updateReplay(time: audio.playTime)
    }

    func togglePlayback() {
        guard let rec = selectedRecording else { return }
        if audio.playingID == rec.id {
            if audio.isPlaying { audio.pause() } else { play(rec) }
        } else {
            play(rec)
        }
    }

    func seekPlayback(to time: TimeInterval) {
        guard let rec = selectedRecording else { return }
        if audio.playingID != rec.id { play(rec) }
        audio.seek(to: time)
        if !audio.isPlaying { audio.play(rec) }
    }

    func setReplayEnabled(_ on: Bool) {
        replayEnabled = on
        if on, let rec = selectedRecording, audio.playingID == rec.id {
            canvas.startReplay(rec)
            canvas.updateReplay(time: audio.playTime)
        } else {
            canvas.stopReplay()
        }
    }

    func stopReplayIfNeeded() {
        canvas.stopReplay()
    }

    func closeAudioBar() {
        audio.stopPlayback()
        canvas.stopReplay()
        showAudioBar = false
    }

    func renameRecording(_ id: UUID, to title: String) {
        guard let i = document.content.recordings.firstIndex(where: { $0.id == id }) else { return }
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        document.content.recordings[i].title = clean
        document.markContentChanged()
        scheduleSave()
    }

    func deleteRecording(_ id: UUID) {
        if audio.playingID == id { closeAudioBar() }
        document.content.recordings.removeAll { $0.id == id }
        document.markContentChanged()
        if selectedRecordingID == id { selectedRecordingID = document.content.recordings.last?.id }
        saveNow()
    }

    // MARK: - Export

    func exportJob(pageIndices: [Int]? = nil, includeBackgrounds: Bool = true) -> ExportJob {
        canvas.flushInkToDocument()
        let indices = pageIndices ?? Array(document.pages.indices)
        let pages = indices.compactMap { document.pages.indices.contains($0) ? document.pages[$0] : nil }
        var drawings: [UUID: PKDrawing] = [:]
        for p in pages { drawings[p.id] = document.drawing(for: p.id) }
        return ExportJob(title: title, pages: pages, drawings: drawings, assets: document.assets,
                         vectorInk: AppSettings.shared.vectorInkExport, includeBackgrounds: includeBackgrounds)
    }

    func exportPDF(pageIndices: [Int]? = nil, includeBackgrounds: Bool = true, then action: @escaping (URL) -> Void) {
        let job = exportJob(pageIndices: pageIndices, includeBackgrounds: includeBackgrounds)
        busyMessage = "Preparing PDF…"
        Task {
            do {
                let url = try await ExportService.pdf(job)
                busyMessage = nil
                action(url)
            } catch {
                busyMessage = nil
                showError("Couldn't create the PDF: \(error.localizedDescription)")
            }
        }
    }

    func sharePDF(pageIndices: [Int]? = nil, includeBackgrounds: Bool = true) {
        exportPDF(pageIndices: pageIndices, includeBackgrounds: includeBackgrounds) { url in
            SharePresenter.share([url])
        }
    }

    func shareImages(pageIndices: [Int]) {
        let job = exportJob(pageIndices: pageIndices)
        busyMessage = "Preparing images…"
        Task {
            let urls = await ExportService.images(job)
            busyMessage = nil
            if urls.isEmpty { showError("Couldn't create the images.") } else { SharePresenter.share(urls) }
        }
    }

    func shareArchive() {
        saveNow()
        busyMessage = "Packaging notebook…"
        Task {
            do {
                let url = try await LibraryStore.shared.exportArchive(document.id)
                busyMessage = nil
                SharePresenter.share([url])
            } catch {
                busyMessage = nil
                showError("Couldn't package the notebook: \(error.localizedDescription)")
            }
        }
    }

    func printNotebook() {
        exportPDF { url in
            let controller = UIPrintInteractionController.shared
            let info = UIPrintInfo.printInfo()
            info.jobName = self.title
            info.outputType = .general
            controller.printInfo = info
            controller.printingItem = url
            controller.present(animated: true)
        }
    }

    // MARK: - Find in notebook

    /// Searches typed text, handwriting and PDF text. Debounced and cancellable,
    /// so it can run on every keystroke.
    func runFind() {
        findTask?.cancel()
        let q = findQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            findResults = []
            currentFindIndex = nil
            isSearching = false
            canvas.showHighlights([], current: nil)
            return
        }
        isSearching = true
        let pages = document.pages
        var refs: [PDFTextSearcher.PageRef] = []
        for (i, page) in pages.enumerated() {
            if case let .pdf(asset, index) = page.background {
                refs.append(PDFTextSearcher.PageRef(pageIndex: i, pageID: page.id, asset: asset, pdfIndex: index, pageSize: page.size))
            }
        }
        let searcher = pdfSearcher
        findTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            var results = InlineSearcher.search(q, pages: pages)
            if !refs.isEmpty {
                results += await searcher.search(q, pages: refs)
            }
            // No exact phrase: show pages that contain every word, highlighting each word.
            let words = q.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if results.isEmpty, words.count > 1 {
                var perWord: [[FindResult]] = []
                for word in words {
                    var hits = InlineSearcher.search(word, pages: pages)
                    if !refs.isEmpty { hits += await searcher.search(word, pages: refs) }
                    perWord.append(hits)
                }
                let pagesWithAll = perWord.map { Set($0.map(\.pageIndex)) }.reduce(nil as Set<Int>?) { acc, set in acc.map { $0.intersection(set) } ?? set } ?? []
                results = perWord.flatMap { $0 }.filter { pagesWithAll.contains($0.pageIndex) }
            }
            guard !Task.isCancelled else { return }
            results.sort { ($0.pageIndex, $0.order) < ($1.pageIndex, $1.order) }
            findResults = results
            isSearching = false
            // Start at the first match at or after the page being read.
            if let first = results.firstIndex(where: { $0.pageIndex >= currentPage }) ?? (results.isEmpty ? nil : 0) {
                currentFindIndex = first
                // Bring the first match into view if it is off screen.
                let r = results[first]
                let visible = r.rect.flatMap { rect in canvas.layout.frame(of: r.pageIndex).map { rect.offsetBy(dx: $0.minX, dy: $0.minY) } }
                    .map { canvas.visibleDocRect.insetBy(dx: 0, dy: 40).contains($0) } ?? false
                highlightFindResults(scroll: !visible)
            } else {
                currentFindIndex = nil
                canvas.showHighlights([], current: nil)
            }
        }
    }

    func showFindResult(_ result: FindResult) {
        guard let index = findResults.firstIndex(of: result) else { return }
        currentFindIndex = index
        highlightFindResults(scroll: true)
    }

    func nextFindResult() {
        guard !findResults.isEmpty else { return }
        currentFindIndex = ((currentFindIndex ?? -1) + 1) % findResults.count
        highlightFindResults(scroll: true)
    }

    func previousFindResult() {
        guard !findResults.isEmpty else { return }
        currentFindIndex = ((currentFindIndex ?? 0) - 1 + findResults.count) % findResults.count
        highlightFindResults(scroll: true)
    }

    /// Highlights every match and emphasizes the current one.
    private func highlightFindResults(scroll: Bool) {
        var all: [CGRect] = []
        var current: CGRect?
        for (i, r) in findResults.enumerated() {
            guard let rect = r.rect, let frame = canvas.layout.frame(of: r.pageIndex) else { continue }
            let doc = rect.offsetBy(dx: frame.minX, dy: frame.minY)
            all.append(doc)
            if i == currentFindIndex { current = doc }
        }
        canvas.showHighlights(all, current: current)
        guard scroll, let index = currentFindIndex, findResults.indices.contains(index) else { return }
        let result = findResults[index]
        if let current {
            canvas.scrollToDocRect(current, animated: true, align: .center)
        } else {
            goToPage(result.pageIndex)
        }
        currentPage = result.pageIndex
    }

    func clearFind() {
        findTask?.cancel()
        findQuery = ""
        findResults = []
        currentFindIndex = nil
        isSearching = false
        canvas.showHighlights([], current: nil)
    }

    // MARK: - Close

    func close() {
        guard !closed else { return }
        if audio.recordState != .idle { audio.stopRecording() }
        audio.tearDown()
        indexer.cancel()
        canvas.prepareToClose()
        document.content.lastPageIndex = currentPage
        document.save(force: document.hasUnsavedChanges)
        document.removeUnreferencedAssets()
        undoManager.removeAllActions()
        closed = true
        LibraryStore.shared.endEditing(document.id)
    }
}
