import NotesCraftCore
import PencilKit
import UIKit

/// PKCanvasView with extra layers: page backgrounds below the ink, a desk mask
/// above it (so ink never shows outside the pages), and an interactive overlay.
final class NotebookCanvasView: PKCanvasView {
    let pageContainer = UIView()
    let deskMask = DeskMaskView()
    let overlay = CanvasOverlayView()
    var onLayout: (() -> Void)?

    /// PencilKit registers its own stroke-level undo actions with the responder
    /// chain's undo manager. Our editor keeps a single snapshot-based history, so
    /// PencilKit's registrations go to a private sink that is never used.
    private let undoSink: UndoManager = {
        let u = UndoManager()
        u.levelsOfUndo = 1
        return u
    }()

    override var undoManager: UndoManager? { undoSink }

    override init(frame: CGRect) {
        super.init(frame: frame)
        pageContainer.layer.anchorPoint = .zero
        pageContainer.isUserInteractionEnabled = false
        pageContainer.backgroundColor = .clear
        addSubview(pageContainer)
        addSubview(deskMask)
        addSubview(overlay)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // PencilKit adds its own subviews; keep ours in the right order.
        if subviews.first !== pageContainer { sendSubviewToBack(pageContainer) }
        if subviews.last !== overlay {
            bringSubviewToFront(deskMask)
            bringSubviewToFront(overlay)
        }
        onLayout?()
    }

    func clearUndoSink() {
        undoSink.removeAllActions()
    }
}

// MARK: - Page tiles

/// What a page tile draws: paper/PDF background plus typed text and images.
nonisolated struct PageTileSnapshot: @unchecked Sendable {
    var background: PageBackground
    var size: CGSize
    var elements: [PageElement]
    var assets: AssetStore
    var board: Bool
    /// False on whiteboards whose paper is drawn live underneath (dots, grid, blank).
    var drawsBackground: Bool = true
}

/// CATiledLayer renders crisply at any zoom, on background threads.
nonisolated final class PageTiledLayer: CATiledLayer {
    private let lock = NSLock()
    private var _snapshot: PageTileSnapshot?

    override class func fadeDuration() -> CFTimeInterval { 0 }

    var snapshot: PageTileSnapshot? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _snapshot
        }
        set {
            lock.lock()
            _snapshot = newValue
            lock.unlock()
        }
    }

    override init() {
        super.init()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? PageTiledLayer { _snapshot = other.snapshot }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(in ctx: CGContext) {
        guard let snap = snapshot else { return }
        if snap.drawsBackground {
            PageRenderer.drawBackground(snap.background, size: snap.size, assets: snap.assets, in: ctx, board: snap.board)
        }
        if !snap.elements.isEmpty {
            let clip = ctx.boundingBoxOfClipPath
            for element in snap.elements where element.frame.insetBy(dx: -4, dy: -4).intersects(clip) {
                PageRenderer.drawElement(element, assets: snap.assets, in: ctx, imageMaxPixels: 2600)
            }
        }
    }
}

final class PageTileView: UIView {
    override class var layerClass: AnyClass { PageTiledLayer.self }

