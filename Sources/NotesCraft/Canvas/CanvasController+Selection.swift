import NotesCraftCore
import PencilKit
import UIKit

struct ElementRef: Hashable {
    var pageID: UUID
    var elementID: UUID
}

/// What the lasso picked: strokes (indices into the baseline ink) and elements.
struct CanvasSelection {
    var strokeIndices: [Int]
    var elements: [ElementRef]
    /// Document-space bounds.
    var bounds: CGRect

    var isEmpty: Bool { strokeIndices.isEmpty && elements.isEmpty }

    func isSingleElement(_ id: UUID) -> Bool {
        strokeIndices.isEmpty && elements.count == 1 && elements[0].elementID == id
    }

    var isSingleText: Bool { strokeIndices.isEmpty && elements.count == 1 }
}

struct DragSession {
    enum Kind { case move, resize(corner: Int) }
    var kind: Kind
    var original: CanvasState
    var originalBounds: CGRect
    var floating: UIImageView
    var transform: CGAffineTransform = .identity
    /// Text-only resizes change the box width instead of scaling.
    var widthOnly = false
}

extension CanvasController {
    // MARK: - Lasso

    func handleLassoPan(_ g: UIPanGestureRecognizer) {
        let p = docPoint(g)
        switch g.state {
        case .began:
            clearSelection()
            lassoPoints = [p]
            updateLassoLayer()
        case .changed:
            if let last = lassoPoints.last, hypot(last.x - p.x, last.y - p.y) * zoom < 2 { return }
            lassoPoints.append(p)
            updateLassoLayer()
        case .ended:
            lassoPoints.append(p)
            let polygon = lassoPoints
            clearLasso()
            selectInside(polygon)
        default:
            clearLasso()
        }
    }

    func updateLassoLayer() {
        let path = CGMutablePath()
        if let first = lassoPoints.first {
            path.move(to: docToContent(first))
            for p in lassoPoints.dropFirst() { path.addLine(to: docToContent(p)) }
            path.closeSubpath()
        }
        lassoLayer.path = path
    }

    func clearLasso() {
        lassoPoints.removeAll()
        lassoLayer.path = nil
    }

    static func polygonContains(_ poly: [CGPoint], _ p: CGPoint) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0 ..< poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    func selectInside(_ polygon: [CGPoint]) {
        guard polygon.count >= 3 else { return }
        var box = CGRect.null
        for p in polygon { box = box.union(CGRect(origin: p, size: .zero)) }
        guard box.width * zoom > 6 || box.height * zoom > 6 else { return }
        var indices: [Int] = []
        for (i, stroke) in baseline.strokes.enumerated() where stroke.renderBounds.intersects(box) {
            var inside = 0, total = 0
            for point in stroke.path.interpolatedPoints(by: .distance(5)) {
                total += 1
                if Self.polygonContains(polygon, point.location.applying(stroke.transform)) { inside += 1 }
            }
            if total > 0, Double(inside) / Double(total) >= 0.5 { indices.append(i) }
        }
        var refs: [ElementRef] = []
        for pi in layout.pages(intersecting: box) {
            let frame = layout.pageFrames[pi]
            let page = document.pages[pi]
            for el in page.elements {
                let r = el.frame.offsetBy(dx: frame.minX, dy: frame.minY)
                let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
                let cornersInside = corners.filter { Self.polygonContains(polygon, $0) }.count
                if Self.polygonContains(polygon, CGPoint(x: r.midX, y: r.midY)) || cornersInside >= 2 {
                    refs.append(ElementRef(pageID: page.id, elementID: el.id))
                }
            }
        }
        setSelection(strokes: indices, elements: refs)
    }

    func selectStrokes(_ indices: [Int]) {
        setSelection(strokes: indices, elements: [])
    }

    func selectElement(_ id: UUID, pageID: UUID) {
        endTextEditing()
        setSelection(strokes: [], elements: [ElementRef(pageID: pageID, elementID: id)])
    }

