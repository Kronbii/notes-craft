import NotesCraftCore
import PencilKit
import UIKit

/// The editable state of a notebook at a moment: page list and all ink in
/// document space. Undo/redo restores these snapshots.
struct CanvasState {
    var pages: [Page]
    var drawing: PKDrawing
    /// How far a whiteboard's content had been moved (by growing left or up)
    /// when this state was taken; restoring moves it to the current position.
    var origin: CGPoint
}

/// Drives the notebook canvas: one PencilKit canvas spanning every page,
/// page backgrounds underneath, overlays on top.
final class CanvasController: NSObject {
    let document: NotebookDocument
    weak var editor: EditorModel?
    let undoManager: UndoManager

    let rootView = CanvasRootView()
    let canvas = NotebookCanvasView()

    private(set) var layout: DocumentLayout
    /// The true ink (what is saved). The canvas may temporarily show something
    /// else (while dragging a selection or replaying audio).
    var baseline = PKDrawing()

    var pageViews: [UUID: PageTileView] = [:]
    var hiddenElements: Set<UUID> = []
    var isApplyingProgrammatic = false
    var toolInUse = false
    var pendingInkChange = false
    /// The tool of the current (or last) PencilKit tool use.
    var lastDrawingTool: ToolKind = .pen
    /// Total shift of a whiteboard's content this session (see `growBoard`).
    var boardOrigin = CGPoint.zero
    var isGrowingBoard = false
    var commitScheduled = false
    /// Zoom and scroll position when a two/three-finger tap started; if either
    /// changed by the time it ends, it was a pinch or a scroll, not a tap.
    var tapStart: (zoom: CGFloat, offset: CGPoint)?
    var tapsWaitForPinch = false
    /// Whiteboard overview in the bottom-left corner.
    var miniMap: BoardMiniMapView?
    /// Whiteboard dots or grid, drawn live for the current zoom.
    var boardPattern: BoardPatternLayer?
    /// The zoom window (writing magnified) and its box on the page.
    var zoomWindow: ZoomWindowController?
    var zoomTargetView: ZoomTargetView?
    /// Height the zoom window covers at the bottom.
    var zoomPanelInset: CGFloat = 0
    var miniMapBottom: NSLayoutConstraint?
    /// Strokes that undo, redo or an edit took off the page. If the canvas
    /// reports one of them again, it is PencilKit's stale copy (see `reconcile`).
    var removedStrokes: Set<StrokeKey> = []
    /// Uncommitted strokes started shortly before this moment are leftovers of
    /// the fingers that tapped undo or redo.
    var discardStrokesBefore = Date.distantPast
    var fitZoom: CGFloat = 1
    var relativeZoom: CGFloat = 1
    var lastBoundsSize: CGSize = .zero
    var didInitialLayout = false
    var visibleRange: Range<Int> = 0 ..< 0
    var lastReportedPage = -1
    var keyboardInset: CGFloat = 0
    var currentTool: ToolKind = .pen

    // Gestures
    let touchObserver = TouchObserver(target: nil, action: nil)
    var twoFingerTap: UITapGestureRecognizer!
    var threeFingerTap: UITapGestureRecognizer!
    var fingerTap: UITapGestureRecognizer!
    var toolTap: UITapGestureRecognizer!
    var toolPan: UIPanGestureRecognizer!
    var longPress: UILongPressGestureRecognizer!
    var pencilInteraction: UIPencilInteraction?
    var editMenu: UIEditMenuInteraction?
    var lastPencilTapTime: TimeInterval = 0
    var pendingMenuPoint: CGPoint?
    var keyboardObservers: [NSObjectProtocol] = []
    var zoomLink: CADisplayLink?
    var zoomAnimation: (from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: CFTimeInterval, docPoint: CGPoint, viewPoint: CGPoint)?

    // Overlays
    let addPageButton = AddPageButton()
    let lassoLayer = CAShapeLayer()
    let highlightLayer = CAShapeLayer()
    let snapPreviewLayer = CAShapeLayer()
    let laserLayer = CAShapeLayer()
    let laserGlowLayer = CAShapeLayer()
    var lassoPoints: [CGPoint] = []
    var laserPoints: [(CGPoint, TimeInterval)] = []
    var laserFadeTimer: Timer?

    // Selection
    var selection: CanvasSelection?
    var selectionView: SelectionView?
    var dragSession: DragSession?

    // Text editing
    var textEditor: TextEditorView?
    var editingText: (pageID: UUID, elementID: UUID, isNew: Bool, before: CanvasState)?

    // Audio replay
    var replayTime: TimeInterval?
    var replayRecordingStrokeTimes: [Int: TimeInterval] = [:]
    var lastReplayVisibleCount = -1

    // Find highlights (document space)
    var highlightRects: [CGRect] = []
    var currentHighlightRect: CGRect?
    let currentHighlightLayer = CAShapeLayer()

