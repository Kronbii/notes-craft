import NotesCraftCore
import PencilKit
import UIKit

extension CanvasController: UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    func setUpGestures() {
        twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap))
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        twoFingerTap.delegate = self
        canvas.addGestureRecognizer(twoFingerTap)

        threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap))
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        threeFingerTap.delegate = self
        canvas.addGestureRecognizer(threeFingerTap)
        twoFingerTap.require(toFail: threeFingerTap)

        fingerTap = UITapGestureRecognizer(target: self, action: #selector(handleFingerTap(_:)))
        fingerTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        fingerTap.delegate = self
        canvas.addGestureRecognizer(fingerTap)
        fingerTap.require(toFail: twoFingerTap)

        toolTap = UITapGestureRecognizer(target: self, action: #selector(handleToolTap(_:)))
        toolTap.delegate = self
        canvas.addGestureRecognizer(toolTap)

        toolPan = UIPanGestureRecognizer(target: self, action: #selector(handleToolPan(_:)))
        toolPan.maximumNumberOfTouches = 1
        toolPan.delegate = self
        canvas.addGestureRecognizer(toolPan)
        toolPan.isEnabled = false

        longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        longPress.minimumPressDuration = 0.5
        longPress.delegate = self
        canvas.addGestureRecognizer(longPress)

        touchObserver.delegate = self
        touchObserver.onHold = { [weak self] points in self?.handleHold(points) }
        touchObserver.onHoldCancelled = { [weak self] in self?.clearSnapPreview() }
        canvas.addGestureRecognizer(touchObserver)

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        canvas.addInteraction(pencil)
        pencilInteraction = pencil

        let menu = UIEditMenuInteraction(delegate: self)
        canvas.addInteraction(menu)
        editMenu = menu
    }

    /// Touches on floating controls (buttons, the selection, the text editor)
    /// belong to those controls, not to the canvas gestures.
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if g === touchObserver { return true }
        if (g === twoFingerTap || g === threeFingerTap), g.numberOfTouches == 0 {
            tapStart = (zoom, canvas.contentOffset)
        }
        if let view = touch.view, view !== canvas.overlay, view.isDescendant(of: canvas.overlay) {
            return false
        }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        if g === touchObserver || other === touchObserver { return true }
        if g === twoFingerTap || g === threeFingerTap { return true }
        return false
    }

    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === fingerTap {
            // In finger-drawing mode, finger taps belong to the pen.
            return !AppSettings.shared.drawWithFinger || !currentTool.usesCanvasDrawing
        }
        if g === twoFingerTap || g === threeFingerTap {
            // Never while zooming or scrolling: two fingers there mean a pinch.
            guard !canvas.isZooming, !canvas.isZoomBouncing, !canvas.isDragging, zoomAnimation == nil else { return false }
            return AppSettings.shared.tapGesturesUndo
        }
        if g === longPress {
            return replayTime == nil
        }
        if g === toolPan, let view = selectionView {
            // Dragging a selection is handled by the selection itself.
            let p = g.location(in: view)
            if view.point(inside: p, with: nil) { return false }
        }
        return true
    }

    // MARK: Taps

    /// A pinch or scroll that starts with two fingers is not a tap: taps wait for
    /// the scroll view's pinch and pan to fail. (The pinch recognizer only exists
    /// once zooming is enabled, so this runs when zoom limits are set.)
    func linkTapsToScrollGestures() {
        guard !tapsWaitForPinch, let pinch = canvas.pinchGestureRecognizer, twoFingerTap != nil, threeFingerTap != nil else { return }
        tapsWaitForPinch = true
        for tap in [twoFingerTap!, threeFingerTap!] {
            tap.require(toFail: pinch)
            tap.require(toFail: canvas.panGestureRecognizer)
        }
    }

    /// Whether the view moved since the tap's fingers came down (then it was a pinch).
    private func viewMovedDuringTap() -> Bool {
        guard let start = tapStart else { return false }
        tapStart = nil
        let zoomChange = abs(zoom - start.zoom) / max(start.zoom, 0.0001)
        let dx = canvas.contentOffset.x - start.offset.x, dy = canvas.contentOffset.y - start.offset.y
        return zoomChange > 0.01 || (dx * dx + dy * dy).squareRoot() > 12
    }

    @objc func handleTwoFingerTap() {
        if viewMovedDuringTap() {
            log.notice("NCGESTURE two-finger tap ignored: the view zoomed or moved")
            return
        }
        // With finger drawing on, the first finger may have started a stroke:
        // cancel it, and undo once PencilKit has let go of it.
        historyWillChange(fromTouch: true)
        DispatchQueue.main.async { [weak self] in
            guard let editor = self?.editor else { return }
            let typing = editor.isEditingText && (editor.canvas.textEditor?.undoManager?.canUndo ?? false)
            let possible = typing || editor.undoManager.canUndo
            let name = typing ? "Typing" : editor.undoManager.undoActionName
            editor.undo()
            // An undo by gesture is easy to trigger without noticing: say what it did.
            editor.showToast(possible ? "Undo · \(name.isEmpty ? "Change" : name)" : "Nothing to undo")
            log.notice("NCGESTURE two-finger undo (\(possible ? name : "nothing", privacy: .public))")
        }
    }

    @objc func handleThreeFingerTap() {
        if viewMovedDuringTap() { return }
        historyWillChange(fromTouch: true)
        DispatchQueue.main.async { [weak self] in
            guard let editor = self?.editor else { return }
            let typing = editor.isEditingText && (editor.canvas.textEditor?.undoManager?.canRedo ?? false)
            let possible = typing || editor.undoManager.canRedo
            let name = typing ? "Typing" : editor.undoManager.redoActionName
            editor.redo()
            editor.showToast(possible ? "Redo · \(name.isEmpty ? "Change" : name)" : "Nothing to redo")
            log.notice("NCGESTURE three-finger redo (\(possible ? name : "nothing", privacy: .public))")
        }
    }

    /// Finger tap: select elements, finish editing, or jump in replay.
    @objc func handleFingerTap(_ g: UITapGestureRecognizer) {
        let p = docPoint(g)
        if replayTime != nil {
            replayTap(at: p)
            return
        }
        if textEditor != nil {
            endTextEditing()
            return
        }
        if let selection, selection.bounds.insetBy(dx: -8 / zoom, dy: -8 / zoom).contains(p) { return }
        if currentTool == .text {
            handleTextTap(at: p)
            return
        }
        if let hit = elementHit(at: p) {
            if currentTool == .lasso || !AppSettings.shared.drawWithFinger {
                if let content = hit.element.textContent, selection?.isSingleElement(hit.element.id) == true {
                    _ = content
                    beginEditingText(pageID: hit.pageID, elementID: hit.element.id)
                } else {
                    selectElement(hit.element.id, pageID: hit.pageID)
                }
                return
            }
        }
        if selection != nil { clearSelection() }
        editor?.canvasTappedEmpty()
    }

    /// Pen (or finger in finger-drawing mode) tap with the text, lasso or replay tool.
    @objc func handleToolTap(_ g: UITapGestureRecognizer) {
        let p = docPoint(g)
        if replayTime != nil {
            replayTap(at: p)
            return
        }
        switch currentTool {
        case .text:
            handleTextTap(at: p)
        case .lasso:
            if let selection, selection.bounds.contains(p) { return }
            if let hit = elementHit(at: p) {
                selectElement(hit.element.id, pageID: hit.pageID)
            } else if let index = strokeHit(at: p) {
                selectStrokes([index])
            } else {
                clearSelection()
            }
        default:
            break
        }
    }

    func handleTextTap(at p: CGPoint) {
        if textEditor != nil {
            endTextEditing()
            return
        }
        if let hit = elementHit(at: p), hit.element.isText {
            beginEditingText(pageID: hit.pageID, elementID: hit.element.id)
        } else if let pageIndex = layout.pageIndex(containing: p) {
            createTextBox(at: p, pageIndex: pageIndex)
        }
    }

    // MARK: Pan (lasso and laser)

    @objc func handleToolPan(_ g: UIPanGestureRecognizer) {
        switch currentTool {
        case .lasso: handleLassoPan(g)
        case .laser: handleLaserPan(g)
        default: break
        }
    }

    // MARK: Long press menu

    @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let contentPoint = g.location(in: canvas)
        let p = contentToDoc(contentPoint)
        if let hit = elementHit(at: p) {
            selectElement(hit.element.id, pageID: hit.pageID)
            return
        }
        if let selection, selection.bounds.contains(p) {
            showSelectionMenu()
            return
        }
        pendingMenuPoint = p
        let config = UIEditMenuConfiguration(identifier: "canvas", sourcePoint: g.location(in: canvas))
        editMenu?.presentEditMenu(with: config)
    }

    // MARK: Apple Pencil double tap

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        handlePencilTap(preferred: UIPencilInteraction.preferredTapAction)
    }

    @available(iOS 17.5, *)
    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        handlePencilTap(preferred: UIPencilInteraction.preferredTapAction)
    }

    private func handlePencilTap(preferred: UIPencilPreferredAction) {
        let now = CACurrentMediaTime()
        guard now - lastPencilTapTime > 0.25 else { return }
        lastPencilTapTime = now
        editor?.handlePencilDoubleTap(systemPreference: preferred)
    }

    // MARK: Keyboard

    func observeKeyboard() {
        keyboardObservers.append(NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] note in
            let frame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated {
                self?.keyboardFrameChanged(frame)
            }
        })
        keyboardObservers.append(NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.keyboardFrameChanged(nil)
            }
        })
    }

    private func keyboardFrameChanged(_ frame: CGRect?) {
        var inset: CGFloat = 0
        if let frame, let window = canvas.window {
            let local = canvas.convert(frame, from: window.screen.coordinateSpace)
            inset = max(0, canvas.bounds.maxY - local.minY)
        }
        guard abs(inset - keyboardInset) > 0.5 else { return }
        keyboardInset = inset
        updateInsets()
        if let editorView = textEditor {
            ensureVisible(docRect: editorView.docFrame, animated: true)
        }
    }

    // MARK: Hit testing

    struct ElementHit {
        var pageID: UUID
        var pageIndex: Int
        var element: PageElement
    }

    /// Topmost element under a document point.
    func elementHit(at p: CGPoint) -> ElementHit? {
        guard let i = layout.pageIndex(containing: p) else { return nil }
        let page = document.pages[i]
        let local = CGPoint(x: p.x - layout.pageFrames[i].minX, y: p.y - layout.pageFrames[i].minY)
        let slop = 6 / max(zoom, 0.1)
        for element in page.elements.reversed() where element.frame.insetBy(dx: -slop, dy: -slop).contains(local) {
            return ElementHit(pageID: page.id, pageIndex: i, element: element)
        }
        return nil
    }

    /// Topmost stroke near a document point.
    func strokeHit(at p: CGPoint) -> Int? {
        let slop = 8 / max(zoom, 0.1)
        let strokes = baseline.strokes
        for i in stride(from: strokes.count - 1, through: 0, by: -1) {
            let s = strokes[i]
            guard s.renderBounds.insetBy(dx: -slop, dy: -slop).contains(p) else { continue }
            let inverse = s.transform.inverted()
            let local = p.applying(inverse)
            for point in s.path.interpolatedPoints(by: .distance(4)) {
                let r = max(point.size.width / 2, 2) + slop
                if hypot(point.location.x - local.x, point.location.y - local.y) <= r { return i }
            }
        }
        return nil
    }

    // MARK: Overlays

    func layoutOverlays() {
        let z = zoom
        if let last = layout.pageFrames.last {
            addPageButton.sizeToFit()
            let size = addPageButton.intrinsicContentSize
            let center = CGPoint(x: layout.contentSize.width / 2 * z, y: (last.maxY + 56) * z)
            addPageButton.bounds = CGRect(origin: .zero, size: size)
            addPageButton.center = center
            addPageButton.isHidden = replayTime != nil || isBoard
        }
        layoutSelectionView()
        textEditor?.updateFrame(zoom: z)
        updateHighlightLayer()
        if !lassoPoints.isEmpty { updateLassoLayer() }
    }

    // MARK: Find highlights

    func showHighlights(_ rects: [CGRect], current: CGRect?) {
        highlightRects = rects
        currentHighlightRect = current
        updateHighlightLayer()
    }

    func updateHighlightLayer() {
        let path = CGMutablePath()
        for r in highlightRects where r != currentHighlightRect {
            path.addRoundedRect(in: docToContent(r).insetBy(dx: -2, dy: -1), cornerWidth: 3, cornerHeight: 3)
        }
        highlightLayer.path = path
        if let current = currentHighlightRect {
            currentHighlightLayer.path = CGPath(roundedRect: docToContent(current).insetBy(dx: -3, dy: -2), cornerWidth: 4, cornerHeight: 4, transform: nil)
        } else {
            currentHighlightLayer.path = nil
        }
    }

    // MARK: Shapes

    /// Turns a just-finished stroke into a clean shape when the shape tool is on,
    /// the pen was held at the end of the stroke, or the highlighter should be straight.
    func processNewStroke(_ stroke: PKStroke) -> PKStroke? {
        let held = touchObserver.consumeHold()
        let points = stroke.path.map { $0.location.applying(stroke.transform) }
        guard points.count >= 2 else { return nil }
        switch currentTool {
        case .shape:
            guard let shape = ShapeRecognizer.recognize(points) else { return nil }
            return makeShapeStroke(shape, like: stroke)
        case .pen:
            guard held, AppSettings.shared.holdToSnapShapes, let shape = ShapeRecognizer.recognize(points) else { return nil }
            Haptics.snap()
            return makeShapeStroke(shape, like: stroke)
        case .highlighter:
            if held || AppSettings.shared.straightHighlighter, let (a, b) = ShapeRecognizer.straightened(points) {
                return makeShapeStroke(.line(a, b), like: stroke)
            }
            return nil
        default:
            return nil
        }
    }

    func makeShapeStroke(_ shape: RecognizedShape, like stroke: PKStroke) -> PKStroke {
        let scale = (abs(stroke.transform.a * stroke.transform.d - stroke.transform.b * stroke.transform.c)).squareRoot()
        let sizes = stroke.path.map { $0.size.width * max(scale, 0.01) }.sorted()
        // Point sizes come from the real stroke, so the shape keeps its thickness.
        let width = max(sizes.isEmpty ? 2 : sizes[sizes.count / 2], 0.5)
        let heights = stroke.path.map { $0.size.height * max(scale, 0.01) }.sorted()
        let height = max(heights.isEmpty ? width : heights[heights.count / 2], 0.5)
        let outline = shape.outline(spacing: max(1.5, width * 0.6))
        let sample = stroke.path.first
        var points: [PKStrokePoint] = []
        points.reserveCapacity(outline.count)
        for (i, p) in outline.enumerated() {
            points.append(PKStrokePoint(
                location: p,
                timeOffset: TimeInterval(i) * 0.004,
                size: CGSize(width: width, height: height),
                opacity: sample?.opacity ?? 1,
                force: sample?.force ?? 1,
                azimuth: sample?.azimuth ?? 0,
                altitude: sample?.altitude ?? .pi / 2
            ))
        }
        let path = PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate)
        return PKStroke(ink: stroke.ink, path: path, transform: .identity, mask: nil)
    }

    /// While the pen rests, preview the shape it will snap to.
    func handleHold(_ contentPoints: [CGPoint]) {
        guard (currentTool == .pen && AppSettings.shared.holdToSnapShapes) || currentTool == .highlighter else { return }
        let points = contentPoints.map(contentToDoc)
        let shape: RecognizedShape?
        if currentTool == .highlighter {
            shape = ShapeRecognizer.straightened(points).map { RecognizedShape.line($0.0, $0.1) }
        } else {
            shape = ShapeRecognizer.recognize(points)
        }
        guard let shape else { return }
        Haptics.tap()
        let path = CGMutablePath()
        let outline = shape.outline(spacing: 4).map(docToContent)
        if let first = outline.first {
            path.move(to: first)
            for p in outline.dropFirst() { path.addLine(to: p) }
        }
        snapPreviewLayer.path = path
        snapPreviewLayer.opacity = 1
    }

    func clearSnapPreview() {
        snapPreviewLayer.path = nil
    }

    // MARK: Laser pointer

    func handleLaserPan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: canvas.overlay)
        let now = CACurrentMediaTime()
        switch g.state {
        case .began:
            laserFadeTimer?.invalidate()
            laserLayer.opacity = 1
            laserGlowLayer.opacity = 0.35
            laserPoints = [(p, now)]
        case .changed:
            laserPoints.append((p, now))
            laserPoints.removeAll { now - $0.1 > 0.9 }
        default:
            fadeLaser()
            return
        }
        let path = CGMutablePath()
        if let first = laserPoints.first {
            path.move(to: first.0)
            for (pt, _) in laserPoints.dropFirst() { path.addLine(to: pt) }
            if laserPoints.count == 1 { path.addLine(to: CGPoint(x: first.0.x + 0.1, y: first.0.y)) }
        }
        laserLayer.path = path
        laserGlowLayer.path = path
    }

    private func fadeLaser() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.6
        laserLayer.add(fade, forKey: "fade")
        laserGlowLayer.add(fade, forKey: "fade")
        laserLayer.opacity = 0
        laserGlowLayer.opacity = 0
        laserFadeTimer?.invalidate()
        laserFadeTimer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.laserLayer.path = nil
                self?.laserGlowLayer.path = nil
                self?.laserPoints.removeAll()
            }
        }
    }
}

