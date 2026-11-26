import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A clean geometric shape recognized from a hand-drawn stroke.
public enum RecognizedShape: Equatable, Sendable {
    case line(CGPoint, CGPoint)
    /// Open chain of straight segments (an angle, a zig-zag of 2-4 segments).
    case polyline([CGPoint])
    /// Closed polygon (triangle, quadrilateral, pentagon, ...), vertices in order.
    case polygon([CGPoint])
    case ellipse(center: CGPoint, radiusX: Double, radiusY: Double, rotation: Double)

    public var name: String {
        switch self {
        case .line: "Line"
        case .polyline: "Polyline"
        case let .polygon(v):
            switch v.count {
            case 3: "Triangle"
            case 4: ShapeRecognizer.isRectangle(v) ? "Rectangle" : "Quadrilateral"
            default: "Polygon"
            }
        case let .ellipse(_, rx, ry, _): abs(rx - ry) < 0.5 ? "Circle" : "Ellipse"
        }
    }

    /// Points along the shape suitable for building a stroke. Corners and ends are
    /// repeated so a B-spline through them stays sharp.
    public func outline(spacing: Double = 3) -> [CGPoint] {
        let step = max(0.5, spacing)
        switch self {
        case let .line(a, b):
            return ShapeRecognizer.sample(segments: [a, b], spacing: step, closed: false)
        case let .polyline(points):
            return ShapeRecognizer.sample(segments: points, spacing: step, closed: false)
        case let .polygon(points):
            return ShapeRecognizer.sample(segments: points, spacing: step, closed: true)
        case let .ellipse(center, rx, ry, rotation):
            let perimeter = Double.pi * (3 * (rx + ry) - ((3 * rx + ry) * (rx + 3 * ry)).squareRoot())
            let n = max(32, Int(perimeter / step))
            var pts: [CGPoint] = []
            pts.reserveCapacity(n + 2)
            let c = cos(rotation), s = sin(rotation)
            for i in 0 ... n {
                let t = Double(i) / Double(n) * 2 * Double.pi
                let x = rx * cos(t), y = ry * sin(t)
                pts.append(CGPoint(x: center.x + x * c - y * s, y: center.y + x * s + y * c))
            }
            // Overlap slightly so the join is seamless.
            if pts.count > 2 { pts.append(pts[1]) }
            return pts
        }
    }
}

public enum ShapeRecognizer {
    public struct Options: Sendable {
        /// Snap lines within this many degrees of a multiple of 45° onto it.
        public var angleSnapDegrees: Double = 5
        /// Snap nearly-axis-aligned rectangles onto the axes.
        public var axisSnapDegrees: Double = 8
        public init() {}
    }

    public static func recognize(_ raw: [CGPoint], options: Options = Options()) -> RecognizedShape? {
        let points = dedupe(raw)
        guard points.count >= 3 else {
            if points.count == 2, distance(points[0], points[1]) > 8 {
                let (a, b) = snapLine(points[0], points[1], options: options)
                return .line(a, b)
            }
            return nil
        }
        let box = boundingBox(points)
        let diag = (box.width * box.width + box.height * box.height).squareRoot()
        guard diag >= 10 else { return nil }
        let length = pathLength(points)
        let gap = distance(points.first!, points.last!)

        // Straight line?
        if let line = fitLine(points, length: length, diag: diag) {
            let (a, b) = snapLine(line.0, line.1, options: options)
            return .line(a, b)
        }

        let closed = gap < max(0.22 * diag, 0.1 * length) && length > 2.2 * diag * 0.5
        if closed {
            return recognizeClosed(points, diag: diag, options: options)
        } else {
            return recognizeOpen(points, diag: diag)
        }
    }

    /// For the highlighter's straight-line mode: the straightened segment, or nil if
    /// the stroke clearly isn't meant to be straight.
    public static func straightened(_ raw: [CGPoint], options: Options = Options()) -> (CGPoint, CGPoint)? {
        let points = dedupe(raw)
        guard points.count >= 2 else { return nil }
        let length = pathLength(points)
        let box = boundingBox(points)
        let diag = (box.width * box.width + box.height * box.height).squareRoot()
        guard diag > 6 else { return nil }
        guard let line = fitLine(points, length: length, diag: diag, tolerance: 0.12) else { return nil }
        return snapLine(line.0, line.1, options: options)
    }

    // MARK: - Open strokes