    init(document: NotebookDocument, editor: EditorModel, undoManager: UndoManager) {
        self.document = document
        self.editor = editor
        self.undoManager = undoManager
        self.layout = DocumentLayout(pageSizes: document.pages.map(\.size))
        super.init()
        baseline = composeDrawing(pages: document.pages, layout: layout)
        setUpCanvas()
        setUpGestures()
        setUpOverlays()
        observeKeyboard()
        keyboardObservers.append(NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.document.assets.purgeImages()
            }
        })
    }

    // MARK: - Setup

    private func setUpCanvas() {
        rootView.controller = self
        rootView.backgroundColor = Theme.deskUI
        rootView.addSubview(canvas)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: rootView.topAnchor),
            canvas.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.showsHorizontalScrollIndicator = false
        canvas.alwaysBounceVertical = true
        // Zoom bounces animate PencilKit's layer but not the page tiles, so
        // zoom changes are animated frame by frame instead (animateZoom).
        canvas.bouncesZoom = false
        canvas.delegate = self
        canvas.drawingPolicy = AppSettings.shared.drawWithFinger ? .anyInput : .pencilOnly
        canvas.isRulerActive = false
        canvas.decelerationRate = .normal
        canvas.onLayout = { [weak self] in self?.canvasDidLayout() }
        setCanvasDrawing(baseline)
        if let tool = editor?.tools.pkTool(for: .pen) { canvas.tool = tool }
    }

    private func setUpOverlays() {
        let overlay = canvas.overlay
        addPageButton.addAction(UIAction { [weak self] _ in
            self?.editor?.addPageAtEnd()
        }, for: .primaryActionTriggered)
        overlay.addSubview(addPageButton)
        addPageButton.addGestureRecognizer(PencilShield(drawingRecognizer: canvas.drawingGestureRecognizer))

        // Find highlights: every match softly, the current match strongly.
        highlightLayer.fillColor = UIColor(red: 1, green: 0.86, blue: 0.2, alpha: 0.28).cgColor
        highlightLayer.strokeColor = nil
        overlay.layer.addSublayer(highlightLayer)
        currentHighlightLayer.fillColor = UIColor(red: 1, green: 0.62, blue: 0.0, alpha: 0.30).cgColor
        currentHighlightLayer.strokeColor = UIColor(red: 1, green: 0.55, blue: 0.0, alpha: 0.95).cgColor
        currentHighlightLayer.lineWidth = 2
        overlay.layer.addSublayer(currentHighlightLayer)

        lassoLayer.fillColor = Theme.canvasAccentUI.withAlphaComponent(0.06).cgColor
        lassoLayer.strokeColor = Theme.canvasAccentUI.cgColor
        lassoLayer.lineWidth = 1.5
        lassoLayer.lineDashPattern = [6, 5]
        lassoLayer.lineJoin = .round
        overlay.layer.addSublayer(lassoLayer)

        snapPreviewLayer.fillColor = nil
        snapPreviewLayer.strokeColor = Theme.canvasAccentUI.withAlphaComponent(0.85).cgColor
        snapPreviewLayer.lineWidth = 2
        snapPreviewLayer.lineDashPattern = [4, 4]
        overlay.layer.addSublayer(snapPreviewLayer)

        laserGlowLayer.fillColor = nil
        laserGlowLayer.lineCap = .round
        laserGlowLayer.lineJoin = .round
        laserGlowLayer.lineWidth = 14
        laserGlowLayer.opacity = 0.35
        laserLayer.fillColor = nil
        laserLayer.lineCap = .round
        laserLayer.lineJoin = .round
        laserLayer.lineWidth = 5
        overlay.layer.addSublayer(laserGlowLayer)
        overlay.layer.addSublayer(laserLayer)
        for l in [highlightLayer, currentHighlightLayer, lassoLayer, snapPreviewLayer, laserLayer, laserGlowLayer] {
            l.actions = ["path": NSNull(), "opacity": NSNull()]
        }
    }

    // MARK: - Layout and zoom

    var zoom: CGFloat { canvas.zoomScale }

    func canvasDidLayout() {
        let size = canvas.bounds.size
        guard size.width > 10, size.height > 10 else { return }
        if size != lastBoundsSize {
            let firstLayout = !didInitialLayout
            let anchorDocY = didInitialLayout ? (canvas.contentOffset.y + canvas.contentInset.top) / max(zoom, 0.01) : 0
            lastBoundsSize = size
            updateZoomLimits()
            if firstLayout {
                didInitialLayout = true
                canvas.setZoomScale(fitZoom, animated: false)
                updateZoomDependentLayout()
                if isBoard {
                    restoreBoardViewport()
                    ensureBoardRoom(allowShift: true)
                    installMiniMapIfNeeded()
                } else {
                    let start = min(max(document.content.lastPageIndex, 0), max(document.pages.count - 1, 0))
                    scrollToPage(start, animated: false)
                }
            } else {
                // Keep the same relative zoom and the same spot at the top.
                let target = min(max(fitZoom * relativeZoom, canvas.minimumZoomScale), canvas.maximumZoomScale)
                canvas.setZoomScale(target, animated: false)
                updateZoomDependentLayout()
                let y = anchorDocY * zoom - canvas.contentInset.top
                canvas.contentOffset = CGPoint(x: canvas.contentOffset.x, y: clampOffsetY(y))
            }
        }
    }

    /// A whiteboard: one very large page you pan around instead of pages you scroll through.
    var isBoard: Bool { document.pages.count == 1 && document.pages[0].isBoard }

    func updateZoomLimits() {
        if isBoard {
            // 100% is actual size; zoom out far enough to see a lot of the board.
            fitZoom = 1
            canvas.minimumZoomScale = 0.05
            canvas.maximumZoomScale = 6
            linkTapsToScrollGestures()
            return
        }
        let width = max(canvas.bounds.width, 100)
        fitZoom = width / layout.contentSize.width
        canvas.minimumZoomScale = fitZoom * 0.3
        canvas.maximumZoomScale = max(fitZoom * 6, 4)
        linkTapsToScrollGestures()
    }

    /// The board area with something on it (document coordinates), if any.
    var boardContentRect: CGRect? {
        guard isBoard, let frame = layout.frame(of: 0) else { return nil }
        var rect = baseline.strokes.isEmpty ? CGRect.null : baseline.bounds
        for element in document.pages[0].elements {
            rect = rect.union(element.frame.offsetBy(dx: frame.minX, dy: frame.minY))
        }
        return rect.isNull ? nil : rect
    }

    private var boardViewKey: String { "boardView.\(document.id.uuidString)" }

    /// Remembers where the board was being looked at (view state, not content).
    func saveBoardViewport() {
        guard isBoard, didInitialLayout else { return }
        let rect = visibleDocRect
        UserDefaults.standard.set([Double(rect.midX), Double(rect.midY), Double(zoom)], forKey: boardViewKey)
    }

    /// Reopens a board where it was left; the first time, shows everything on it.
    func restoreBoardViewport() {
        let view = CGPoint(x: canvas.bounds.width / 2, y: canvas.bounds.height / 2)
        if let saved = UserDefaults.standard.array(forKey: boardViewKey) as? [Double], saved.count == 3,
           saved.allSatisfy(\.isFinite) {
            let z = min(max(CGFloat(saved[2]), canvas.minimumZoomScale), canvas.maximumZoomScale)
            setZoom(z, keeping: CGPoint(x: saved[0], y: saved[1]), at: view)
        } else if boardContentRect != nil {
            fitBoardContent(maxZoom: 1, animated: false)
        } else {
            centerBoard()
        }
    }

    /// Zooms so everything on the board is visible.
    func fitBoardContent(maxZoom: CGFloat, animated: Bool) {
        guard let content = boardContentRect?.insetBy(dx: -60, dy: -60) else {
            centerBoard()
            return
        }
        let fit = min(canvas.bounds.width / content.width, (canvas.bounds.height - keyboardInset) / content.height)
        let z = min(max(fit, canvas.minimumZoomScale), maxZoom)
        let doc = CGPoint(x: content.midX, y: content.midY)
        let view = CGPoint(x: canvas.bounds.width / 2, y: canvas.bounds.height / 2)
        if animated { animateZoom(to: z, keeping: doc, at: view) } else { setZoom(z, keeping: doc, at: view) }
    }

    /// Opens a whiteboard at actual size, centered on what is drawn (or the middle).
    func centerBoard() {
        guard let frame = layout.frame(of: 0) else { return }
        let center = boardContentRect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: frame.midX, y: frame.midY)
        setZoom(1, keeping: center, at: CGPoint(x: canvas.bounds.width / 2, y: canvas.bounds.height / 2))
    }

    /// Positions everything that depends on the zoom scale.
    func updateZoomDependentLayout() {
        let z = zoom
        relativeZoom = z / max(fitZoom, 0.0001)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let container = canvas.pageContainer
        container.layer.bounds = CGRect(origin: .zero, size: layout.contentSize)
        container.layer.position = .zero
        container.transform = CGAffineTransform(scaleX: z, y: z)
        let contentSize = CGSize(width: layout.contentSize.width * z, height: layout.contentSize.height * z)
        if canvas.contentSize != contentSize { canvas.contentSize = contentSize }
        let contentRect = CGRect(origin: .zero, size: contentSize)
        canvas.deskMask.frame = contentRect
        canvas.overlay.frame = contentRect
        CATransaction.commit()
        updateInsets()
        updateVisiblePages(force: true)
        layoutOverlays()
        miniMap?.updateViewport()
        layoutZoomTarget()
    }

    func updateInsets() {
        let contentSize = canvas.contentSize
        let insetX = max(0, (canvas.bounds.width - contentSize.width) / 2)
        let insetY = max(0, (canvas.bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY + max(keyboardInset, zoomPanelInset), right: insetX)
        if canvas.contentInset != inset { canvas.contentInset = inset }
    }

    func clampOffsetY(_ y: CGFloat) -> CGFloat {
        let minY = -canvas.contentInset.top
        let maxY = max(minY, canvas.contentSize.height + canvas.contentInset.bottom - canvas.bounds.height)
        return min(max(y, minY), maxY)
    }

    /// Visible area in document coordinates.
    var visibleDocRect: CGRect {
        let b = canvas.bounds
        let z = max(zoom, 0.0001)
        return CGRect(x: b.minX / z, y: b.minY / z, width: b.width / z, height: b.height / z)
    }

    func docToContent(_ r: CGRect) -> CGRect {
        let z = zoom
        return CGRect(x: r.minX * z, y: r.minY * z, width: r.width * z, height: r.height * z)
    }

    func docToContent(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom, y: p.y * zoom)
    }

    func contentToDoc(_ p: CGPoint) -> CGPoint {
        let z = max(zoom, 0.0001)
        return CGPoint(x: p.x / z, y: p.y / z)
    }

    /// Location of a gesture in document coordinates.
    func docPoint(_ g: UIGestureRecognizer) -> CGPoint {
        contentToDoc(g.location(in: canvas))
    }

    func docPoint(_ t: UITouch) -> CGPoint {
        contentToDoc(t.location(in: canvas))
    }

    // MARK: - Visible pages

    func updateVisiblePages(force: Bool = false) {
        let visible = visibleDocRect
        let margin = visible.height * 0.75
        let range = layout.pages(intersecting: visible.insetBy(dx: -40, dy: -margin))
        let pages = document.pages
        if force || range != visibleRange {
            visibleRange = range
            var keep = Set<UUID>()
            for i in range where i < pages.count {
                let page = pages[i]
                keep.insert(page.id)
                let view = pageViews[page.id] ?? {
                    let v = PageTileView(frame: .zero)
                    canvas.pageContainer.addSubview(v)
                    pageViews[page.id] = v
                    return v
                }()
                let frame = layout.pageFrames[i]
                if view.frame != frame { view.frame = frame }
                view.configure(page: page, hiddenElements: hiddenElements, assets: document.assets)
            }
            for (id, view) in pageViews where !keep.contains(id) {
                view.removeFromSuperview()
                pageViews[id] = nil
            }
            updateDeskMask()
        }
        updateBoardPattern()
        reportCurrentPage()
    }

    func updateDeskMask() {
        let z = zoom
        let range = visibleRange
        var rects: [CGRect] = []
        rects.reserveCapacity(range.count + 2)
        let lo = max(0, range.lowerBound - 1), hi = min(layout.pageCount, range.upperBound + 1)
        if lo < hi {
            for i in lo ..< hi {
                rects.append(docToContent(layout.pageFrames[i]).integral(scale: canvas.traitCollection.displayScale))
            }
        }
        let extent = CGRect(origin: .zero, size: canvas.contentSize).insetBy(dx: -canvas.bounds.width, dy: -canvas.bounds.height)
        canvas.deskMask.update(pageRects: rects, extent: extent)
        _ = z
    }

    func refreshPageViews() {
        let pages = document.pages
        for i in visibleRange where i < pages.count {
            pageViews[pages[i].id]?.configure(page: pages[i], hiddenElements: hiddenElements, assets: document.assets)
        }
        updateBoardPattern()
    }

    func reportCurrentPage() {
        guard let page = layout.dominantPage(in: visibleDocRect) else { return }
        if page != lastReportedPage {
            lastReportedPage = page
            editor?.canvasCurrentPageChanged(page)
        }
    }

    var currentPageIndex: Int {
        layout.dominantPage(in: visibleDocRect) ?? 0
    }

    func scrollToPage(_ index: Int, animated: Bool) {
        guard let frame = layout.frame(of: index) else { return }
        scrollToDocRect(CGRect(x: frame.minX, y: frame.minY - DocumentLayout.pageGap / 2, width: frame.width, height: 1), animated: animated, align: .top)
    }

    enum ScrollAlign { case top, center }

    func scrollToDocRect(_ rect: CGRect, animated: Bool, align: ScrollAlign) {
        let target = docToContent(rect)
        var y: CGFloat
        switch align {
        case .top: y = target.minY
        case .center: y = target.midY - canvas.bounds.height / 2
        }
        y = clampOffsetY(y)
        var x = canvas.contentOffset.x
        if target.minX < canvas.bounds.minX || target.maxX > canvas.bounds.maxX {
            x = target.midX - canvas.bounds.width / 2
            let minX = -canvas.contentInset.left
            let maxX = max(minX, canvas.contentSize.width + canvas.contentInset.right - canvas.bounds.width)
            x = min(max(x, minX), maxX)
        }
        canvas.setContentOffset(CGPoint(x: x, y: y), animated: animated)
        if !animated { updateVisiblePages() }
    }

    func zoomToFit(animated: Bool) {
        if isBoard {
            fitBoardContent(maxZoom: 1.5, animated: animated)
            return
        }
        let doc = CGPoint(x: layout.contentSize.width / 2, y: visibleDocRect.midY)
        let view = CGPoint(x: canvas.bounds.width / 2, y: canvas.bounds.height / 2)
        if animated {
            animateZoom(to: fitZoom, keeping: doc, at: view)
        } else {
            setZoom(fitZoom, keeping: doc, at: view)
        }
    }

    /// Sets the zoom so that `docPoint` appears at `viewPoint` (relative to the
    /// visible area's top-left).
    func setZoom(_ z: CGFloat, keeping docPoint: CGPoint, at viewPoint: CGPoint) {
        let target = min(max(z, canvas.minimumZoomScale), canvas.maximumZoomScale)
        // Between the new zoom and the new offset the view is somewhere else
        // entirely; a whiteboard must not grow toward that spot.
        isGrowingBoard = true
        defer {
            isGrowingBoard = false
            if isBoard { ensureBoardRoom(allowShift: false) }
        }
        canvas.setZoomScale(target, animated: false)
        updateZoomDependentLayout()
        var x = docPoint.x * target - viewPoint.x
        var y = docPoint.y * target - viewPoint.y
        let minX = -canvas.contentInset.left
        let maxX = max(minX, canvas.contentSize.width + canvas.contentInset.right - canvas.bounds.width)
        x = min(max(x, minX), maxX)
        y = clampOffsetY(y)
        canvas.contentOffset = CGPoint(x: x, y: y)
    }

    func animateZoom(to z: CGFloat, keeping docPoint: CGPoint, at viewPoint: CGPoint, duration: CFTimeInterval = 0.28) {
        zoomLink?.invalidate()
        zoomAnimation = (zoom, z, CACurrentMediaTime(), duration, docPoint, viewPoint)
        let link = CADisplayLink(target: self, selector: #selector(stepZoomAnimation))
        link.add(to: .main, forMode: .common)
        zoomLink = link
    }

    @objc func stepZoomAnimation() {
        guard let a = zoomAnimation else {
            zoomLink?.invalidate()
            zoomLink = nil
            return
        }
        let t = min(1, (CACurrentMediaTime() - a.start) / a.duration)
        let eased = 1 - pow(1 - t, 3)
        setZoom(a.from + (a.to - a.from) * eased, keeping: a.docPoint, at: a.viewPoint)
        if t >= 1 {
            zoomAnimation = nil
            zoomLink?.invalidate()
            zoomLink = nil
            ensureBoardRoom(allowShift: true)
            textEditor?.rescale(zoom: zoom)
            editor?.canvasZoomEnded()
        }
    }

    // MARK: - Composing and splitting ink

    func composeDrawing(pages: [Page], layout: DocumentLayout) -> PKDrawing {
        var strokes: [PKStroke] = []
        for (i, page) in pages.enumerated() where i < layout.pageFrames.count {
            let origin = layout.pageFrames[i].origin
            let t = CGAffineTransform(translationX: origin.x, y: origin.y)
            for var s in document.drawing(for: page.id).strokes {
                s.transform = s.transform.concatenating(t)
                strokes.append(s)
            }
        }
        return PKDrawing(strokes: strokes)
    }

    /// Splits document-space ink into page-local stroke lists (in page order).
    /// Ink that lies completely outside every page is dropped.
    func splitStrokes(_ drawing: PKDrawing, layout: DocumentLayout) -> [[PKStroke]] {
        var buckets = [[PKStroke]](repeating: [], count: layout.pageCount)
        for stroke in drawing.strokes {
            let b = stroke.renderBounds
            guard !b.isNull, let i = layout.pageIndex(forY: b.midY) else { continue }
            let frame = layout.pageFrames[i]
            guard b.intersects(frame.insetBy(dx: -1, dy: -1)) else { continue }
            var s = stroke
            s.transform = stroke.transform.concatenating(CGAffineTransform(translationX: -frame.minX, y: -frame.minY))
            buckets[i].append(s)
        }
        return buckets
    }

    func composeStrokes(_ buckets: [[PKStroke]], layout: DocumentLayout) -> PKDrawing {
        var strokes: [PKStroke] = []
        for (i, list) in buckets.enumerated() where i < layout.pageCount {
            let origin = layout.pageFrames[i].origin
            let t = CGAffineTransform(translationX: origin.x, y: origin.y)
            for var s in list {
                s.transform = s.transform.concatenating(t)
                strokes.append(s)
            }
        }
        return PKDrawing(strokes: strokes)
    }

    /// Pushes the current ink into the document's per-page drawings (before saving).
    func flushInkToDocument() {
        commitPendingInk()
        let buckets = splitStrokes(baseline, layout: layout)
        for (i, page) in document.pages.enumerated() where i < buckets.count {
            document.setDrawing(PKDrawing(strokes: buckets[i]), for: page.id)
        }
    }

    // MARK: - Canvas drawing

    func setCanvasDrawing(_ drawing: PKDrawing) {
        // Handing PencilKit the same ink again makes it re-render every stroke,
        // which shows as a flicker (after typing, moving a text box, ...).
        let shown = canvas.drawing
        if shown.strokes.count == drawing.strokes.count, InkFingerprint.of(shown) == InkFingerprint.of(drawing) { return }
        isApplyingProgrammatic = true
        canvas.drawing = drawing
        isApplyingProgrammatic = false
        zoomWindow?.syncFromMain()
    }

    /// What the canvas should show for the baseline (replay fades future ink).
    func displayDrawing() -> PKDrawing {
        if replayTime != nil { return replayDisplayDrawing() }
        return baseline
    }

    // MARK: - State and undo

    var currentState: CanvasState {
        CanvasState(pages: document.pages, drawing: baseline, origin: boardOrigin)
    }

    /// Applies a change as one undoable step.
    func perform(_ name: String, _ change: (inout CanvasState) -> Void) {
        commitPendingInk()
        let old = currentState
        var new = old
        change(&new)
        apply(new)
        registerUndo(from: old, to: new, name: name)
        editor?.scheduleSave()
    }

    func registerUndo(from old: CanvasState, to new: CanvasState, name: String) {
        undoManager.registerUndo(withTarget: self) { target in
            target.restore(old, inverse: new, name: name)
        }
        undoManager.setActionName(name)
        canvas.clearUndoSink()
        editor?.undoStateChanged()
    }

    private func restore(_ state: CanvasState, inverse: CanvasState, name: String) {
        clearSelection()
        cancelTextEditing()
        apply(state)
        undoManager.registerUndo(withTarget: self) { target in
            target.restore(inverse, inverse: state, name: name)
        }
        undoManager.setActionName(name)
        editor?.scheduleSave()
        editor?.undoStateChanged()
    }

    /// Makes a state current: pages, layout, page tiles and ink.
    func apply(_ incoming: CanvasState) {
        let state = aligned(incoming)
        let oldPages = document.pages
        let structural = oldPages.count != state.pages.count
            || zip(oldPages, state.pages).contains { $0.id != $1.id || $0.size != $1.size }
        let oldByID = Dictionary(oldPages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        document.content.pages = state.pages
        document.markContentChanged()
        for page in state.pages where oldByID[page.id] != page {
            document.bump(page.id)
        }
        noteRemovedStrokes(from: baseline, to: state.drawing)
        baseline = state.drawing
        if structural {
            relayoutDocument()
        } else {
            refreshPageViews()
        }
        setCanvasDrawing(displayDrawing())
        editor?.pagesChanged()
        miniMap?.contentChanged()
    }

    /// Recomputes the page layout after pages were added, removed, resized or moved.
    func relayoutDocument() {
        let oldTopDocY = visibleDocRect.minY
        layout = DocumentLayout(pageSizes: document.pages.map(\.size))
        updateZoomLimits()
        for (_, v) in pageViews { v.removeFromSuperview() }
        pageViews.removeAll()
        visibleRange = 0 ..< 0
        updateZoomDependentLayout()
        let y = clampOffsetY(oldTopDocY * zoom)
        if abs(canvas.contentOffset.y - y) > 1 { canvas.contentOffset.y = y }
        updateVisiblePages(force: true)
    }

    /// Records ink the user just drew or erased as one undo step.
    func commitPendingInk() {
        guard pendingInkChange else { return }
        pendingInkChange = false
        guard replayTime == nil, dragSession == nil else { return }
        let reported = canvas.drawing
        let old = baseline
        if reported.strokes.count == old.strokes.count, InkFingerprint.of(reported) == InkFingerprint.of(old) { return }
        var drawing = reconcile(reported, with: old)
        if drawing.strokes.count != reported.strokes.count || InkFingerprint.of(drawing) != InkFingerprint.of(reported) {
            log.notice("NCUNDO reconciled ink: canvas \(reported.strokes.count) strokes, kept \(drawing.strokes.count)")
            setCanvasDrawing(drawing)
        }
        if drawing.strokes.count == old.strokes.count, InkFingerprint.of(drawing) == InkFingerprint.of(old) { return }
        let added = drawing.strokes.count == old.strokes.count + 1
        if added, lastDrawingTool == .pen, let last = drawing.strokes.last, let erased = scribbleErase(last, over: old) {
            // The scribble and what it covered go away as one undo step.
            clearSnapPreview()
            let before = CanvasState(pages: document.pages, drawing: old, origin: boardOrigin)
            removedStrokes.insert(StrokeKey(last))
            apply(erased)
            registerUndo(from: before, to: erased, name: "Scribble erase")
            historyDidChange()
            Haptics.snap()
            editor?.inkChanged(erased: true)
            editor?.scheduleSave()
            return
        }
        var changedCanvas = drawing.strokes.count != reported.strokes.count || InkFingerprint.of(drawing) != InkFingerprint.of(reported)
        if added, let last = drawing.strokes.last, let replacement = processNewStroke(last) {
            removedStrokes.insert(StrokeKey(last))
            drawing.strokes[drawing.strokes.count - 1] = replacement
            setCanvasDrawing(drawing)
            changedCanvas = true
        }
        if changedCanvas { historyDidChange() }
        clearSnapPreview()
        noteRemovedStrokes(from: old, to: drawing)
        baseline = drawing
        let pages = document.pages
        registerUndo(from: CanvasState(pages: pages, drawing: old, origin: boardOrigin), to: CanvasState(pages: pages, drawing: drawing, origin: boardOrigin), name: lastDrawingTool == .eraser ? "Erase" : "Ink")
        editor?.inkChanged(erased: lastDrawingTool == .eraser)
        editor?.scheduleSave()
        miniMap?.contentChanged()
        zoomWindow?.syncFromMain()
    }

    /// Remembers strokes that left the notebook (erased, undone, replaced), so a
    /// stale copy reported by PencilKit can never bring them back.
    func noteRemovedStrokes(from old: PKDrawing, to new: PKDrawing) {
        let newKeys = Set(new.strokes.map(StrokeKey.init))
        for stroke in old.strokes {
            let key = StrokeKey(stroke)
            if !newKeys.contains(key) { removedStrokes.insert(key) }
        }
        removedStrokes.subtract(newKeys)
        if removedStrokes.count > 50000 { removedStrokes.removeAll() }
    }

    /// PencilKit can finish a stroke on top of a stale copy of the drawing (for
    /// example when an undo lands while a finger stroke is starting), which would
    /// bring undone ink back or drop restored ink. A pen can only add strokes and
    /// the eraser can only remove or split them, so anything else the canvas
    /// reports is dropped.
    func reconcile(_ drawing: PKDrawing, with baseline: PKDrawing) -> PKDrawing {
        let known = Set(baseline.strokes.map(StrokeKey.init))
        let removed = removedStrokes
        let discardBefore = discardStrokesBefore
        func isStale(_ s: PKStroke) -> Bool {
            let key = StrokeKey(s)
            if known.contains(key) { return false }
            if removed.contains(key) { return true }
            // Started just before a tap undo and never committed: the tapping finger.
            let age = discardBefore.timeIntervalSince(s.path.creationDate)
            return age > 0 && age < 30
        }
        if lastDrawingTool.isInking {
            let fresh = drawing.strokes.filter { !known.contains(StrokeKey($0)) && !isStale($0) }
            return PKDrawing(strokes: baseline.strokes + fresh)
        }
        return PKDrawing(strokes: drawing.strokes.filter { !isStale($0) })
    }

    /// Called around undo and redo: ink started before now that is not in the
    /// baseline can only be stale, and the canvas must end up showing the baseline.
    func historyWillChange(fromTouch: Bool = false) {
        if fromTouch {
            // Ink the tapping fingers left behind is not part of the history.
            discardStrokesBefore = Date()
            commitPendingInk()
        } else {
            commitPendingInk()
            discardStrokesBefore = Date()
        }
        // A finger tap (two-finger undo) may have started a PencilKit stroke.
        let drawingGesture = canvas.drawingGestureRecognizer
        if drawingGesture.isEnabled, drawingGesture.state == .began || drawingGesture.state == .changed {
            drawingGesture.isEnabled = false
            drawingGesture.isEnabled = true
        }
    }

    func historyDidChange() {
        // PencilKit may restore its own copy a moment later; put the truth back.
        for delay in [0.05, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.resyncCanvasIfNeeded()
            }
        }
    }

    func resyncCanvasIfNeeded() {
        guard replayTime == nil, dragSession == nil, !toolInUse else { return }
        if pendingInkChange { commitPendingInk() }
        let shown = canvas.drawing
        if shown.strokes.count != baseline.strokes.count || InkFingerprint.of(shown) != InkFingerprint.of(baseline) {
            log.notice("NCUNDO canvas drifted from baseline (\(shown.strokes.count) vs \(self.baseline.strokes.count)); resynced")
            setCanvasDrawing(baseline)
        }
    }

    // MARK: - Page operations

    /// Edits pages together with their (page-local) ink as one undoable step.
    func performPageEdit(_ name: String, _ edit: (inout [Page], inout [[PKStroke]]) -> Void) {
        commitPendingInk()
        endTextEditing()
        clearSelection()
        perform(name) { state in
            let oldLayout = DocumentLayout(pageSizes: state.pages.map(\.size))
            var strokes = splitStrokes(state.drawing, layout: oldLayout)
            var pages = state.pages
            edit(&pages, &strokes)
            if pages.isEmpty {
                // A notebook always has at least one page.
                let blank = Page(style: AppSettings.shared.defaultPaper)
                pages = [blank]
                strokes = [[]]
            }
            while strokes.count < pages.count { strokes.append([]) }
            if strokes.count > pages.count { strokes.removeLast(strokes.count - pages.count) }
            let newLayout = DocumentLayout(pageSizes: pages.map(\.size))
            state.pages = pages
            state.drawing = composeStrokes(strokes, layout: newLayout)
        }
    }

    func performElementEdit(_ name: String, pageID: UUID, _ edit: (inout Page) -> Void) {
        perform(name) { state in
            guard let i = state.pages.firstIndex(where: { $0.id == pageID }) else { return }
            edit(&state.pages[i])
        }
    }

    // MARK: - Tools

    func applyTool(_ tools: ToolState) {
        let previous = currentTool
        currentTool = tools.tool
        if previous != tools.tool {
            commitPendingInk()
            if previous == .text { endTextEditing() }
            if previous == .lasso && tools.tool != .lasso { clearSelection() }
            clearLasso()
        }
        let usesDrawing = tools.tool.usesCanvasDrawing && replayTime == nil
        if let pk = tools.pkTool(for: tools.tool) {
            canvas.tool = pk
            zoomWindow?.applyTool(pk, fingerDraws: AppSettings.shared.drawWithFinger)
        }
        canvas.drawingGestureRecognizer.isEnabled = usesDrawing
        let fingerDraws = AppSettings.shared.drawWithFinger
        canvas.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
        let touchTypes: [NSNumber] = fingerDraws
            ? [NSNumber(value: UITouch.TouchType.pencil.rawValue), NSNumber(value: UITouch.TouchType.direct.rawValue)]
            : [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        toolPan.allowedTouchTypes = touchTypes
        // Fingers scroll; with finger drawing on, scrolling takes two fingers
        // (except with the text tool, which never draws).
        let pan = canvas.panGestureRecognizer
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        pan.minimumNumberOfTouches = (fingerDraws && tools.tool != .text && replayTime == nil) ? 2 : 1
        toolTap.allowedTouchTypes = touchTypes
        toolPan.isEnabled = tools.tool == .lasso || tools.tool == .laser
        toolTap.isEnabled = tools.tool == .lasso || tools.tool == .text || replayTime != nil
        touchObserver.trackFingers = fingerDraws
        touchObserver.isEnabled = tools.tool.isInking
        laserLayer.strokeColor = UIColor(tools.laserColor).cgColor
        laserGlowLayer.strokeColor = UIColor(tools.laserColor).cgColor
    }

    func updateChromeAppearance(_ style: UIUserInterfaceStyle) {
        canvas.deskMask.overrideUserInterfaceStyle = style
        canvas.overlay.overrideUserInterfaceStyle = style
    }

    // MARK: - Teardown

    func prepareToClose() {
        endTextEditing()
        commitPendingInk()
        clearSelection()
        flushInkToDocument()
        for token in keyboardObservers { NotificationCenter.default.removeObserver(token) }
        keyboardObservers.removeAll()
        laserFadeTimer?.invalidate()
        zoomLink?.invalidate()
        zoomLink = nil
    }
}

// MARK: - Scroll and canvas delegate

extension CanvasController: PKCanvasViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateVisiblePages()
        if selectionView != nil || textEditor != nil { layoutOverlays() }
        // A whiteboard keeps growing ahead of you (right and down even mid-scroll).
        if isBoard {
            ensureBoardRoom(allowShift: false)
            miniMap?.updateViewport()
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { growBoardWhenSettled() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        growBoardWhenSettled()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        growBoardWhenSettled()
    }

    /// The scroll view still reports dragging inside its end callbacks.
    private func growBoardWhenSettled() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Whatever PencilKit shows must be the notebook's ink.
            self.resyncCanvasIfNeeded()
            if self.isBoard { self.ensureBoardRoom(allowShift: true) }
        }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateZoomDependentLayout()
        // Show the zoom level only while the user pinches (or a zoom animates).
        if scrollView.isZooming || scrollView.isZoomBouncing || zoomAnimation != nil {
            editor?.canvasZoomChanged(percent: Int((relativeZoom * 100).rounded()))
        }
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        editor?.canvasZoomBegan()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        defer { growBoardWhenSettled() }
        // Snap to fit-width when close: makes it easy to get back to the default.
        if abs(scale / fitZoom - 1) < 0.06, abs(scale - fitZoom) > 0.0001 {
            let view = CGPoint(x: canvas.bounds.width / 2, y: canvas.bounds.height / 2)
            let doc = contentToDoc(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
            animateZoom(to: fitZoom, keeping: doc, at: view, duration: 0.2)
        }
        updateZoomDependentLayout()
        textEditor?.rescale(zoom: zoom)
        editor?.canvasZoomEnded()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        // While a selection is being dragged the canvas shows a temporary drawing.
        guard !isApplyingProgrammatic, replayTime == nil, dragSession == nil else { return }
        if selection != nil { clearSelection() }
        pendingInkChange = true
        if !toolInUse { scheduleCommit() }
    }

    /// Commits ink once PencilKit has returned from its callback. Replacing the
    /// canvas drawing while PencilKit is still finishing a stroke (a scribble
    /// erase, a snapped shape) leaves PencilKit holding an old copy, which it
    /// shows again on the next zoom or scroll and later reports back as ink.
    func scheduleCommit() {
        guard !commitScheduled else { return }
        commitScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.commitScheduled = false
            self.commitPendingInk()
        }
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        toolInUse = true
        lastDrawingTool = currentTool
        if selection != nil { clearSelection() }
        if textEditor != nil { endTextEditing() }
        editor?.canvasBeganDrawing()
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        toolInUse = false
        // The final stroke may be delivered just after the tool ends, and the
        // canvas must not be changed from inside PencilKit's callbacks.
        scheduleCommit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.commitPendingInk()
        }
    }
}