// MARK: - Edit menu (paste, add text)

extension CanvasController: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        if configuration.identifier as? String == "selection" {
            return selectionMenu()
        }
        guard let point = pendingMenuPoint else { return nil }
        var items: [UIMenuElement] = []
        if Clipboard.hasContent {
            items.append(UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.paste(at: point)
            })
        }
        if layout.pageIndex(containing: point) != nil {
            items.append(UIAction(title: "Add text", image: UIImage(systemName: "textformat")) { [weak self] _ in
                guard let self, let i = self.layout.pageIndex(containing: point) else { return }
                self.createTextBox(at: point, pageIndex: i)
            })
        }
        return items.isEmpty ? nil : UIMenu(children: items)
    }
}

// MARK: - Scribble to erase

extension CanvasController {
    /// If `stroke` scribbles out ink (or a text box or image), the state with
    /// all of it removed. Nil when the stroke is ordinary writing.
    func scribbleErase(_ stroke: PKStroke, over baseline: PKDrawing) -> CanvasState? {
        guard AppSettings.shared.scribbleToErase else { return nil }
        let points = stroke.path.map { $0.location.applying(stroke.transform) }
        let duration = stroke.path.count > 1 ? stroke.path[stroke.path.count - 1].timeOffset : nil
        guard ScribbleDetector.isScribble(points, duration: duration, viewScale: Double(zoom)) else { return nil }
        let hull = ScribbleDetector.expanded(ScribbleDetector.convexHull(points), by: 3)
        let hullBox = ShapeRecognizer.boundingBox(hull)

        var erased: [PKStroke] = []
        var kept: [PKStroke] = []
        kept.reserveCapacity(baseline.strokes.count)
        for s in baseline.strokes {
            if s.renderBounds.intersects(hullBox), Self.coverage(of: s, by: hull) >= 0.5 {
                erased.append(s)
            } else {
                kept.append(s)
            }
        }

        var pages = document.pages
        var removedElements = 0
        for (pi, frame) in layout.pageFrames.enumerated() where pi < pages.count && frame.intersects(hullBox) {
            let before = pages[pi].elements.count
            pages[pi].elements.removeAll { element in
                let docFrame = element.frame.offsetBy(dx: frame.minX, dy: frame.minY)
                guard docFrame.intersects(hullBox) else { return false }
                return Self.coverage(of: docFrame, by: hull) >= 0.6
            }
            removedElements += before - pages[pi].elements.count
        }
        guard !erased.isEmpty || removedElements > 0 else { return nil }
        _ = touchObserver.consumeHold()
        log.notice("NCSCRIBBLE erased \(erased.count) strokes and \(removedElements) items")
        fadeOut(erased + [stroke])
        return CanvasState(pages: pages, drawing: PKDrawing(strokes: kept), origin: boardOrigin)
    }

