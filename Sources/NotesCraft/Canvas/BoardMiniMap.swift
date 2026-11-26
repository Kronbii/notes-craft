import NotesCraftCore
import PencilKit
import UIKit

/// The whiteboard minimap (bottom left, like GoodNotes): an overview of what is
/// on the board with the visible area marked. Tap or drag on it to move there;
/// below it, the zoom level (tap for 100%) and a button that brings you back to
/// your writing.
final class BoardMiniMapView: UIView {
    weak var controller: CanvasController?

    static let mapSize = CGSize(width: 156, height: 98)
    static let barHeight: CGFloat = 42

    private let mapView = UIView()
    private let contentLayer = CALayer()
    /// Shown instead when the content is too small on the map to see.
    private let contentMarker = CAShapeLayer()
    private let viewportLayer = CAShapeLayer()
    private let zoomButton = UIButton(type: .system)
    private let fitButton = UIButton(type: .system)
    private let divider = UIView()

    /// Document rect the content image shows.
    private var contentRect: CGRect?
    /// Document rect mapped onto the map; fixed while dragging so the map holds still.
    private var world = CGRect.zero
    private var dragging = false
    private var renderWork: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.17, green: 0.18, blue: 0.18, alpha: 0.94)
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 3)

        mapView.backgroundColor = UIColor(red: 0.27, green: 0.29, blue: 0.28, alpha: 1)
        mapView.layer.cornerRadius = 12
        mapView.layer.cornerCurve = .continuous
        mapView.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        mapView.clipsToBounds = true
        addSubview(mapView)
        contentLayer.contentsGravity = .resize
        contentLayer.minificationFilter = .trilinear
        mapView.layer.addSublayer(contentLayer)
        contentMarker.fillColor = UIColor.white.withAlphaComponent(0.9).cgColor
        contentMarker.strokeColor = UIColor(red: 0.62, green: 0.78, blue: 0.90, alpha: 0.9).cgColor
        contentMarker.lineWidth = 1
        contentMarker.actions = ["path": NSNull()]
        mapView.layer.addSublayer(contentMarker)
        viewportLayer.fillColor = UIColor(red: 0.55, green: 0.71, blue: 0.84, alpha: 0.30).cgColor
        viewportLayer.strokeColor = UIColor(red: 0.62, green: 0.78, blue: 0.90, alpha: 0.95).cgColor
        viewportLayer.lineWidth = 1.5
        viewportLayer.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull()]
        mapView.layer.addSublayer(viewportLayer)

        divider.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        addSubview(divider)

        var zoomConfig = UIButton.Configuration.plain()
        zoomConfig.baseForegroundColor = UIColor.white.withAlphaComponent(0.86)
        zoomConfig.contentInsets = .zero
        zoomButton.configuration = zoomConfig
        zoomButton.addAction(UIAction { [weak self] _ in self?.controller?.zoomBoardToActualSize() }, for: .primaryActionTriggered)
        addSubview(zoomButton)

        var fitConfig = UIButton.Configuration.plain()
        fitConfig.image = UIImage(systemName: "viewfinder", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
        fitConfig.baseForegroundColor = UIColor.white.withAlphaComponent(0.86)
        fitButton.configuration = fitConfig
        fitButton.accessibilityLabel = "Show everything on the canvas"
        fitButton.addAction(UIAction { [weak self] _ in self?.controller?.fitBoardContent(maxZoom: 1, animated: true) }, for: .primaryActionTriggered)
        addSubview(fitButton)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        mapView.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        mapView.addGestureRecognizer(tap)
        mapView.isAccessibilityElement = true
        mapView.accessibilityLabel = "Canvas overview"
        mapView.accessibilityHint = "Tap or drag to move around the canvas"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.mapSize.width, height: Self.mapSize.height + Self.barHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 18).cgPath
        mapView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.mapSize.height)
        divider.frame = CGRect(x: bounds.width * 0.62, y: Self.mapSize.height + 9, width: 1, height: Self.barHeight - 18)
        zoomButton.frame = CGRect(x: 0, y: Self.mapSize.height, width: bounds.width * 0.62, height: Self.barHeight)
        fitButton.frame = CGRect(x: bounds.width * 0.62, y: Self.mapSize.height, width: bounds.width * 0.38, height: Self.barHeight)
        updateViewport()
    }

    // MARK: Updating

    /// Moves the visible-area box (cheap; called while scrolling and zooming).
    func updateViewport() {
        guard let controller else { return }
        let visible = controller.visibleDocRect
        let zoomText = "\(Int((controller.zoom * 100).rounded()))%"
        if zoomButton.configuration?.title != zoomText {
            var config = zoomButton.configuration
            config?.attributedTitle = AttributedString(zoomText, attributes: AttributeContainer([
                .font: UIFont.monospacedDigitSystemFont(ofSize: 15, weight: .medium),
            ]))
            config?.title = zoomText
            zoomButton.configuration = config
            zoomButton.accessibilityLabel = "Zoom \(zoomText). Tap for 100 percent"
        }
        if !dragging {
            var w = visible
            if let contentRect {
                w = w.union(contentRect)
            }
            world = w.insetBy(dx: -w.width * 0.06, dy: -w.height * 0.06)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let contentRect {
            let r = mapRect(contentRect)
            contentLayer.frame = r
            contentLayer.isHidden = false
            // Far from your writing it shrinks to a speck: mark where it is.
            if max(r.width, r.height) < 8 {
                contentMarker.path = UIBezierPath(ovalIn: CGRect(x: r.midX - 3.5, y: r.midY - 3.5, width: 7, height: 7)).cgPath
                contentMarker.isHidden = false
            } else {
                contentMarker.isHidden = true
            }
        } else {
            contentLayer.isHidden = true
            contentMarker.isHidden = true
        }
        var box = mapRect(visible)
        // Keep the box findable when it is tiny.
        if box.width < 6 { box = box.insetBy(dx: (box.width - 6) / 2, dy: 0) }
        if box.height < 6 { box = box.insetBy(dx: 0, dy: (box.height - 6) / 2) }
        viewportLayer.path = UIBezierPath(roundedRect: box, cornerRadius: min(4, box.width / 3, box.height / 3)).cgPath
        CATransaction.commit()
    }

    /// Re-renders the overview of what is on the board, a moment after it changes.
    func contentChanged() {
        renderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.renderContent() }
        renderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func renderContent() {
        guard let controller else { return }
        guard let rect = controller.boardContentRect?.insetBy(dx: -20, dy: -20) else {
            contentRect = nil
            contentLayer.contents = nil
            updateViewport()
            return
        }
        // Enough pixels for the map even when the content fills it.
        let scale = min(2, 520 / max(rect.width, rect.height, 1))
        let drawing = controller.baseline
        let frames: [CGRect] = {
            guard let page = controller.document.pages.first, let frame = controller.layout.frame(of: 0) else { return [] }
            return page.elements.map { $0.frame.offsetBy(dx: frame.minX, dy: frame.minY) }
        }()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let size = CGSize(width: max(1, rect.width * scale), height: max(1, rect.height * scale))
        var ink: UIImage?
        // Dark appearance turns black ink white, so it shows on the dark map.
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            ink = drawing.image(from: rect, scale: scale)
        }
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.withAlphaComponent(0.55).setFill()
            for f in frames {
                let r = CGRect(x: (f.minX - rect.minX) * scale, y: (f.minY - rect.minY) * scale, width: f.width * scale, height: f.height * scale)
                UIBezierPath(roundedRect: r, cornerRadius: 1.5).fill()
            }
            ink?.draw(in: CGRect(origin: .zero, size: size))
        }
        contentRect = rect
        contentLayer.contents = image.cgImage
        updateViewport()
    }

    // MARK: Mapping

    private var mapScale: CGFloat {
        guard world.width > 0, world.height > 0 else { return 1 }
        return min(mapView.bounds.width / world.width, mapView.bounds.height / world.height)
    }

    private var mapOrigin: CGPoint {
        let m = mapScale
        return CGPoint(x: (mapView.bounds.width - world.width * m) / 2, y: (mapView.bounds.height - world.height * m) / 2)
    }

    private func mapRect(_ doc: CGRect) -> CGRect {
        let m = mapScale, o = mapOrigin
        return CGRect(x: o.x + (doc.minX - world.minX) * m, y: o.y + (doc.minY - world.minY) * m, width: doc.width * m, height: doc.height * m)
    }

    private func docPoint(_ map: CGPoint) -> CGPoint {
        let m = max(mapScale, 0.000001), o = mapOrigin
        return CGPoint(x: world.minX + (map.x - o.x) / m, y: world.minY + (map.y - o.y) / m)
    }

    // MARK: Gestures

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began:
            dragging = true
            controller?.centerBoardView(on: docPoint(g.location(in: mapView)), animated: false)
        case .changed:
            controller?.centerBoardView(on: docPoint(g.location(in: mapView)), animated: false)
        default:
            dragging = false
            controller?.ensureBoardRoom(allowShift: true)
            updateViewport()
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        controller?.centerBoardView(on: docPoint(g.location(in: mapView)), animated: true)
    }
}