    func setSelection(strokes: [Int], elements: [ElementRef]) {
        let sel = CanvasSelection(strokeIndices: strokes.sorted(), elements: elements, bounds: .null)
        guard !sel.isEmpty else {
            clearSelection()
            return
        }
        selection = sel
        selection?.bounds = selectionBounds(sel)
        if selectionView == nil {
            let view = SelectionView(controller: self)
            canvas.overlay.addSubview(view)
            selectionView = view
        }
        selectionView?.configure(selection: selection!)
        layoutSelectionView()
        Haptics.tap()
        editor?.selectionChanged(hasSelection: true)
    }

    func clearSelection() {
        if dragSession != nil { cancelDrag() }
        guard selection != nil || selectionView != nil else { return }
        selection = nil
        selectionView?.removeFromSuperview()
        selectionView = nil
        editor?.selectionChanged(hasSelection: false)
    }

    func selectionBounds(_ sel: CanvasSelection) -> CGRect {
        var r = CGRect.null
        let strokes = baseline.strokes
        for i in sel.strokeIndices where i < strokes.count { r = r.union(strokes[i].renderBounds) }
        for ref in sel.elements {
            if let frame = docFrame(of: ref) { r = r.union(frame) }
        }
        return r
    }

    func docFrame(of ref: ElementRef) -> CGRect? {
        guard let i = document.pageIndex(of: ref.pageID), let el = document.pages[i].elements.first(where: { $0.id == ref.elementID }) else { return nil }
        let origin = layout.pageFrames[i].origin
        return el.frame.offsetBy(dx: origin.x, dy: origin.y)
    }

    func layoutSelectionView() {
        guard let selection, let view = selectionView else { return }
        var bounds = selection.bounds
        if let drag = dragSession { bounds = drag.originalBounds.applying(drag.transform) }
        view.layout(contentRect: docToContent(bounds), visible: canvas.bounds)
    }

    func showSelectionMenu() {
        selectionView?.flashBar()
    }

    // MARK: - Dragging (move and resize)

    func beginDrag(_ kind: DragSession.Kind) {
        guard let selection, dragSession == nil else { return }
        commitPendingInk()
        let original = currentState
        let image = renderSelectionImage(selection, state: original, scale: min(zoom * canvas.traitCollection.displayScale, 4))
        let floating = UIImageView(image: image)
        floating.frame = docToContent(selection.bounds)
        floating.isUserInteractionEnabled = false
        canvas.overlay.insertSubview(floating, at: 0)
        var widthOnly = false
        if case .resize = kind, selection.strokeIndices.isEmpty, selection.elements.count == 1,
           let ref = selection.elements.first, element(ref)?.isText == true {
            widthOnly = true
        }
        dragSession = DragSession(kind: kind, original: original, originalBounds: selection.bounds, floating: floating, widthOnly: widthOnly)
        // Hide the originals while the floating copy moves.
        let selected = Set(selection.strokeIndices)
        let remaining = original.drawing.strokes.enumerated().filter { !selected.contains($0.offset) }.map(\.element)
        setCanvasDrawing(PKDrawing(strokes: remaining))
        hiddenElements = Set(selection.elements.map(\.elementID))
        refreshPageViews()
    }

    func updateDrag(translation: CGPoint) {
        guard var drag = dragSession else { return }
        let dx = translation.x / zoom, dy = translation.y / zoom
        let b = drag.originalBounds
        switch drag.kind {
        case .move:
            drag.transform = CGAffineTransform(translationX: dx, y: dy)
        case let .resize(corner):
            // Corners: 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left.
            let anchor: CGPoint
            let moving: CGPoint
            switch corner {
            case 0: anchor = CGPoint(x: b.maxX, y: b.maxY); moving = CGPoint(x: b.minX, y: b.minY)
            case 1: anchor = CGPoint(x: b.minX, y: b.maxY); moving = CGPoint(x: b.maxX, y: b.minY)
            case 2: anchor = CGPoint(x: b.minX, y: b.minY); moving = CGPoint(x: b.maxX, y: b.maxY)
            default: anchor = CGPoint(x: b.maxX, y: b.minY); moving = CGPoint(x: b.minX, y: b.maxY)
            }
            let w0 = moving.x - anchor.x, h0 = moving.y - anchor.y
            let w1 = w0 + dx, h1 = h0 + dy
            var sx = abs(w0) > 0.5 ? w1 / w0 : 1
            var sy = abs(h0) > 0.5 ? h1 / h0 : 1
            if drag.widthOnly {
                sx = max(sx, 40 / max(b.width, 1))
                sy = 1
            } else {
                let s = max(min(max(sx, sy), 20), 0.08)
                sx = s
                sy = s
            }
            drag.transform = CGAffineTransform(translationX: anchor.x, y: anchor.y)
                .scaledBy(x: sx, y: sy)
                .translatedBy(x: -anchor.x, y: -anchor.y)
        }
        dragSession = drag
        let newBounds = b.applying(drag.transform)
        if drag.widthOnly {
            drag.floating.contentMode = .topLeft
            drag.floating.clipsToBounds = true
        }
        drag.floating.frame = docToContent(newBounds)
        layoutSelectionView()
    }