    static func recognizeOpen(_ points: [CGPoint], diag: Double) -> RecognizedShape? {
        // Only two-segment chains (angles, check marks, carets). Longer zig-zags are
        // too easily confused with wavy handwriting.
        let simplified = rdp(points, epsilon: max(3, 0.06 * diag))
        guard simplified.count == 3 else { return nil }
        for i in 0 ..< simplified.count - 1 where distance(simplified[i], simplified[i + 1]) < 0.15 * diag {
            return nil
        }
        let meanError = meanDistance(points, toPolyline: simplified, closed: false)
        guard meanError < 0.02 * diag + 0.5 else { return nil }
        var maxError = 0.0
        for p in points {
            maxError = max(maxError, min(segmentDistance(p, simplified[0], simplified[1]), segmentDistance(p, simplified[1], simplified[2])))
        }
        guard maxError < 0.05 * diag + 1 else { return nil }
        let angle = interiorAngle(simplified[0], simplified[1], simplified[2])
        guard angle < 155 else { return nil }
        return .polyline(simplified)
    }

    // MARK: - Closed strokes

    static func recognizeClosed(_ points: [CGPoint], diag: Double, options: Options) -> RecognizedShape? {
        let ellipse = fitEllipse(points)
        let polygon = fitPolygon(points, diag: diag)

        if let polygon {
            let polyError = meanDistance(points, toPolyline: polygon, closed: true) / diag
            let ellipseError = ellipse?.error ?? .infinity
            // Polygons with clear corners win unless the ellipse fits much better.
            if polygon.count <= 4, polyError < 0.04, polyError < ellipseError * 1.6 {
                return .polygon(regularize(polygon, options: options))
            }
            if polygon.count <= 6, polyError < 0.03, polyError < ellipseError {
                return .polygon(polygon)
            }
        }
        if let ellipse, ellipse.error < 0.1 {
            var rx = ellipse.rx, ry = ellipse.ry, rot = ellipse.rotation
            let ratio = min(rx, ry) / max(rx, ry)
            if ratio > 0.86 {
                let r = (rx + ry) / 2
                rx = r
                ry = r
                rot = 0
            } else {
                // Snap the axes to horizontal/vertical when close.
                let deg = rot * 180 / Double.pi
                let nearest = (deg / 90).rounded() * 90
                if abs(deg - nearest) < options.axisSnapDegrees { rot = nearest * Double.pi / 180 }
            }
            return .ellipse(center: ellipse.center, radiusX: rx, radiusY: ry, rotation: rot)
        }
        return nil
    }

    /// Finds the corners of a closed stroke. Returns nil when it is too round or too wiggly.
    static func fitPolygon(_ points: [CGPoint], diag: Double) -> [CGPoint]? {
        // Start the simplification at the point farthest from the centroid so a
        // corner (not the middle of an edge) anchors it.
        let centroid = mean(points)
        var startIndex = 0
        var far = -1.0
        for (i, p) in points.enumerated() {
            let d = distance(p, centroid)
            if d > far {
                far = d
                startIndex = i
            }
        }
        var loop = Array(points[startIndex...]) + Array(points[..<startIndex])
        loop.append(loop[0])
        var simplified = rdp(loop, epsilon: max(3, 0.07 * diag))
        if simplified.count > 1, distance(simplified.first!, simplified.last!) < 0.15 * diag {
            simplified.removeLast()
        }
        // Merge vertices that are very close together.
        var merged: [CGPoint] = []
        for p in simplified {
            if let last = merged.last, distance(last, p) < 0.1 * diag { continue }
            merged.append(p)
        }
        if merged.count > 3, let first = merged.first, let last = merged.last, distance(first, last) < 0.1 * diag {
            merged.removeLast()
        }
        // Drop vertices that are nearly straight (angle close to 180°).
        var changed = true
        while changed, merged.count > 3 {
            changed = false
            for i in 0 ..< merged.count {
                let prev = merged[(i - 1 + merged.count) % merged.count]
                let next = merged[(i + 1) % merged.count]
                if interiorAngle(prev, merged[i], next) > 160 {
                    merged.remove(at: i)
                    changed = true
                    break
                }
            }
        }
        guard merged.count >= 3, merged.count <= 6 else { return nil }
        return merged
    }

