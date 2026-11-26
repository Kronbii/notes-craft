import NotesCraftCore
import PencilKit
import UIKit

/// The zoom window: a magnified strip at the bottom where you write comfortably
/// while the ink lands, normal size, inside a box on the page. It is a second
/// PencilKit canvas in the page's own coordinates (just zoomed in), so ink keeps
/// its real width and joins the page's undo history.
final class ZoomWindowController: NSObject, PKCanvasViewDelegate {
    weak var canvas: CanvasController?

    /// The panel area: page background image, then the writing canvas.
    let view = UIView()
    private let paper = UIImageView()
    let writing = PKCanvasView()
    private let advanceGuide = UIView()

    /// The page area being written (document coordinates).
    private(set) var target: CGRect = .zero
    /// How much bigger the writing is than on the page.
    var magnification: CGFloat = 2.5 {
        didSet { if oldValue != magnification { resizeTarget(keepingOrigin: true) } }
    }
    var autoAdvance = true

    private var applying = false
    private var toolInUse = false
    private var pending = false
    private var commitScheduled = false
    /// Where the current line started (for "new line").
    private var lineStartX: CGFloat?

    override init() {
        super.init()
        view.clipsToBounds = true
        view.layer.cornerRadius = 14
        view.layer.cornerCurve = .continuous
        view.backgroundColor = .white
        paper.contentMode = .scaleToFill
        view.addSubview(paper)
        writing.backgroundColor = .clear
        writing.isOpaque = false
        writing.overrideUserInterfaceStyle = .light
        writing.isScrollEnabled = false
        writing.bouncesZoom = false
        writing.showsVerticalScrollIndicator = false
        writing.showsHorizontalScrollIndicator = false
        writing.contentInsetAdjustmentBehavior = .never
        writing.delegate = self
        view.addSubview(writing)
        advanceGuide.backgroundColor = Theme.canvasAccentUI.withAlphaComponent(0.35)
        advanceGuide.isUserInteractionEnabled = false
        view.addSubview(advanceGuide)
    }

    // MARK: Layout

    /// Called when the panel's size changes.
    func layout() {
        writing.frame = view.bounds
        paper.frame = view.bounds
        advanceGuide.frame = CGRect(x: view.bounds.width * 0.78, y: 10, width: 1.5, height: max(0, view.bounds.height - 20))
        advanceGuide.isHidden = !autoAdvance
        resizeTarget(keepingOrigin: true)
    }

    /// Places the box at the start of the visible part of the current page.
    func placeInitially() {
        guard let c = canvas else { return }
        let visible = c.visibleDocRect
        let index = c.isBoard ? 0 : (c.layout.pageIndex(forY: visible.minY + visible.height * 0.25) ?? 0)
        guard let page = c.layout.frame(of: index) else { return }
        let size = targetSize
        let x = c.isBoard ? max(page.minX, visible.minX + 40) : page.minX + leftMargin(page)
        let y = max(page.minY + 60, visible.minY + 60)
        lineStartX = x
        moveTarget(to: CGRect(origin: CGPoint(x: x, y: min(y, page.maxY - size.height)), size: size), scroll: true)
    }

    private var targetSize: CGSize {
        let m = max(magnification, 1)
        return CGSize(width: max(view.bounds.width, 200) / m, height: max(view.bounds.height, 100) / m)
    }

    private func resizeTarget(keepingOrigin: Bool) {
        guard target != .zero else { return }
        moveTarget(to: CGRect(origin: target.origin, size: targetSize), scroll: false)
    }

    private func leftMargin(_ page: CGRect) -> CGFloat {
        min(max(page.width * 0.13, 48), 96) + 6
    }

    private func pageFrame(containing rect: CGRect) -> CGRect? {
        guard let c = canvas else { return nil }
        if c.isBoard { return c.layout.frame(of: 0) }
        guard let i = c.layout.pageIndex(forY: rect.midY) else { return nil }
        return c.layout.frame(of: i)
    }