    func endDrag() {
        guard let drag = dragSession, var selection else { return }
        dragSession = nil
        let t = drag.transform
        if t.isIdentity {
            cancelDragDisplay(drag)
            return
        }
        var state = drag.original
        // Strokes keep their indices; only their transforms change.
        var strokes = state.drawing.strokes
        for i in selection.strokeIndices where i < strokes.count {
            strokes[i].transform = strokes[i].transform.concatenating(t)
        }
        state.drawing = PKDrawing(strokes: strokes)
        // Elements: transform, then move to whichever page their center lands on.
        let newLayout = layout
        var newRefs: [ElementRef] = []
        for ref in selection.elements {
            guard let from = state.pages.firstIndex(where: { $0.id == ref.pageID }),
                  let ei = state.pages[from].elements.firstIndex(where: { $0.id == ref.elementID }) else { continue }
            var element = state.pages[from].elements[ei]
            let origin = newLayout.pageFrames[from].origin
            var docRect = element.frame.offsetBy(dx: origin.x, dy: origin.y)
            if drag.widthOnly {
                let newRect = docRect.applying(t)
                docRect = CGRect(x: newRect.minX, y: docRect.minY, width: max(newRect.width, 40), height: docRect.height)
            } else {
                docRect = docRect.applying(t)
            }
            let center = CGPoint(x: docRect.midX, y: docRect.midY)
            let to = newLayout.pageIndex(forY: center.y) ?? from
            let toOrigin = newLayout.pageFrames[to].origin
            element.frame = docRect.offsetBy(dx: -toOrigin.x, dy: -toOrigin.y)
            if let text = element.textContent {
                element.frame.size.height = TextStyling.measuredHeight(text, width: element.frame.width)
            }
            state.pages[from].elements.remove(at: ei)
            state.pages[to].elements.append(element)
            newRefs.append(ElementRef(pageID: state.pages[to].id, elementID: element.id))
        }
        hiddenElements.removeAll()
        apply(state)
        registerUndo(from: drag.original, to: state, name: drag.kindName)
        editor?.scheduleSave()
        selection.elements = newRefs
        selection.bounds = selectionBounds(selection)
        self.selection = selection
        selectionView?.configure(selection: selection)
        layoutSelectionView()
        // Keep the floating copy briefly so tiles can redraw underneath it.
        let floating = drag.floating
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { floating.removeFromSuperview() }
    }

    func cancelDrag() {
        guard let drag = dragSession else { return }
        dragSession = nil
        cancelDragDisplay(drag)
    }

    private func cancelDragDisplay(_ drag: DragSession) {
        hiddenElements.removeAll()
        setCanvasDrawing(displayDrawing())
        refreshPageViews()
        drag.floating.removeFromSuperview()
        layoutSelectionView()
    }

    func element(_ ref: ElementRef) -> PageElement? {
        document.pages.first { $0.id == ref.pageID }?.elements.first { $0.id == ref.elementID }
    }