    /// Makes near-rectangles exact rectangles and snaps near-axis ones to the axes.
    static func regularize(_ polygon: [CGPoint], options: Options) -> [CGPoint] {
        guard polygon.count == 4 else { return polygon }
        let angles = (0 ..< 4).map { i in
            interiorAngle(polygon[(i + 3) % 4], polygon[i], polygon[(i + 1) % 4])
        }
        guard angles.allSatisfy({ abs($0 - 90) < 20 }) else { return polygon }
        // Orientation: average direction of the edges, folded into [0, 90).
        var sx = 0.0, sy = 0.0
        for i in 0 ..< 4 {
            let a = polygon[i], b = polygon[(i + 1) % 4]
            let theta = atan2(Double(b.y - a.y), Double(b.x - a.x))
            // Multiply by 4 so edges 90° apart reinforce each other.
            sx += cos(4 * theta)
            sy += sin(4 * theta)
        }
        var theta = atan2(sy, sx) / 4
        let deg = theta * 180 / Double.pi
        let nearest = (deg / 90).rounded() * 90
        if abs(deg - nearest) < options.axisSnapDegrees { theta = nearest * Double.pi / 180 }
        // Fit an oriented bounding box in that frame.
        let c = cos(theta), s = sin(theta)
        let center = mean(polygon)
        var minU = Double.infinity, maxU = -Double.infinity, minV = Double.infinity, maxV = -Double.infinity
        for p in polygon {
            let dx = Double(p.x - center.x), dy = Double(p.y - center.y)
            let u = dx * c + dy * s
            let v = -dx * s + dy * c
            minU = min(minU, u); maxU = max(maxU, u)
            minV = min(minV, v); maxV = max(maxV, v)
        }
        // Use the average extents of opposite corners rather than the max, which
        // overshoots for sloppy drawings.
        let corners = [(minU, minV), (maxU, minV), (maxU, maxV), (minU, maxV)]
        let rect = corners.map { u, v in
            CGPoint(x: Double(center.x) + u * c - v * s, y: Double(center.y) + u * s + v * c)
        }
        // Keep the original winding direction.
        let originalArea = signedArea(polygon)
        return (originalArea >= 0) == (signedArea(rect) >= 0) ? rect : rect.reversed()
    }

    public static func isRectangle(_ polygon: [CGPoint]) -> Bool {
        guard polygon.count == 4 else { return false }
        return (0 ..< 4).allSatisfy { i in
            abs(interiorAngle(polygon[(i + 3) % 4], polygon[i], polygon[(i + 1) % 4]) - 90) < 2
        }
    }

    struct EllipseFit {
        var center: CGPoint
        var rx: Double
        var ry: Double
        var rotation: Double
        /// Mean relative radial error.
        var error: Double
    }

    static func fitEllipse(_ points: [CGPoint]) -> EllipseFit? {
        // Resample uniformly by arc length so dense slow sections don't dominate.
        let pts = resample(points, count: 64)
        guard pts.count >= 8 else { return nil }
        let c = mean(pts)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in pts {
            let dx = Double(p.x - c.x), dy = Double(p.y - c.y)
            sxx += dx * dx
            syy += dy * dy
            sxy += dx * dy
        }
        let n = Double(pts.count)
        sxx /= n; syy /= n; sxy /= n
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let cs = cos(theta), sn = sin(theta)
        var maxU = 0.0, maxV = 0.0
        var us: [Double] = [], vs: [Double] = []
        for p in pts {
            let dx = Double(p.x - c.x), dy = Double(p.y - c.y)
            let u = dx * cs + dy * sn
            let v = -dx * sn + dy * cs
            us.append(u); vs.append(v)
            maxU = max(maxU, abs(u)); maxV = max(maxV, abs(v))
        }
        // For points spread evenly around an ellipse, the RMS along an axis is r/√2.
        let rmsU = (us.map { $0 * $0 }.reduce(0, +) / n).squareRoot() * 2.0.squareRoot()
        let rmsV = (vs.map { $0 * $0 }.reduce(0, +) / n).squareRoot() * 2.0.squareRoot()
        let rx = (rmsU + maxU) / 2, ry = (rmsV + maxV) / 2
        guard rx > 3, ry > 3 else { return nil }
        var err = 0.0
        for i in 0 ..< us.count {
            let rho = ((us[i] / rx) * (us[i] / rx) + (vs[i] / ry) * (vs[i] / ry)).squareRoot()
            err += abs(rho - 1)
        }
        // Check the stroke actually goes around (not a "C").
        let coverage = angularCoverage(pts, center: c)
        guard coverage > 0.8 else { return nil }
        return EllipseFit(center: c, rx: rx, ry: ry, rotation: theta, error: err / Double(us.count))
    }