    /// Share of a stroke's points inside the polygon.
    static func coverage(of stroke: PKStroke, by hull: [CGPoint]) -> Double {
        var inside = 0
        var total = 0
        let step = max(1, stroke.path.count / 40)
        var i = 0
        for p in stroke.path {
            defer { i += 1 }
            guard i % step == 0 else { continue }
            total += 1
            if ScribbleDetector.contains(hull, p.location.applying(stroke.transform)) { inside += 1 }
        }
        return total == 0 ? 0 : Double(inside) / Double(total)
    }

    /// Share of a rectangle inside the polygon (sampled on a grid).
    static func coverage(of rect: CGRect, by hull: [CGPoint]) -> Double {
        var inside = 0
        let n = 6
        for yi in 0 ..< n {
            for xi in 0 ..< n {
                let p = CGPoint(x: rect.minX + rect.width * (CGFloat(xi) + 0.5) / CGFloat(n),
                                y: rect.minY + rect.height * (CGFloat(yi) + 0.5) / CGFloat(n))
                if ScribbleDetector.contains(hull, p) { inside += 1 }
            }
        }
        return Double(inside) / Double(n * n)
    }

    /// Briefly shows strokes that were just removed, fading away.
    func fadeOut(_ strokes: [PKStroke]) {
        guard !strokes.isEmpty else { return }
        let drawing = PKDrawing(strokes: strokes)
        let docRect = drawing.bounds.insetBy(dx: -4, dy: -4)
        guard docRect.width > 0, docRect.height > 0 else { return }
        let screenScale = canvas.window?.screen.scale ?? 2
        let scale = min(zoom * screenScale, 2048 / max(docRect.width, docRect.height))
        var image = UIImage()
        // The ink canvas is always light; render the same colors.
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: docRect, scale: scale)
        }
        let view = UIImageView(image: image)
        view.frame = docToContent(docRect)
        view.isUserInteractionEnabled = false
        canvas.overlay.insertSubview(view, at: 0)
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut]) {
            view.alpha = 0
            view.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
        } completion: { _ in
            view.removeFromSuperview()
        }
    }
}
