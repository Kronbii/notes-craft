import NotesCraftCore
import UIKit

/// The dots or grid of a whiteboard, drawn live for the exact zoom (not cached
/// per zoom band), following GoodNotes: 25 pt between dots, every 2nd, 4th, 8th…
/// dot when zoomed out so they are never closer than 7.5 points on screen, and
/// dots that stay small (about 1.3 to 2.4 points across) at any zoom.
/// Replicator layers make scrolling and pinching cost a few property changes.
nonisolated final class BoardPatternLayer: CALayer {
    private let rows = CAReplicatorLayer()
    private let columns = CAReplicatorLayer()
    private let dot = CALayer()
    private let vLines = CAReplicatorLayer()
    private let vLine = CALayer()
    private let hLines = CAReplicatorLayer()
    private let hLine = CALayer()

    /// Spacing on screen below which dots (or grid lines) are thinned out.
    static let minDotGap: CGFloat = 7.5
    static let minLineGap: CGFloat = 12

    /// Pattern repeat in document points at a zoom (base spacing times a power of two).
    static func pitch(base: CGFloat, zoom: CGFloat, minGap: CGFloat) -> CGFloat {
        CGFloat(PaperKind.boardPitch(base: Double(base), zoom: Double(zoom), minGap: Double(minGap)))
    }

    /// Dot diameter on screen (points) at a zoom.
    static func dotDiameter(zoom: CGFloat) -> CGFloat {
        min(2.4, max(1.3, 0.9 + 1.1 * zoom))
    }

    override init() {
        super.init()
        columns.addSublayer(dot)
        rows.addSublayer(columns)
        addSublayer(rows)
        vLines.addSublayer(vLine)
        hLines.addSublayer(hLine)
        addSublayer(vLines)
        addSublayer(hLines)
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func hidePattern() {
        rows.isHidden = true
        vLines.isHidden = true
        hLines.isHidden = true
    }

    /// - Parameters:
    ///   - pageFrame: the board page in document coordinates (this layer's frame).
    ///   - visible: the visible area in document coordinates.
    func update(background: PageBackground, pageFrame: CGRect, visible: CGRect, zoom: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if frame != pageFrame { frame = pageFrame }
        guard case let .paper(kind, color) = background else {
            backgroundColor = UIColor.white.cgColor
            hidePattern()
            return
        }
        backgroundColor = color.fill.cgColor
        guard kind.hasBoardPattern, zoom > 0 else {
            hidePattern()
            return
        }
        let dotted = kind == .dotted
        let pitch = Self.pitch(base: CGFloat(kind.boardSpacing), zoom: zoom, minGap: dotted ? Self.minDotGap : Self.minLineGap)
        let local = visible.offsetBy(dx: -pageFrame.minX, dy: -pageFrame.minY)
            .intersection(CGRect(origin: .zero, size: pageFrame.size))
        guard !local.isNull, local.width > 0, local.height > 0 else {
            hidePattern()
            return
        }
        let i0 = (local.minX / pitch).rounded(.down), i1 = (local.maxX / pitch).rounded(.up)
        let j0 = (local.minY / pitch).rounded(.down), j1 = (local.maxY / pitch).rounded(.up)
        let nx = Int(i1 - i0) + 1, ny = Int(j1 - j0) + 1
        guard nx > 0, ny > 0, nx < 800, ny < 800 else {
            hidePattern()
            return
        }
        let origin = CGPoint(x: i0 * pitch, y: j0 * pitch)
        let dark = color.isDark
        if dotted {
            vLines.isHidden = true
            hLines.isHidden = true
            rows.isHidden = false
            let d = Self.dotDiameter(zoom: zoom) / zoom
            dot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            dot.position = .zero
            dot.cornerRadius = d / 2
            dot.backgroundColor = (dark ? RGBA(hex: "#6E7270")! : RGBA(hex: "#BDBDC2")!).cgColor
            columns.frame = .zero
            columns.instanceCount = nx
            columns.instanceTransform = CATransform3DMakeTranslation(pitch, 0, 0)
            rows.frame = CGRect(origin: origin, size: .zero)
            rows.instanceCount = ny
            rows.instanceTransform = CATransform3DMakeTranslation(0, pitch, 0)
        } else {
            rows.isHidden = true
            vLines.isHidden = false
            hLines.isHidden = false
            let w = 0.8 / zoom
            let lineColor = (dark ? RGBA(hex: "#3F4341")! : RGBA(hex: "#E2E2E6")!).cgColor
            vLine.backgroundColor = lineColor
            hLine.backgroundColor = lineColor
            vLine.frame = CGRect(x: -w / 2, y: 0, width: w, height: CGFloat(ny - 1) * pitch)
            vLines.frame = CGRect(origin: origin, size: .zero)
            vLines.instanceCount = nx
            vLines.instanceTransform = CATransform3DMakeTranslation(pitch, 0, 0)
            hLine.frame = CGRect(x: 0, y: -w / 2, width: CGFloat(nx - 1) * pitch, height: w)
            hLines.frame = CGRect(origin: origin, size: .zero)
            hLines.instanceCount = ny
            hLines.instanceTransform = CATransform3DMakeTranslation(0, pitch, 0)
        }
    }
}

extension CanvasController {
    /// Keeps the live whiteboard pattern in step with the zoom and scroll position.
    func updateBoardPattern() {
        guard isBoard, let frame = layout.frame(of: 0), let page = document.pages.first else {
            boardPattern?.removeFromSuperlayer()
            boardPattern = nil
            return
        }
        let layer = boardPattern ?? {
            let l = BoardPatternLayer()
            canvas.pageContainer.layer.insertSublayer(l, at: 0)
            boardPattern = l
            return l
        }()
        layer.update(background: page.background, pageFrame: frame, visible: visibleDocRect, zoom: zoom)
    }
}