    /// Renders the selected strokes and elements (document space) to an image.
    func renderSelectionImage(_ sel: CanvasSelection, state: CanvasState, scale: CGFloat) -> UIImage {
        let bounds = sel.bounds.isNull ? CGRect(x: 0, y: 0, width: 1, height: 1) : sel.bounds
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(scale, 1)
        format.opaque = false
        let strokes = sel.strokeIndices.compactMap { state.drawing.strokes.indices.contains($0) ? state.drawing.strokes[$0] : nil }
        let inkImage = InkRenderer.image(of: PKDrawing(strokes: strokes), in: bounds, scale: max(scale, 1))
        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { ctx in
            let cg = ctx.cgContext
            for ref in sel.elements {
                guard let pi = state.pages.firstIndex(where: { $0.id == ref.pageID }),
                      let el = state.pages[pi].elements.first(where: { $0.id == ref.elementID }) else { continue }
                let origin = layout.pageFrames[pi].origin
                var docEl = el
                docEl.frame = el.frame.offsetBy(dx: origin.x - bounds.minX, dy: origin.y - bounds.minY)
                PageRenderer.drawElement(docEl, assets: document.assets, in: cg, imageMaxPixels: 2000)
            }
            inkImage?.draw(in: CGRect(origin: .zero, size: bounds.size))
        }
    }

    // MARK: - Selection actions

    func deleteSelection() {
        guard let selection else { return }
        let indices = Set(selection.strokeIndices)
        let refs = Set(selection.elements)
        clearSelection()
        perform("Delete") { state in
            state.drawing = PKDrawing(strokes: state.drawing.strokes.enumerated().filter { !indices.contains($0.offset) }.map(\.element))
            for pi in state.pages.indices {
                let pid = state.pages[pi].id
                state.pages[pi].elements.removeAll { refs.contains(ElementRef(pageID: pid, elementID: $0.id)) }
            }
        }
    }