extension CanvasController {
    /// Shows the board's minimap (whiteboards only).
    func installMiniMapIfNeeded() {
        guard isBoard, miniMap == nil else { return }
        let map = BoardMiniMapView()
        map.controller = self
        map.translatesAutoresizingMaskIntoConstraints = false
        rootView.addSubview(map)
        let bottom = map.bottomAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        NSLayoutConstraint.activate([
            map.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 16),
            bottom,
            map.widthAnchor.constraint(equalToConstant: BoardMiniMapView.mapSize.width),
            map.heightAnchor.constraint(equalToConstant: BoardMiniMapView.mapSize.height + BoardMiniMapView.barHeight),
        ])
        miniMap = map
        miniMapBottom = bottom
        map.renderContent()
    }

    /// Room to leave below the minimap (the audio player sits there when open).
    func setMiniMapBottomInset(_ inset: CGFloat) {
        miniMapBottom?.constant = -inset
        UIView.animate(withDuration: 0.25) { self.rootView.layoutIfNeeded() }
    }

    /// Moves the view so `doc` is in the middle of the screen, keeping the zoom.
    func centerBoardView(on doc: CGPoint, animated: Bool) {
        let view = CGPoint(x: canvas.bounds.width / 2, y: canvas.bounds.height / 2)
        if animated {
            animateZoom(to: zoom, keeping: doc, at: view, duration: 0.25)
        } else {
            setZoom(zoom, keeping: doc, at: view)
        }
    }

    /// 100%, keeping the middle of the screen in place.
    func zoomBoardToActualSize() {
        let view = CGPoint(x: canvas.bounds.width / 2, y: canvas.bounds.height / 2)
        let doc = contentToDoc(CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY))
        animateZoom(to: 1, keeping: doc, at: view, duration: 0.25)
    }
}