    /// Moves the box, keeping it on a page, and shows that area magnified.
    func moveTarget(to rect: CGRect, scroll: Bool) {
        guard let c = canvas else { return }
        var r = rect
        if let page = pageFrame(containing: rect) {
            r.origin.x = min(max(r.minX, page.minX), page.maxX - r.width)
            r.origin.y = min(max(r.minY, page.minY), page.maxY - r.height)
        }
        target = r
        let m = magnification
        applying = true
        writing.minimumZoomScale = m
        writing.maximumZoomScale = m
        writing.zoomScale = m
        writing.contentSize = CGSize(width: c.layout.contentSize.width * m, height: c.layout.contentSize.height * m)
        writing.contentOffset = CGPoint(x: r.minX * m, y: r.minY * m)
        applying = false
        renderPaper()
        syncFromMain()
        c.layoutZoomTarget()
        if scroll { c.ensureVisible(docRect: r.insetBy(dx: 0, dy: -20), animated: true) }
    }

    func nudge(dx: CGFloat, dy: CGFloat) {
        moveTarget(to: target.offsetBy(dx: dx * target.width, dy: dy * target.height), scroll: true)
    }

    /// Back to the start of the line, one line down.
    func newLine() {
        guard let page = pageFrame(containing: target) else { return }
        let start = lineStartX ?? (canvas?.isBoard == true ? target.minX : page.minX + leftMargin(page))
        var step = target.height * 0.6
        // On ruled paper, move by whole lines.
        if let c = canvas, !c.isBoard, let i = c.layout.pageIndex(forY: target.midY), c.document.pages.indices.contains(i),
           let kind = c.document.pages[i].background.paperKind, kind.spacing > 0 {
            step = max(1, (step / CGFloat(kind.spacing)).rounded()) * CGFloat(kind.spacing)
        }
        var next = CGRect(x: start, y: target.minY + step, width: target.width, height: target.height)
        // Past the page's end: the next page, if there is one.
        if let c = canvas, !c.isBoard, next.maxY > page.maxY, let i = c.layout.pageIndex(forY: page.midY), let below = c.layout.frame(of: i + 1) {
            next.origin.y = below.minY + 60
            next.origin.x = below.minX + leftMargin(below)
        }
        lineStartX = next.minX
        moveTarget(to: next, scroll: true)
    }

    /// After writing near the right edge, slide along (or go to the next line).
    private func advanceIfNeeded(after added: [PKStroke]) {
        guard autoAdvance, let reach = added.map(\.renderBounds.maxX).max(), let page = pageFrame(containing: target) else { return }
        guard reach > target.minX + target.width * 0.78 else { return }
        let rightLimit = canvas?.isBoard == true ? CGFloat.greatestFiniteMagnitude : page.maxX - 24
        if target.maxX + target.width * 0.5 <= rightLimit {
            moveTarget(to: target.offsetBy(dx: target.width * 0.55, dy: 0), scroll: true)
        } else {
            newLine()
        }
    }

    // MARK: Paper

    /// The page (paper, text boxes, images) behind the writing, magnified.
    private func renderPaper() {
        guard let c = canvas, view.bounds.width > 0, let page = pageFrame(containing: target),
              let index = c.isBoard ? 0 : c.layout.pageIndex(forY: target.midY), c.document.pages.indices.contains(index) else { return }
        let model = c.document.pages[index]
        let local = target.offsetBy(dx: -page.minX, dy: -page.minY)
        let m = magnification
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { ctx in
            let g = ctx.cgContext
            g.scaleBy(x: m, y: m)
            g.translateBy(x: -local.minX, y: -local.minY)
            g.clip(to: local)
            PageRenderer.drawBackground(model.background, size: model.size, assets: c.document.assets, in: g, board: model.isBoard)
            PageRenderer.drawElements(model.elements.filter { $0.frame.intersects(local) }, assets: c.document.assets, in: g, imageMaxPixels: 1600)
        }
        paper.image = image
    }

    // MARK: Ink

    /// Shows the page's ink (after anything changed it).
    func syncFromMain() {
        guard let c = canvas, !toolInUse else { return }
        let ink = c.baseline
        let shown = writing.drawing
        if shown.strokes.count == ink.strokes.count, InkFingerprint.of(shown) == InkFingerprint.of(ink) { return }
        applying = true
        writing.drawing = ink
        applying = false
    }