/// Root view handed to SwiftUI. The ink canvas is forced to the light
/// appearance (so ink colors never invert); the desk and overlays follow the app.
final class CanvasRootView: UIView {
    weak var controller: CanvasController?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: CanvasRootView, _) in
            view.controller?.updateChromeAppearance(view.traitCollection.userInterfaceStyle)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        controller?.updateChromeAppearance(traitCollection.userInterfaceStyle)
    }
}

extension CGRect {
    func integral(scale: CGFloat) -> CGRect {
        guard scale > 0 else { return integral }
        return CGRect(
            x: (minX * scale).rounded() / scale,
            y: (minY * scale).rounded() / scale,
            width: (width * scale).rounded() / scale,
            height: (height * scale).rounded() / scale
        )
    }
}

/// Identifies a stroke well enough to tell whether the canvas brought back one
/// that was removed.
nonisolated struct StrokeKey: Hashable {
    var date: Double
    var count: Int
    var tx: CGFloat
    var ty: CGFloat

    init(_ s: PKStroke) {
        date = s.path.creationDate.timeIntervalSinceReferenceDate
        count = s.path.count
        tx = s.transform.tx
        ty = s.transform.ty
    }
}

// MARK: - Endless whiteboard

extension CanvasController {
    /// A state moved to the board's current position. A board also never
    /// shrinks back: growing is not something undo takes away.
    func aligned(_ state: CanvasState) -> CanvasState {
        guard isBoard || state.origin != boardOrigin else { return state }
        let dx = boardOrigin.x - state.origin.x, dy = boardOrigin.y - state.origin.y
        var result = state
        if dx != 0 || dy != 0 {
            result.drawing = state.drawing.transformed(using: CGAffineTransform(translationX: dx, y: dy))
        }
        result.pages = state.pages.map { page in
            guard page.isBoard else { return page }
            var p = page
            if let current = document.pages.first(where: { $0.id == page.id }), current.isBoard {
                p.size = current.size
            }
            if dx != 0 || dy != 0 { CanvasController.move(&p, dx: dx, dy: dy) }
            return p
        }
        result.origin = boardOrigin
        return result
    }