    /// Fraction of 360° swept around the center, in 10° bins.
    static func angularCoverage(_ pts: [CGPoint], center: CGPoint) -> Double {
        var bins = [Bool](repeating: false, count: 36)
        for p in pts {
            var a = atan2(Double(p.y - center.y), Double(p.x - center.x))
            if a < 0 { a += 2 * Double.pi }
            let i = min(35, Int(a / (2 * Double.pi) * 36))
            bins[i] = true
        }
        return Double(bins.filter { $0 }.count) / 36
    }

    // MARK: - Line fitting

    static func fitLine(_ points: [CGPoint], length: Double, diag: Double, tolerance: Double = 0.06) -> (CGPoint, CGPoint)? {
        guard let a = points.first, let b = points.last else { return nil }
        let chord = distance(a, b)
        guard chord > 0.5 * diag, chord > 8 else { return nil }
        guard length < chord * 1.18 else { return nil }
        var maxDev = 0.0
        for p in points {
            maxDev = max(maxDev, perpendicularDistance(p, a, b))
        }
        guard maxDev < tolerance * chord + 1.5 else { return nil }
        // Least-squares direction keeps sloppy ends from tilting the line.
        let c = mean(points)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in points {
            let dx = Double(p.x - c.x), dy = Double(p.y - c.y)
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let dir = (cos(theta), sin(theta))
        func project(_ p: CGPoint) -> CGPoint {
            let t = Double(p.x - c.x) * dir.0 + Double(p.y - c.y) * dir.1
            return CGPoint(x: Double(c.x) + t * dir.0, y: Double(c.y) + t * dir.1)
        }
        return (project(a), project(b))
    }

    static func snapLine(_ a: CGPoint, _ b: CGPoint, options: Options) -> (CGPoint, CGPoint) {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 0, options.angleSnapDegrees > 0 else { return (a, b) }
        let deg = atan2(dy, dx) * 180 / Double.pi
        let nearest = (deg / 45).rounded() * 45
        guard abs(deg - nearest) < options.angleSnapDegrees else { return (a, b) }
        let rad = nearest * Double.pi / 180
        let mid = CGPoint(x: (Double(a.x) + Double(b.x)) / 2, y: (Double(a.y) + Double(b.y)) / 2)
        let hx = cos(rad) * len / 2, hy = sin(rad) * len / 2
        return (CGPoint(x: Double(mid.x) - hx, y: Double(mid.y) - hy), CGPoint(x: Double(mid.x) + hx, y: Double(mid.y) + hy))
    }

    // MARK: - Geometry helpers

    static func dedupe(_ points: [CGPoint]) -> [CGPoint] {
        var out: [CGPoint] = []
        out.reserveCapacity(points.count)
        for p in points where p.x.isFinite && p.y.isFinite {
            if let last = out.last, distance(last, p) < 0.5 { continue }
            out.append(p)
        }
        return out
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(a.x - b.x), dy = Double(a.y - b.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    static func pathLength(_ pts: [CGPoint]) -> Double {
        guard pts.count > 1 else { return 0 }
        var total = 0.0
        for i in 1 ..< pts.count { total += distance(pts[i - 1], pts[i]) }
        return total
    }

    public static func boundingBox(_ pts: [CGPoint]) -> CGRect {
        guard let first = pts.first else { return .null }
        var minX = Double(first.x), maxX = Double(first.x), minY = Double(first.y), maxY = Double(first.y)
        for p in pts {
            minX = min(minX, Double(p.x)); maxX = max(maxX, Double(p.x))
            minY = min(minY, Double(p.y)); maxY = max(maxY, Double(p.y))
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func mean(_ pts: [CGPoint]) -> CGPoint {
        guard !pts.isEmpty else { return .zero }
        var sx = 0.0, sy = 0.0
        for p in pts { sx += Double(p.x); sy += Double(p.y) }
        return CGPoint(x: sx / Double(pts.count), y: sy / Double(pts.count))
    }

    static func perpendicularDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return distance(p, a) }
        return abs(dy * Double(p.x - a.x) - dx * Double(p.y - a.y)) / len2.squareRoot()
    }

    static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return distance(p, a) }
        var t = (Double(p.x - a.x) * dx + Double(p.y - a.y) * dy) / len2
        t = min(1, max(0, t))
        return distance(p, CGPoint(x: Double(a.x) + t * dx, y: Double(a.y) + t * dy))
    }

    static func meanDistance(_ pts: [CGPoint], toPolyline poly: [CGPoint], closed: Bool) -> Double {
        guard poly.count >= 2, !pts.isEmpty else { return .infinity }
        var segments: [(CGPoint, CGPoint)] = []
        for i in 0 ..< poly.count - 1 { segments.append((poly[i], poly[i + 1])) }
        if closed { segments.append((poly[poly.count - 1], poly[0])) }
        var total = 0.0
        for p in pts {
            var best = Double.infinity
            for (a, b) in segments { best = min(best, segmentDistance(p, a, b)) }
            total += best
        }
        return total / Double(pts.count)
    }

    /// Angle at `b` in degrees (180 = straight).
    static func interiorAngle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Double {
        let v1 = (Double(a.x - b.x), Double(a.y - b.y))
        let v2 = (Double(c.x - b.x), Double(c.y - b.y))
        let l1 = (v1.0 * v1.0 + v1.1 * v1.1).squareRoot(), l2 = (v2.0 * v2.0 + v2.1 * v2.1).squareRoot()
        guard l1 > 0, l2 > 0 else { return 180 }
        let cosv = max(-1, min(1, (v1.0 * v2.0 + v1.1 * v2.1) / (l1 * l2)))
        return acos(cosv) * 180 / Double.pi
    }

    static func signedArea(_ poly: [CGPoint]) -> Double {
        var area = 0.0
        for i in 0 ..< poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            area += Double(a.x) * Double(b.y) - Double(b.x) * Double(a.y)
        }
        return area / 2
    }