    func copySelection() {
        guard let selection else { return }
        let state = currentState
        let image = renderSelectionImage(selection, state: state, scale: 3)
        Clipboard.write(selection: selection, state: state, layout: layout, assets: document.assets, image: image)
        Haptics.tap()
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    func duplicateSelection() {
        guard let selection else { return }
        let offset = CGAffineTransform(translationX: 24, y: 24)
        var newStrokeIndices: [Int] = []
        var newRefs: [ElementRef] = []
        perform("Duplicate") { state in
            var strokes = state.drawing.strokes
            for i in selection.strokeIndices where i < strokes.count {
                var s = strokes[i]
                s.transform = s.transform.concatenating(offset)
                newStrokeIndices.append(strokes.count)
                strokes.append(s)
            }
            state.drawing = PKDrawing(strokes: strokes)
            for ref in selection.elements {
                guard let pi = state.pages.firstIndex(where: { $0.id == ref.pageID }),
                      var el = state.pages[pi].elements.first(where: { $0.id == ref.elementID }) else { continue }
                el.id = UUID()
                el.frame = el.frame.offsetBy(dx: 24, dy: 24)
                state.pages[pi].elements.append(el)
                newRefs.append(ElementRef(pageID: ref.pageID, elementID: el.id))
            }
        }
        setSelection(strokes: newStrokeIndices, elements: newRefs)
    }

    func recolorSelection(_ color: RGBA) {
        guard var selection else { return }
        perform("Change color") { state in
            var strokes = state.drawing.strokes
            for i in selection.strokeIndices where i < strokes.count {
                let s = strokes[i]
                var c = UIColor(color)
                if s.ink.inkType == .marker { c = c.withAlphaComponent(1) }
                strokes[i] = PKStroke(ink: PKInk(s.ink.inkType, color: c), path: s.path, transform: s.transform, mask: s.mask)
            }
            state.drawing = PKDrawing(strokes: strokes)
            for ref in selection.elements {
                guard let pi = state.pages.firstIndex(where: { $0.id == ref.pageID }),
                      let ei = state.pages[pi].elements.firstIndex(where: { $0.id == ref.elementID }),
                      var text = state.pages[pi].elements[ei].textContent else { continue }
                for r in text.runs.indices { text.runs[r].color = color }
                state.pages[pi].elements[ei].content = .text(text)
            }
        }
        selection.bounds = selectionBounds(selection)
        self.selection = selection
        layoutSelectionView()
    }

    func reorderSelectedElements(toFront: Bool) {
        guard let selection, !selection.elements.isEmpty else { return }
        let refs = Set(selection.elements)
        perform(toFront ? "Bring to front" : "Send to back") { state in
            for pi in state.pages.indices {
                let pid = state.pages[pi].id
                let moving = state.pages[pi].elements.filter { refs.contains(ElementRef(pageID: pid, elementID: $0.id)) }
                guard !moving.isEmpty else { continue }
                state.pages[pi].elements.removeAll { refs.contains(ElementRef(pageID: pid, elementID: $0.id)) }
                if toFront {
                    state.pages[pi].elements.append(contentsOf: moving)
                } else {
                    state.pages[pi].elements.insert(contentsOf: moving, at: 0)
                }
            }
        }
    }

    /// Image of the selection for sharing.
    func selectionImageForSharing() -> UIImage? {
        guard let selection else { return nil }
        return renderSelectionImage(selection, state: currentState, scale: 3)
    }

    /// Ink-only image (white background) for handwriting recognition.
    func selectionInkImageForRecognition() -> (UIImage, CGRect)? {
        guard let selection, !selection.strokeIndices.isEmpty else { return nil }
        let strokes = selection.strokeIndices.compactMap { baseline.strokes.indices.contains($0) ? baseline.strokes[$0] : nil }
        let drawing = PKDrawing(strokes: strokes.map { s in
            PKStroke(ink: PKInk(s.ink.inkType == .marker ? .pen : s.ink.inkType, color: .black), path: s.path, transform: s.transform, mask: s.mask)
        })
        let bounds = drawing.bounds.insetBy(dx: -12, dy: -12)
        guard let ink = InkRenderer.image(of: drawing, in: bounds, scale: 2) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: bounds.size))
            ink.draw(in: CGRect(origin: .zero, size: bounds.size))
        }
        return (image, selection.bounds)
    }

    /// Replaces the selected ink with a text box containing `text`.
    func replaceSelectionWithText(_ text: String) {
        guard let selection, let pageIndex = layout.pageIndex(forY: selection.bounds.midY) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let indices = Set(selection.strokeIndices)
        let lines = max(1, trimmed.components(separatedBy: "\n").count)
        let size = min(max(Double(selection.bounds.height) / Double(lines) * 0.62, 11), 48)
        let pageFrame = layout.pageFrames[pageIndex]
        let color = selection.strokeIndices.first.flatMap { baseline.strokes.indices.contains($0) ? baseline.strokes[$0].ink.color.rgba : nil } ?? .black
        let content = TextContent(runs: [TextRun(text: trimmed, family: .system, size: size, color: color.withAlpha(1))])
        var frame = selection.bounds.offsetBy(dx: -pageFrame.minX, dy: -pageFrame.minY)
        frame.size.width = max(frame.width + 24, 120)
        frame.size.height = TextStyling.measuredHeight(content, width: frame.width)
        let element = PageElement(frame: frame, content: .text(content))
        let pageID = document.pages[pageIndex].id
        clearSelection()
        perform("Convert to text") { state in
            state.drawing = PKDrawing(strokes: state.drawing.strokes.enumerated().filter { !indices.contains($0.offset) }.map(\.element))
            if let pi = state.pages.firstIndex(where: { $0.id == pageID }) { state.pages[pi].elements.append(element) }
        }
        setSelection(strokes: [], elements: [ElementRef(pageID: pageID, elementID: element.id)])
    }

    func saveSelectionAsElement() {
        guard let selection else { return }
        let state = currentState
        let payload = Clipboard.payload(selection: selection, state: state, layout: layout, assets: document.assets)
        let preview = renderSelectionImage(selection, state: state, scale: 2)
        do {
            try ElementsLibrary.shared.add(payload: payload, preview: preview)
            editor?.showToast("Saved to Elements")
            Haptics.success()
        } catch {
            editor?.showError("Couldn't save the element: \(error.localizedDescription)")
        }
    }

    func selectionMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copySelection() },
            UIAction(title: "Cut", image: UIImage(systemName: "scissors")) { [weak self] _ in self?.cutSelection() },
            UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.duplicateSelection() },
            UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.deleteSelection() },
        ])
    }

    // MARK: - Paste

    /// Pastes clipboard content centered on a document point (or the visible page).
    func paste(at docPoint: CGPoint?, payload: Clipboard.Payload? = nil) {
        let target = docPoint ?? CGPoint(x: visibleDocRect.midX, y: visibleDocRect.midY)
        let pageIndex = layout.pageIndex(forY: target.y) ?? currentPageIndex
        guard pageIndex < document.pages.count else { return }
        let pageFrame = layout.pageFrames[pageIndex]
        let pageID = document.pages[pageIndex].id
        Task {
            let clipContent: Clipboard.Content?
            if let payload {
                clipContent = await Clipboard.content(from: payload, into: document)
            } else {
                clipContent = await Clipboard.read(into: document)
            }
            guard let clip = clipContent else {
                editor?.showToast("Nothing to paste")
                return
            }
            // Center the content on the target, kept inside the page.
            var originX = target.x - clip.size.width / 2
            var originY = target.y - clip.size.height / 2
            originX = min(max(originX, pageFrame.minX), max(pageFrame.minX, pageFrame.maxX - clip.size.width))
            originY = min(max(originY, pageFrame.minY), max(pageFrame.minY, pageFrame.maxY - clip.size.height))
            let t = CGAffineTransform(translationX: originX, y: originY)
            var newIndices: [Int] = []
            var refs: [ElementRef] = []
            perform(payload == nil ? "Paste" : "Insert element") { state in
                var strokes = state.drawing.strokes
                for var s in clip.strokes {
                    s.transform = s.transform.concatenating(t)
                    newIndices.append(strokes.count)
                    strokes.append(s)
                }
                state.drawing = PKDrawing(strokes: strokes)
                guard let pi = state.pages.firstIndex(where: { $0.id == pageID }) else { return }
                for var el in clip.elements {
                    el.id = UUID()
                    el.frame = el.frame.offsetBy(dx: originX - pageFrame.minX, dy: originY - pageFrame.minY)
                    state.pages[pi].elements.append(el)
                    refs.append(ElementRef(pageID: pageID, elementID: el.id))
                }
            }
            if currentTool != .lasso { editor?.selectTool(.lasso) }
            setSelection(strokes: newIndices, elements: refs)
        }
    }
}