    static func move(_ page: inout Page, dx: CGFloat, dy: CGFloat) {
        page.elements = page.elements.map { element in
            var e = element
            e.frame = e.frame.offsetBy(dx: dx, dy: dy)
            return e
        }
        if var recognition = page.recognition {
            recognition.lines = recognition.lines.map { line in
                var l = line
                l.rect = l.rect.offsetBy(dx: dx, dy: dy)
                return l
            }
            page.recognition = recognition
        }
    }

    /// Keeps plenty of board around what is on screen, so you never reach an
    /// edge. Growing right or down only enlarges the board; growing left or up
    /// also moves everything over (the view stays put), so that waits until
    /// nothing is being dragged, edited or animated.
    func ensureBoardRoom(allowShift: Bool) {
        guard isBoard, didInitialLayout, !isGrowingBoard, let frame = layout.frame(of: 0) else { return }
        let visible = visibleDocRect
        guard visible.width > 1, visible.height > 1 else { return }
        // Mid-zoom the offset can briefly belong to the old zoom (the view seems
        // to be off the board); that is not a reason to grow.
        guard visible.intersects(frame) else { return }
        let margin = max(max(visible.width, visible.height) * 1.25, 4000)
        let needLeft = max(0, margin - (visible.minX - frame.minX))
        let needTop = max(0, margin - (visible.minY - frame.minY))
        let needRight = max(0, margin - (frame.maxX - visible.maxX))
        let needBottom = max(0, margin - (frame.maxY - visible.maxY))
        let canShift = allowShift && selection == nil && textEditor == nil && dragSession == nil
            && replayTime == nil && !toolInUse && zoomAnimation == nil && !canvas.isDragging && !canvas.isDecelerating
        let left = canShift ? needLeft : 0
        let top = canShift ? needTop : 0
        guard left + top + needRight + needBottom > 0 else { return }
        // Grow in big steps so it happens rarely.
        func step(_ need: CGFloat) -> CGFloat { need > 0 ? max(need, margin * 2) : 0 }
        growBoard(left: step(left), top: step(top), right: step(needRight), bottom: step(needBottom))
    }