    private var tiled: PageTiledLayer { layer as! PageTiledLayer }
    private(set) var pageID: UUID?
    private var lastBackground: PageBackground?
    private var lastSize: CGSize = .zero
    private var lastElements: [PageElement] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .white
        isUserInteractionEnabled = false
        tiled.tileSize = CGSize(width: 512, height: 512)
        tiled.levelsOfDetail = 4
        tiled.levelsOfDetailBias = 5
        tiled.contentsScale = UIScreen.main.scale
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Updates what the tile shows, invalidating only what changed.
    func configure(page: Page, hiddenElements: Set<UUID>, assets: AssetStore) {
        let elements = page.elements.filter { !hiddenElements.contains($0.id) }
        // On a whiteboard the paper is drawn live underneath (BoardPatternLayer);
        // the tiles only carry text boxes and images.
        let kind = page.background.paperKind
        let paperUnderneath = page.isBoard && (kind == .blank || kind?.hasBoardPattern == true)
        isOpaque = !paperUnderneath
        backgroundColor = paperUnderneath ? .clear : page.background.paperColor.fill.uiColor
        var snap = PageTileSnapshot(background: page.background, size: page.size, elements: elements, assets: assets, board: page.isBoard)
        snap.drawsBackground = !paperUnderneath
        // A whiteboard's pattern is anchored to its origin and it only grows by
        // whole pattern repeats, so a new size doesn't change what is drawn:
        // redrawing everything would make it blink.
        let sizeMatters = !page.isBoard
        if pageID != page.id || lastBackground != page.background || (sizeMatters && lastSize != page.size) {
            if pageID != page.id {
                // Boards zoom much further out than pages.
                tiled.levelsOfDetail = page.isBoard ? 8 : 4
            }
            pageID = page.id
            lastBackground = page.background
            lastSize = page.size
            lastElements = elements
            tiled.snapshot = snap
            tiled.setNeedsDisplay()
            return
        }
        let resized = lastSize != page.size
        lastSize = page.size
        guard elements != lastElements || resized else { return }
        // Invalidate the union of changed element frames (old and new).
        let oldByID = Dictionary(lastElements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newByID = Dictionary(elements.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var dirty = CGRect.null
        for (id, el) in oldByID where newByID[id] != el { dirty = dirty.union(el.frame) }
        for (id, el) in newByID where oldByID[id] != el { dirty = dirty.union(el.frame) }
        // Order changes affect overlaps; just redraw everything involved.
        if lastElements.map(\.id) != elements.map(\.id) {
            for el in elements { dirty = dirty.union(el.frame) }
        }
        lastElements = elements
        tiled.snapshot = snap
        if !dirty.isNull {
            tiled.setNeedsDisplay(dirty.insetBy(dx: -8, dy: -8))
        }
    }

    func redrawAll() {
        tiled.setNeedsDisplay()
    }
}

// MARK: - Desk mask

/// Covers everything outside the pages with the desk color (hiding stray ink)
/// and draws the page shadows and outlines.
final class DeskMaskView: UIView {
    private let desk = CAShapeLayer()
    private let shadow = CALayer()
    private let shadowMask = CAShapeLayer()
    private let outline = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        desk.fillRule = .evenOdd
        shadowMask.fillRule = .evenOdd
        shadow.mask = shadowMask
        shadow.shadowColor = UIColor.black.cgColor
        shadow.shadowOpacity = 0.14
        shadow.shadowRadius = 10
        shadow.shadowOffset = CGSize(width: 0, height: 3)
        outline.fillColor = nil
        outline.lineWidth = 0.5
        layer.addSublayer(desk)
        layer.addSublayer(shadow)
        layer.addSublayer(outline)
        for l in [desk, shadow, shadowMask, outline] as [CALayer] {
            l.actions = ["path": NSNull(), "shadowPath": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        }
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: DeskMaskView, _) in
            view.updateColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateColors() {
        let traits = traitCollection
        desk.fillColor = Theme.deskUI.resolvedColor(with: traits).cgColor
        outline.strokeColor = UIColor.black.withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.6 : 0.08).cgColor
        shadow.shadowOpacity = traits.userInterfaceStyle == .dark ? 0.5 : 0.14
    }

    /// `pageRects` and `extent` are in this view's coordinates (content points).
    func update(pageRects: [CGRect], extent: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let outer = extent.insetBy(dx: -4000, dy: -4000)
        let deskPath = CGMutablePath()
        deskPath.addRect(outer)
        let pagesPath = CGMutablePath()
        for r in pageRects {
            deskPath.addRect(r)
            pagesPath.addRect(r)
        }
        desk.frame = bounds
        shadow.frame = bounds
        shadowMask.frame = bounds
        outline.frame = bounds
        desk.path = deskPath
        shadowMask.path = deskPath
        shadow.shadowPath = pagesPath
        outline.path = pagesPath
        CATransaction.commit()
    }
}

// MARK: - Overlay

/// Holds interactive views above the ink. Touches pass through except where a
/// visible, interactive subview is hit.
final class CanvasOverlayView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        for sub in subviews where !sub.isHidden && sub.alpha > 0.01 && sub.isUserInteractionEnabled {
            if sub.point(inside: convert(point, to: sub), with: event) { return true }
        }
        return false
    }
}

/// The "+ Add page" pill below the last page.
final class AddPageButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        var config = UIButton.Configuration.filled()
        config.cornerStyle = .capsule
        config.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        config.imagePadding = 6
        config.title = "Add page"
        config.baseBackgroundColor = Theme.raisedUI
        config.baseForegroundColor = Theme.inkUI
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 20)
        configuration = config
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.1
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 2)
        accessibilityLabel = "Add page"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
