import NotesCraftCore
import PencilKit
import UIKit

/// Draws page backgrounds, templates and elements into any CoreGraphics context
/// whose coordinates are page points with y pointing down. Used by on-screen
/// tiles, thumbnails and PDF export so all three always match.
nonisolated enum PageRenderer {
    // MARK: Background

    static func drawBackground(_ background: PageBackground, size: CGSize, assets: AssetStore?, in ctx: CGContext, board: Bool = false) {
        let rect = CGRect(origin: .zero, size: size)
        switch background {
        case let .paper(kind, color):
            drawPaper(kind: kind, color: color, size: size, in: ctx, board: board)
        case let .pdf(asset, index):
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(rect)
            if let assets, let page = assets.pdfPage(asset, index: index) {
                assets.pdfRenderLock.lock()
                drawPDFPage(page, size: size, in: ctx)
                assets.pdfRenderLock.unlock()
            } else {
                drawMissing(size: size, in: ctx)
            }
        case let .image(asset):
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(rect)
            if let assets, let image = assets.image(asset) {
                drawImage(image, in: rect, ctx: ctx)
            } else {
                drawMissing(size: size, in: ctx)
            }
        }
    }

    static func drawPDFPage(_ page: CGPDFPage, size: CGSize, in ctx: CGContext) {
        ctx.saveGState()
        // PDF space is y-up; flip into our y-down page space.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        let target = CGRect(origin: .zero, size: size)
        let transform = page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true)
        ctx.concatenate(transform)
        ctx.clip(to: page.getBoxRect(.cropBox))
        ctx.interpolationQuality = .high
        ctx.setRenderingIntent(.defaultIntent)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }

    /// Draws a CGImage into a y-down rect without flipping it.
    static func drawImage(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    static func drawMissing(size: CGSize, in ctx: CGContext) {
        let r = CGRect(origin: .zero, size: size).insetBy(dx: 24, dy: 24)
        ctx.setStrokeColor(UIColor.systemGray3.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [6, 6])
        ctx.stroke(r)
        ctx.setLineDash(phase: 0, lengths: [])
    }

    // MARK: Paper

    /// `lineScale` thickens rules and dots (for small previews).
    static func drawPaper(kind: PaperKind, color: PaperColor, size: CGSize, in ctx: CGContext, lineScale: Double = 1, board: Bool = false) {
        let w = Double(size.width), h = Double(size.height)
        ctx.setFillColor(color.fill.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if board && kind.hasBoardPattern {
            drawBoardPattern(kind: kind, color: color, size: size, in: ctx)
            return
        }

        let rule = color.ruleColor.cgColor
        let lineWidth = 0.6
        ctx.setLineCap(.butt)

        func hLine(_ y: Double, from x0: Double = 0, to x1: Double? = nil, color c: CGColor = rule, width lw: Double = lineWidth) {
            ctx.setStrokeColor(c)
            ctx.setLineWidth(lw * lineScale)
            ctx.move(to: CGPoint(x: x0, y: y))
            ctx.addLine(to: CGPoint(x: x1 ?? w, y: y))
            ctx.strokePath()
        }
        func vLine(_ x: Double, from y0: Double = 0, to y1: Double? = nil, color c: CGColor = rule, width lw: Double = lineWidth) {
            ctx.setStrokeColor(c)
            ctx.setLineWidth(lw * lineScale)
            ctx.move(to: CGPoint(x: x, y: y0))
            ctx.addLine(to: CGPoint(x: x, y: y1 ?? h))
            ctx.strokePath()
        }

        let s = kind.spacing
        // Only the part being drawn (a tile of a large page) is worth looping over.
        let clip = ctx.boundingBoxOfClipPath.insetBy(dx: -2, dy: -2)
        // On a whiteboard zoomed far out, thin dots and grid lines out so they
        // don't turn into gray mush: keep them at least ~7 device pixels apart.
        var step = 1
        if w >= 4000 || h >= 4000 {
            let deviceScale = max(abs(Double(ctx.ctm.a)), 0.0001)
            while s * Double(step) * deviceScale < 7, step < 64 { step *= 2 }
        }
        func firstIndex(_ origin: Double, _ lower: Double) -> Int {
            guard s > 0, lower.isFinite else { return 0 }
            return max(0, Int(((lower - origin) / s).rounded(.down)))
        }
        let topMargin = min(max(h * 0.09, 48), 96)
        let bottomMargin = min(max(h * 0.045, 24), 54)

        switch kind {
        case .blank:
            break

        case .collegeRuled, .narrowRuled, .wideRuled, .legal:
            var y = topMargin
            while y <= h - bottomMargin {
                hLine(y)
                y += s
            }
            let marginX = min(max(w * 0.13, 48), 96)
            vLine(marginX, color: color.marginColor.cgColor, width: 0.8)
            if kind == .legal { vLine(marginX + 3, color: color.marginColor.cgColor, width: 0.8) }

        case .grid, .smallGrid:
            let ox = (w - (w / s).rounded(.down) * s) / 2
            let oy = (h - (h / s).rounded(.down) * s) / 2
            let strong = color.ruleColor.withAlpha(min(1, color.ruleColor.a * 1.5)).cgColor
            // Small grids keep every fifth (strong) line when thinned out.
            let gridStep = kind == .smallGrid && step > 1 ? max(5, step - step % 5) : step
            var i = firstIndex(ox, clip.minX)
            i -= i % gridStep
            var x = ox + Double(i) * s
            while x <= min(w + 0.01, Double(clip.maxX)) {
                vLine(x, from: max(0, Double(clip.minY)), to: min(h, Double(clip.maxY)),
                      color: (kind == .smallGrid && i % 5 == 0) ? strong : rule, width: kind == .smallGrid ? 0.4 : 0.5)
                x += s * Double(gridStep)
                i += gridStep
            }
            i = firstIndex(oy, clip.minY)
            i -= i % gridStep
            var y = oy + Double(i) * s
            while y <= min(h + 0.01, Double(clip.maxY)) {
                hLine(y, from: max(0, Double(clip.minX)), to: min(w, Double(clip.maxX)),
                      color: (kind == .smallGrid && i % 5 == 0) ? strong : rule, width: kind == .smallGrid ? 0.4 : 0.5)
                y += s * Double(gridStep)
                i += gridStep
            }

        case .dotted:
            let ox = (w - (w / s).rounded(.down) * s) / 2
            let oy = (h - (h / s).rounded(.down) * s) / 2
            let dot = color.ruleColor.withAlpha(min(1, color.ruleColor.a * 1.6)).cgColor
            ctx.setFillColor(dot)
            let r = 0.85 * lineScale
            var row = max(1, firstIndex(oy, clip.minY))
            row += (step - row % step) % step
            var y = oy + Double(row) * s
            let firstColumn: Int = {
                var c = max(1, firstIndex(ox, clip.minX))
                c += (step - c % step) % step
                return c
            }()
            while y < min(h - 0.01, Double(clip.maxY) + r) {
                var x = ox + Double(firstColumn) * s
                while x < min(w - 0.01, Double(clip.maxX) + r) {
                    ctx.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                    x += s * Double(step)
                }
                y += s * Double(step)
            }
            ctx.fillPath()

        case .cornell:
            let header = min(max(h * 0.1, 60), 110)
            let summaryTop = h * 0.79
            let cueX = w * 0.3
            hLine(header, width: 1)
            var y = header + s
            while y < summaryTop - 2 {
                hLine(y, from: cueX)
                y += s
            }
            vLine(cueX, from: header, to: summaryTop, width: 1)
            hLine(summaryTop, width: 1)

        case .checklist:
            var y = topMargin
            let box = min(s * 0.55, 12)
            let boxX = min(max(w * 0.07, 28), 48)
            ctx.setStrokeColor(color.ruleColor.withAlpha(min(1, color.ruleColor.a * 1.7)).cgColor)
            while y + s <= h - bottomMargin {
                hLine(y + s)
                let r = CGRect(x: boxX, y: y + (s - box) / 2 + 1, width: box, height: box)
                ctx.setStrokeColor(color.ruleColor.withAlpha(min(1, color.ruleColor.a * 1.7)).cgColor)
                ctx.setLineWidth(0.9 * lineScale)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 2, cornerHeight: 2, transform: nil))
                ctx.strokePath()
                y += s
            }

        case .music:
            let staffGap = s
            let staffHeight = staffGap * 4
            let pitch = staffHeight + staffGap * 5
            let left = min(max(w * 0.07, 28), 54)
            var top = topMargin * 0.8
            let staffColor = color.ruleColor.withAlpha(min(1, color.ruleColor.a * 1.6)).cgColor
            while top + staffHeight <= h - bottomMargin {
                for k in 0 ..< 5 {
                    hLine(top + Double(k) * staffGap, from: left, to: w - left, color: staffColor, width: 0.6)
                }
                vLine(left, from: top, to: top + staffHeight, color: staffColor, width: 0.8)
                vLine(w - left, from: top, to: top + staffHeight, color: staffColor, width: 0.8)
                top += pitch
            }
        }
    }

    /// Largest pattern repeat a board can show (dots thin out by powers of two
    /// when zoomed out); growing a board by multiples of it keeps every dot in place.
    static let boardPatternPeriod: Double = 25 * 256

    /// A whiteboard's dots or grid, GoodNotes style: wide spacing, soft gray,
    /// anchored to the board's origin, dots that stay visible at any zoom, and
    /// thinned out by powers of two when zoomed far out.
    static func drawBoardPattern(kind: PaperKind, color: PaperColor, size: CGSize, in ctx: CGContext) {
        let s = kind.boardSpacing
        guard s > 0 else { return }
        let deviceScale = max(abs(Double(ctx.ctm.a)), 0.0001) // pixels per point
        // Same rule as the live pattern (BoardPatternLayer): dots at least 7.5
        // points apart, at two pixels per point.
        let minGapPixels = kind == .dotted ? 15.0 : 24.0
        var step = 1
        while s * Double(step) * deviceScale < minGapPixels, step < 256 { step *= 2 }
        let pitch = s * Double(step)
        let clip = ctx.boundingBoxOfClipPath.intersection(CGRect(origin: .zero, size: size))
        guard !clip.isNull, clip.width > 0, clip.height > 0 else { return }
        let i0 = Int((Double(clip.minX) / pitch).rounded(.down)), i1 = Int((Double(clip.maxX) / pitch).rounded(.up))
        let j0 = Int((Double(clip.minY) / pitch).rounded(.down)), j1 = Int((Double(clip.maxY) / pitch).rounded(.up))
        guard i1 >= i0, j1 >= j0, (i1 - i0 + 1) * (j1 - j0 + 1) < 200_000 else { return }
        let dark = color.isDark
        if kind == .dotted {
            // About 2.4 pixels across, so dots stay small but never vanish.
            let r = max(0.45, 1.2 / deviceScale)
            ctx.setFillColor((dark ? RGBA(hex: "#6E7270")! : RGBA(hex: "#BDBDC2")!).cgColor)
            for j in j0 ... j1 {
                for i in i0 ... i1 {
                    let x = Double(i) * pitch, y = Double(j) * pitch
                    ctx.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                }
            }
            ctx.fillPath()
            return
        }
        let lineWidth = max(0.5, 1.1 / deviceScale)
        let minor = (dark ? RGBA(hex: "#3F4341")! : RGBA(hex: "#E2E2E6")!).cgColor
        let major = (dark ? RGBA(hex: "#4D524F")! : RGBA(hex: "#CFCFD5")!).cgColor
        ctx.setLineWidth(lineWidth)
        func stroke(_ isMajor: Bool, _ lines: () -> Void) {
            lines()
            ctx.setStrokeColor(isMajor ? major : minor)
            ctx.strokePath()
        }
        for majorPass in [false, true] {
            stroke(majorPass) {
                for i in i0 ... i1 where (kind == .smallGrid && i * step % 5 == 0) == majorPass {
                    let x = Double(i) * pitch
                    ctx.move(to: CGPoint(x: x, y: Double(clip.minY)))
                    ctx.addLine(to: CGPoint(x: x, y: Double(clip.maxY)))
                }
                for j in j0 ... j1 where (kind == .smallGrid && j * step % 5 == 0) == majorPass {
                    let y = Double(j) * pitch
                    ctx.move(to: CGPoint(x: Double(clip.minX), y: y))
                    ctx.addLine(to: CGPoint(x: Double(clip.maxX), y: y))
                }
            }
        }
    }

    // MARK: Elements

    static func drawElements(_ elements: [PageElement], assets: AssetStore?, in ctx: CGContext, imageMaxPixels: Int = 3000) {
        for element in elements {
            drawElement(element, assets: assets, in: ctx, imageMaxPixels: imageMaxPixels)
        }
    }

    static func drawElement(_ element: PageElement, assets: AssetStore?, in ctx: CGContext, imageMaxPixels: Int = 3000) {
        switch element.content {
        case let .image(asset):
            if let assets, let image = assets.image(asset, maxPixels: imageMaxPixels) {
                drawImage(image, in: element.frame, ctx: ctx)
            } else {
                ctx.setFillColor(UIColor.systemGray5.cgColor)
                ctx.fill(element.frame)
            }
        case let .text(content):
            drawText(content, in: element.frame, ctx: ctx)
        }
    }

    static func drawText(_ content: TextContent, in frame: CGRect, ctx: CGContext) {
        if let fill = content.fill {
            ctx.setFillColor(fill.cgColor)
            ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
        }
        let string = TextStyling.attributedString(content)
        UIGraphicsPushContext(ctx)
        string.draw(with: frame.insetBy(dx: TextStyling.textInset, dy: TextStyling.textInset),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        UIGraphicsPopContext()
    }

    // MARK: Whole pages

    /// Renders a full page (background, elements and ink) to an image.
    static func image(page: Page, drawing: PKDrawing, assets: AssetStore?, scale: CGFloat, opaque: Bool = true) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = opaque
        let renderer = UIGraphicsImageRenderer(size: page.size, format: format)
        let inkImage = InkRenderer.image(of: drawing, in: page.bounds, scale: scale)
        return renderer.image { context in
            let ctx = context.cgContext
            drawBackground(page.background, size: page.size, assets: assets, in: ctx, board: page.isBoard)
            drawElements(page.elements, assets: assets, in: ctx, imageMaxPixels: Int(max(page.size.width, page.size.height) * scale))
            inkImage?.draw(in: page.bounds)
        }
    }
}