    /// Enlarges a whiteboard on any side (document points).
    func growBoard(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) {
        guard isBoard, var page = document.pages.first else { return }
        // Grow by whole pattern repeats (at every zoom level's thinning) so dots
        // and grid lines stay in place and nothing needs redrawing.
        let period = CGFloat(PageRenderer.boardPatternPeriod)
        func q(_ v: CGFloat) -> CGFloat { v > 0 ? (v / period).rounded(.up) * period : 0 }
        let limit = CGFloat(NotebookKind.maxBoardSide)
        var l = q(left), t = q(top), r = q(right), b = q(bottom)
        let roomX = max(0, limit - page.size.width), roomY = max(0, limit - page.size.height)
        if l + r > roomX { let f = roomX / (l + r); l = (l * f / period).rounded(.down) * period; r = (r * f / period).rounded(.down) * period }
        if t + b > roomY { let f = roomY / (t + b); t = (t * f / period).rounded(.down) * period; b = (b * f / period).rounded(.down) * period }
        guard l + t + r + b > 0 else { return }

        isGrowingBoard = true
        defer { isGrowingBoard = false }
        commitPendingInk()
        let offset = canvas.contentOffset
        page.size = CGSize(width: page.size.width + l + r, height: page.size.height + t + b)
        if l != 0 || t != 0 {
            CanvasController.move(&page, dx: l, dy: t)
            baseline = baseline.transformed(using: CGAffineTransform(translationX: l, y: t))
            removedStrokes = Set(removedStrokes.map { key in
                var k = key
                k.tx += l
                k.ty += t
                return k
            })
            boardOrigin.x += l
            boardOrigin.y += t
            clearLasso()
            showHighlights([], current: nil)
        }
        document.content.pages[0] = page
        document.markContentChanged()
        document.bump(page.id)
        layout = DocumentLayout(pageSizes: document.pages.map(\.size))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateZoomDependentLayout()
        if l != 0 || t != 0 {
            canvas.contentOffset = CGPoint(x: offset.x + l * zoom, y: offset.y + t * zoom)
            setCanvasDrawing(displayDrawing())
            updateVisiblePages(force: true)
            layoutOverlays()
        }
        CATransaction.commit()
        if l != 0 || t != 0 { miniMap?.contentChanged() }
        log.notice("NCBOARD grew left \(Int(l)) top \(Int(t)) right \(Int(r)) bottom \(Int(b)) -> \(Int(page.size.width))x\(Int(page.size.height))")
        editor?.scheduleSave()
    }
}