    func applyTool(_ tool: PKTool, fingerDraws: Bool) {
        writing.tool = tool
        writing.drawingPolicy = fingerDraws ? .anyInput : .pencilOnly
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        toolInUse = true
        canvas?.zoomWindowBeganWriting()
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        toolInUse = false
        scheduleCommit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.commit() }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !applying else { return }
        pending = true
        if !toolInUse { scheduleCommit() }
    }

    /// Like the page canvas: never change the drawing inside PencilKit's callbacks.
    private func scheduleCommit() {
        guard !commitScheduled else { return }
        commitScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.commitScheduled = false
            self?.commit()
        }
    }

    private func commit() {
        guard pending, !toolInUse, let c = canvas else { return }
        pending = false
        let before = c.baseline
        let known = Set(before.strokes.map(StrokeKey.init))
        let now = writing.drawing.strokes
        let nowKeys = Set(now.map(StrokeKey.init))
        let removed = known.subtracting(nowKeys)
        let added = now.filter { !known.contains(StrokeKey($0)) }
        guard !removed.isEmpty || !added.isEmpty else { return }
        c.commitZoomWindowChange(removed: removed, added: added)
        syncFromMain()
        if removed.isEmpty { advanceIfNeeded(after: added) }
    }
}

/// The box on the page that the zoom window writes into. Drag it to move.
final class ZoomTargetView: UIView {
    var onDrag: ((CGPoint, UIGestureRecognizer.State) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.canvasAccentUI.withAlphaComponent(0.07)
        layer.borderColor = Theme.canvasAccentUI.cgColor
        layer.borderWidth = 2
        layer.cornerRadius = 6
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        addGestureRecognizer(pan)
        isAccessibilityElement = true
        accessibilityLabel = "Zoom window area"
        accessibilityHint = "Drag to choose where the zoom window writes"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func drag(_ g: UIPanGestureRecognizer) {
        onDrag?(g.translation(in: superview), g.state)
        g.setTranslation(.zero, in: superview)
    }
}

extension CanvasController {
    func openZoomWindow() -> ZoomWindowController {
        if let existing = zoomWindow { return existing }
        let z = ZoomWindowController()
        z.canvas = self
        zoomWindow = z
        if let tool = editor?.tools.pkTool(for: currentTool) { z.applyTool(tool, fingerDraws: AppSettings.shared.drawWithFinger) }
        let box = ZoomTargetView()
        box.onDrag = { [weak self] translation, _ in
            guard let self, let z = self.zoomWindow else { return }
            z.moveTarget(to: z.target.offsetBy(dx: translation.x / self.zoom, dy: translation.y / self.zoom), scroll: false)
        }
        canvas.overlay.addSubview(box)
        zoomTargetView = box
        return z
    }

    func closeZoomWindow() {
        zoomTargetView?.removeFromSuperview()
        zoomTargetView = nil
        zoomWindow = nil
        setZoomPanelInset(0)
    }

    /// Room the zoom window takes at the bottom (kept clear when scrolling to the box).
    func setZoomPanelInset(_ inset: CGFloat) {
        guard abs(zoomPanelInset - inset) > 0.5 else { return }
        zoomPanelInset = inset
        updateInsets()
    }

    func layoutZoomTarget() {
        guard let z = zoomWindow, let box = zoomTargetView else { return }
        box.frame = docToContent(z.target)
    }

    func zoomWindowBeganWriting() {
        if selection != nil { clearSelection() }
        if textEditor != nil { endTextEditing() }
        editor?.canvasBeganDrawing()
    }

    /// Ink written or erased in the zoom window: one undo step, like the page's own.
    func commitZoomWindowChange(removed: Set<StrokeKey>, added: [PKStroke]) {
        commitPendingInk()
        let old = baseline
        let pages = document.pages
        // A single new pen stroke may be a scribble over ink.
        if removed.isEmpty, added.count == 1, currentTool == .pen, let erased = scribbleErase(added[0], over: old) {
            let before = CanvasState(pages: pages, drawing: old, origin: boardOrigin)
            removedStrokes.insert(StrokeKey(added[0]))
            apply(erased)
            registerUndo(from: before, to: erased, name: "Scribble erase")
            Haptics.snap()
            editor?.scheduleSave()
            return
        }
        var strokes = old.strokes.filter { !removed.contains(StrokeKey($0)) }
        strokes.append(contentsOf: added)
        let new = PKDrawing(strokes: strokes)
        noteRemovedStrokes(from: old, to: new)
        baseline = new
        setCanvasDrawing(displayDrawing())
        registerUndo(from: CanvasState(pages: pages, drawing: old, origin: boardOrigin),
                     to: CanvasState(pages: pages, drawing: new, origin: boardOrigin),
                     name: removed.isEmpty ? "Ink" : "Erase")
        editor?.inkChanged(erased: !removed.isEmpty)
        editor?.scheduleSave()
        miniMap?.contentChanged()
    }
}