    /// Ramer-Douglas-Peucker simplification (iterative to avoid deep recursion).
    public static func rdp(_ pts: [CGPoint], epsilon: Double) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack: [(Int, Int)] = [(0, pts.count - 1)]
        while let (s, e) = stack.popLast() {
            guard e > s + 1 else { continue }
            var maxD = 0.0
            var idx = s
            for i in (s + 1) ..< e {
                let d = perpendicularDistance(pts[i], pts[s], pts[e])
                if d > maxD {
                    maxD = d
                    idx = i
                }
            }
            if maxD > epsilon {
                keep[idx] = true
                stack.append((s, idx))
                stack.append((idx, e))
            }
        }
        return pts.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    /// Resamples a polyline into `count` points evenly spaced by arc length.
    static func resample(_ pts: [CGPoint], count: Int) -> [CGPoint] {
        guard pts.count > 1, count > 1 else { return pts }
        let total = pathLength(pts)
        guard total > 0 else { return pts }
        let step = total / Double(count - 1)
        var out: [CGPoint] = [pts[0]]
        var acc = 0.0
        var prev = pts[0]
        var i = 1
        while i < pts.count, out.count < count {
            let cur = pts[i]
            let d = distance(prev, cur)
            if acc + d >= step, d > 0 {
                let t = (step - acc) / d
                let p = CGPoint(x: Double(prev.x) + t * Double(cur.x - prev.x), y: Double(prev.y) + t * Double(cur.y - prev.y))
                out.append(p)
                prev = p
                acc = 0
            } else {
                acc += d
                prev = cur
                i += 1
            }
        }
        while out.count < count { out.append(pts[pts.count - 1]) }
        return out
    }

    /// Points along straight segments, repeating vertices so corners stay sharp.
    static func sample(segments vertices: [CGPoint], spacing: Double, closed: Bool) -> [CGPoint] {
        guard vertices.count >= 2 else { return vertices }
        var chain = vertices
        if closed { chain.append(vertices[0]) }
        var out: [CGPoint] = []
        for i in 0 ..< chain.count - 1 {
            let a = chain[i], b = chain[i + 1]
            let len = distance(a, b)
            let n = max(1, Int(len / spacing))
            // Corner: repeat so the spline passes through it.
            out.append(a); out.append(a); out.append(a)
            for k in 1 ..< n {
                let t = Double(k) / Double(n)
                out.append(CGPoint(x: Double(a.x) + t * Double(b.x - a.x), y: Double(a.y) + t * Double(b.y - a.y)))
            }
        }
        let end = chain[chain.count - 1]
        out.append(end); out.append(end); out.append(end)
        if closed, chain.count > 2 {
            // Run a little past the start so the closing corner joins cleanly.
            let a = chain[0], b = chain[1]
            let len = distance(a, b)
            if len > 0 {
                let t = min(1, spacing * 2 / len)
                out.append(CGPoint(x: Double(a.x) + t * Double(b.x - a.x), y: Double(a.y) + t * Double(b.y - a.y)))
            }
        }
        return out
    }
}