/// Rendering of PencilKit ink outside a canvas.
nonisolated enum InkRenderer {
    /// Ink as a bitmap. Always renders in the light appearance so dark mode never
    /// inverts ink colors in exports and thumbnails.
    static func image(of drawing: PKDrawing, in rect: CGRect, scale: CGFloat) -> UIImage? {
        guard !drawing.strokes.isEmpty, !drawing.bounds.intersection(rect).isNull else { return nil }
        var result: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            result = drawing.image(from: rect, scale: scale)
        }
        return result
    }

    /// Ink types whose look a filled outline reproduces faithfully.
    static func isVectorFriendly(_ ink: PKInk) -> Bool {
        switch ink.inkType {
        case .pen, .monoline, .fountainPen, .marker: true
        default: false
        }
    }

    /// Draws strokes as filled vector outlines (sharp at any zoom, small PDFs).
    /// Textured inks (pencil, crayon, watercolor) are drawn as a bitmap instead.
    static func drawVector(_ drawing: PKDrawing, pageRect: CGRect, in ctx: CGContext, bitmapScale: CGFloat = 3) {
        var textured: [PKStroke] = []
        ctx.saveGState()
        ctx.translateBy(x: -pageRect.minX, y: -pageRect.minY)
        for stroke in drawing.strokes {
            guard stroke.renderBounds.intersects(pageRect) else { continue }
            if !isVectorFriendly(stroke.ink) {
                textured.append(stroke)
                continue
            }
            drawStroke(stroke, in: ctx)
        }
        ctx.restoreGState()
        if !textured.isEmpty, let img = image(of: PKDrawing(strokes: textured), in: pageRect, scale: bitmapScale), let cg = img.cgImage {
            PageRenderer.drawImage(cg, in: CGRect(origin: .zero, size: pageRect.size), ctx: ctx)
        }
    }

    static func drawStroke(_ stroke: PKStroke, in ctx: CGContext) {
        let color = stroke.ink.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var alpha: CGFloat = 0
        color.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        let isMarker = stroke.ink.inkType == .marker
        let path = outlinePath(for: stroke)
        guard !path.isEmpty else { return }
        ctx.saveGState()
        if let mask = stroke.mask {
            ctx.concatenate(stroke.transform)
            ctx.addPath(mask.cgPath)
            ctx.clip()
            ctx.concatenate(stroke.transform.inverted())
        }
        if isMarker {
            // Markers are translucent with a multiply look.
            ctx.setBlendMode(.multiply)
            ctx.setAlpha(min(1, max(0.3, alpha)))
            ctx.setFillColor(color.withAlphaComponent(1).cgColor)
        } else {
            ctx.setFillColor(color.cgColor)
        }
        ctx.addPath(path)
        ctx.fillPath(using: .winding)
        ctx.restoreGState()
    }

    /// The filled outline of a stroke, in drawing coordinates: one polygon running
    /// up the left edge and back down the right, with round caps, plus round
    /// patches at sharp turns.
    static func outlinePath(for stroke: PKStroke) -> CGPath {
        let path = CGMutablePath()
        let t = stroke.transform
        let scale = max((abs(t.a * t.d - t.b * t.c)).squareRoot(), 0.01)
        var points: [CGPoint] = []
        var widths: [CGFloat] = []
        for p in stroke.path.interpolatedPoints(by: .distance(1.5)) {
            let loc = p.location.applying(t)
            var width = max(p.size.width, 0.3) * scale
            if stroke.ink.inkType == .fountainPen {
                width = max(width * 0.75, (p.size.width + p.size.height) / 2 * 0.6 * scale)
            }
            if let last = points.last, hypot(last.x - loc.x, last.y - loc.y) < 0.4 {
                widths[widths.count - 1] = max(widths[widths.count - 1], width)
                continue
            }
            points.append(loc)
            widths.append(width)
        }
        guard let first = points.first else { return path }
        if points.count == 1 {
            let r = widths[0] / 2
            path.addEllipse(in: CGRect(x: first.x - r, y: first.y - r, width: 2 * r, height: 2 * r))
            return path
        }
        let n = points.count
        var left: [CGPoint] = [], right: [CGPoint] = []
        left.reserveCapacity(n)
        right.reserveCapacity(n)
        for i in 0 ..< n {
            let a = points[max(0, i - 1)], b = points[min(n - 1, i + 1)]
            var dx = b.x - a.x, dy = b.y - a.y
            let len = hypot(dx, dy)
            if len < 0.0001 { dx = 1; dy = 0 } else { dx /= len; dy /= len }
            let r = widths[i] / 2
            left.append(CGPoint(x: points[i].x - dy * r, y: points[i].y + dx * r))
            right.append(CGPoint(x: points[i].x + dy * r, y: points[i].y - dx * r))
        }
        func angle(_ from: CGPoint, _ to: CGPoint) -> CGFloat { atan2(to.y - from.y, to.x - from.x) }
        path.move(to: left[0])
        for i in 1 ..< n { path.addLine(to: left[i]) }
        let endAngle = angle(points[n - 2], points[n - 1])
        path.addArc(center: points[n - 1], radius: widths[n - 1] / 2, startAngle: endAngle + .pi / 2, endAngle: endAngle - .pi / 2, clockwise: true)
        for i in stride(from: n - 1, through: 0, by: -1) { path.addLine(to: right[i]) }
        let startAngle = angle(points[0], points[1])
        path.addArc(center: points[0], radius: widths[0] / 2, startAngle: startAngle - .pi / 2, endAngle: startAngle + .pi / 2, clockwise: true)
        path.closeSubpath()
        // Sharp turns can fold the outline over itself; cover them with a dot.
        if n > 2 {
            for i in 1 ..< n - 1 {
                let a1 = angle(points[i - 1], points[i]), a2 = angle(points[i], points[i + 1])
                var turn = abs(a2 - a1)
                if turn > .pi { turn = 2 * .pi - turn }
                if turn > .pi / 4 {
                    let r = widths[i] / 2
                    path.addEllipse(in: CGRect(x: points[i].x - r, y: points[i].y - r, width: 2 * r, height: 2 * r))
                }
            }
        }
        return path
    }
}