extension DragSession {
    var kindName: String {
        switch kind {
        case .move: "Move"
        case .resize: "Resize"
        }
    }
}

// MARK: - Selection view

/// Dashed frame with corner handles and an action bar.
final class SelectionView: UIView, UIGestureRecognizerDelegate {
    private weak var controller: CanvasController?
    private let border = CAShapeLayer()
    private let halo = CAShapeLayer()
    private var handles: [UIView] = []
    private let bar = SelectionBar()
    private var contentRect: CGRect = .zero
    private let handleSize: CGFloat = 22
    private let pad: CGFloat = 14

    init(controller: CanvasController) {
        self.controller = controller
        super.init(frame: .zero)
        backgroundColor = .clear
        halo.fillColor = nil
        halo.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        halo.lineWidth = 3.5
        halo.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer.addSublayer(halo)
        border.fillColor = Theme.canvasAccentUI.withAlphaComponent(0.05).cgColor
        border.strokeColor = Theme.canvasAccentUI.cgColor
        border.lineWidth = 1.5
        border.lineDashPattern = [6, 4]
        border.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        layer.addSublayer(border)

        let movePan = UIPanGestureRecognizer(target: self, action: #selector(handleMove(_:)))
        movePan.maximumNumberOfTouches = 1
        movePan.delegate = self
        addGestureRecognizer(movePan)

        for i in 0 ..< 4 {
            let h = UIView(frame: CGRect(x: 0, y: 0, width: handleSize, height: handleSize))
            let dot = UIView(frame: CGRect(x: 4, y: 4, width: handleSize - 8, height: handleSize - 8))
            dot.backgroundColor = .white
            dot.layer.cornerRadius = (handleSize - 8) / 2
            dot.layer.borderColor = Theme.canvasAccentUI.cgColor
            dot.layer.borderWidth = 2
            dot.isUserInteractionEnabled = false
            h.addSubview(dot)
            h.tag = i
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            h.addGestureRecognizer(pan)
            h.accessibilityLabel = "Resize handle"
            addSubview(h)
            handles.append(h)
        }
        bar.controller = controller
        bar.addGestureRecognizer(PencilShield(drawingRecognizer: controller.canvas.drawingGestureRecognizer))
        addSubview(bar)

    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(selection: CanvasSelection) {
        bar.configure(selection: selection)
    }

    func flashBar() {
        bar.alpha = 0.3
        UIView.animate(withDuration: 0.2) { self.bar.alpha = 1 }
    }

    /// `rect` is the selection in overlay (content) coordinates.
    func layout(contentRect rect: CGRect, visible: CGRect) {
        contentRect = rect
        frame = rect.insetBy(dx: -pad, dy: -pad)
        let local = CGRect(x: pad, y: pad, width: rect.width, height: rect.height)
        border.frame = bounds
        border.path = CGPath(rect: local, transform: nil)
        halo.frame = bounds
        halo.path = CGPath(rect: local, transform: nil)
        let corners = [CGPoint(x: local.minX, y: local.minY), CGPoint(x: local.maxX, y: local.minY),
                       CGPoint(x: local.maxX, y: local.maxY), CGPoint(x: local.minX, y: local.maxY)]
        for (i, h) in handles.enumerated() { h.center = corners[i] }
        // Action bar above the selection, or below if there is no room.
        bar.sizeToFit()
        let barSize = bar.bounds.size
        var barY = local.minY - barSize.height - 14
        let globalTop = frame.minY + barY
        if globalTop < visible.minY + 8 { barY = local.maxY + 18 }
        if frame.minY + barY + barSize.height > visible.maxY - 8 { barY = max(local.minY + 8, visible.minY - frame.minY + 8) }
        var barX = local.midX - barSize.width / 2
        let globalX = frame.minX + barX
        if globalX < visible.minX + 8 { barX += visible.minX + 8 - globalX }
        if frame.minX + barX + barSize.width > visible.maxX - 8 { barX -= frame.minX + barX + barSize.width - (visible.maxX - 8) }
        bar.frame = CGRect(x: barX, y: barY, width: barSize.width, height: barSize.height)
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        if bar.frame.contains(point) { return true }
        for h in handles where h.frame.insetBy(dx: -8, dy: -8).contains(point) { return true }
        return bounds.insetBy(dx: pad - 4, dy: pad - 4).contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if bar.frame.contains(point) { return bar.hitTest(convert(point, to: bar), with: event) }
        for h in handles where h.frame.insetBy(dx: -8, dy: -8).contains(point) { return h }
        return super.hitTest(point, with: event)
    }

    /// Dragging the selection must not scroll or draw on the page underneath.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        guard let canvas = controller?.canvas else { return false }
        return other === canvas.panGestureRecognizer || other === canvas.drawingGestureRecognizer
    }

    @objc private func handleMove(_ g: UIPanGestureRecognizer) {
        guard let controller else { return }
        switch g.state {
        case .began: controller.beginDrag(.move)
        case .changed: controller.updateDrag(translation: g.translation(in: superview))
        case .ended: controller.endDrag()
        default: controller.cancelDrag()
        }
    }

    @objc private func handleResize(_ g: UIPanGestureRecognizer) {
        guard let controller, let tag = g.view?.tag else { return }
        switch g.state {
        case .began: controller.beginDrag(.resize(corner: tag))
        case .changed: controller.updateDrag(translation: g.translation(in: superview))
        case .ended: controller.endDrag()
        default: controller.cancelDrag()
        }
    }
}

/// The floating pill of selection actions.
final class SelectionBar: UIView {
    weak var controller: CanvasController?
    private let stack = UIStackView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 22
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)
        blur.layer.cornerRadius = 22
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        addSubview(blur)
        stack.axis = .horizontal
        stack.spacing = 2
        stack.alignment = .center
        addSubview(stack)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(selection: CanvasSelection) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let hasInk = !selection.strokeIndices.isEmpty
        let hasElements = !selection.elements.isEmpty
        let isSingleText = selection.strokeIndices.isEmpty && selection.elements.count == 1
            && controller?.element(selection.elements[0])?.isText == true

        if isSingleText {
            stack.addArrangedSubview(button("character.cursor.ibeam", "Edit text") { c in
                guard let ref = c.selection?.elements.first else { return }
                c.beginEditingText(pageID: ref.pageID, elementID: ref.elementID)
            })
        }
        stack.addArrangedSubview(button("doc.on.doc", "Copy") { $0.copySelection() })
        stack.addArrangedSubview(button("scissors", "Cut") { $0.cutSelection() })
        stack.addArrangedSubview(button("plus.square.on.square", "Duplicate") { $0.duplicateSelection() })
        if hasInk || isSingleText {
            stack.addArrangedSubview(colorButton())
        }
        if hasInk {
            stack.addArrangedSubview(button("character.textbox", "Convert to text") { $0.editor?.convertSelectionToText() })
        }
        var more: [UIMenuElement] = [
            UIAction(title: "Share as image", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                self?.controller?.editor?.shareSelectionImage()
            },
            UIAction(title: "Save to Elements", image: UIImage(systemName: "star.square.on.square")) { [weak self] _ in
                self?.controller?.saveSelectionAsElement()
            },
        ]
        if hasElements {
            more.append(UIAction(title: "Bring to front", image: UIImage(systemName: "square.3.layers.3d.top.filled")) { [weak self] _ in
                self?.controller?.reorderSelectedElements(toFront: true)
            })
            more.append(UIAction(title: "Send to back", image: UIImage(systemName: "square.3.layers.3d.bottom.filled")) { [weak self] _ in
                self?.controller?.reorderSelectedElements(toFront: false)
            })
        }
        let moreButton = UIButton(type: .system)
        moreButton.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
        moreButton.menu = UIMenu(children: more)
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.accessibilityLabel = "More"
        style(moreButton)
        stack.addArrangedSubview(moreButton)
        let delete = button("trash", "Delete") { $0.deleteSelection() }
        delete.tintColor = Theme.recordUI
        stack.addArrangedSubview(delete)
        setNeedsLayout()
    }

    private func style(_ b: UIButton) {
        b.tintColor = Theme.inkUI
        b.widthAnchor.constraint(equalToConstant: 42).isActive = true
        b.heightAnchor.constraint(equalToConstant: 42).isActive = true
        b.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 16, weight: .medium), forImageIn: .normal)
    }

    private func button(_ symbol: String, _ label: String, action: @escaping (CanvasController) -> Void) -> UIButton {
        let b = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in
            guard let c = self?.controller else { return }
            action(c)
        })
        b.setImage(UIImage(systemName: symbol), for: .normal)
        b.accessibilityLabel = label
        b.largeContentTitle = label
        style(b)
        return b
    }

    private func colorButton() -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: "paintpalette"), for: .normal)
        b.accessibilityLabel = "Color"
        let actions = RGBA.inkPalette.map { color in
            UIAction(title: color.hex, image: Self.swatch(color)) { [weak self] _ in
                self?.controller?.recolorSelection(color)
            }
        }
        b.menu = UIMenu(title: "Color", options: .displayInline, children: [UIMenu(options: .displayInline, preferredElementSize: .small, children: actions)])
        b.showsMenuAsPrimaryAction = true
        style(b)
        return b
    }

    static func swatch(_ color: RGBA) -> UIImage {
        let size = CGSize(width: 22, height: 22)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            UIColor(color).setFill()
            UIBezierPath(ovalIn: r).fill()
            UIColor.black.withAlphaComponent(0.15).setStroke()
            UIBezierPath(ovalIn: r).stroke()
        }.withRenderingMode(.alwaysOriginal)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let fit = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return CGSize(width: fit.width + 16, height: 46)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        blur.frame = bounds
        stack.frame = bounds.insetBy(dx: 8, dy: 2)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 22).cgPath
    }
}
