import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Recognizes a "scribble out" gesture: a stroke that sweeps back and forth
/// several times over a compact area (GoodNotes-style scribble to erase).
public enum ScribbleDetector {
    /// Screen speed (points per second) above which a stroke counts as a quick
    /// scribble rather than handwriting.
    public static let fastSpeed = 600.0

    /// - Parameters:
    ///   - raw: stroke points in document space.
    ///   - duration: how long the stroke took, if known.
    ///   - viewScale: screen points per document point (the zoom).
    public static func isScribble(_ raw: [CGPoint], duration: Double? = nil, viewScale: Double = 1) -> Bool {
        let pts = ShapeRecognizer.dedupe(raw)
        guard pts.count >= 16 else { return false }
        let box = ShapeRecognizer.boundingBox(pts)
        let diag = (Double(box.width) * Double(box.width) + Double(box.height) * Double(box.height)).squareRoot()
        guard diag * viewScale >= 15 else { return false }
        let length = ShapeRecognizer.pathLength(pts)
        // A scribble covers a lot of ink for its size.
        guard length > 3.2 * diag else { return false }
        let fast = duration.map { $0 > 0 && length * viewScale / $0 >= fastSpeed } ?? false
        let axes = sweeps(pts)
        // Back and forth along the scribble's long side (over a word): a slow
        // one needs more sweeps and must be clearly longer than it is tall,
        // so letters like "m" never count.
        if axes.main >= 5, axes.elongation >= 1.6 { return true }
        if fast, axes.main >= 4 { return true }
        // A quick zig-zag that travels along a word.
        if fast, axes.cross >= 6 { return true }
        return false
    }

    /// Direction reversals along the stroke's main axis and across it, ignoring
    /// wiggles smaller than a third of the extent (handwriting backtracks).
    static func sweeps(_ pts: [CGPoint]) -> (main: Int, cross: Int, elongation: Double) {
        let c = ShapeRecognizer.mean(pts)
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in pts {
            let dx = Double(p.x - c.x), dy = Double(p.y - c.y)
            sxx += dx * dx; syy += dy * dy; sxy += dx * dy
        }
        let theta = 0.5 * atan2(2 * sxy, sxx - syy)
        let ux = cos(theta), uy = sin(theta)
        let main = pts.map { Double($0.x) * ux + Double($0.y) * uy }
        let cross = pts.map { -Double($0.x) * uy + Double($0.y) * ux }
        let mainExtent = (main.max() ?? 0) - (main.min() ?? 0)
        let crossExtent = (cross.max() ?? 0) - (cross.min() ?? 0)
        return (reversals(main), reversals(cross), mainExtent / max(crossExtent, 1))
    }

    static func reversals(_ s: [Double]) -> Int {
        guard let lo = s.min(), let hi = s.max() else { return 0 }
        let extent = hi - lo
        guard extent > 8 else { return 0 }
        let threshold = 0.35 * extent
        var count = 0
        var direction = 0 // +1 increasing, -1 decreasing
        var extreme = s[0]
        for v in s.dropFirst() {
            switch direction {
            case 0:
                if v - extreme > threshold { direction = 1; extreme = v } else if extreme - v > threshold { direction = -1; extreme = v }
            case 1:
                if v > extreme { extreme = v } else if extreme - v > threshold { count += 1; direction = -1; extreme = v }
            default:
                if v < extreme { extreme = v } else if v - extreme > threshold { count += 1; direction = 1; extreme = v }
            }
        }
        return count
    }

    /// Convex hull (counter-clockwise), used as the area to erase.
    public static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let pts = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard pts.count > 2 else { return pts }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
            Double(a.x - o.x) * Double(b.y - o.y) - Double(a.y - o.y) * Double(b.x - o.x)
        }
        var lower: [CGPoint] = []
        for p in pts {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in pts.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Point-in-polygon (even-odd).
    public static func contains(_ poly: [CGPoint], _ p: CGPoint) -> Bool {
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

    /// The hull grown outward by `margin` (approximate, about its centroid).
    public static func expanded(_ hull: [CGPoint], by margin: Double) -> [CGPoint] {
        guard hull.count >= 3 else { return hull }
        let c = ShapeRecognizer.mean(hull)
        return hull.map { p in
            let dx = Double(p.x - c.x), dy = Double(p.y - c.y)
            let d = max((dx * dx + dy * dy).squareRoot(), 0.001)
            return CGPoint(x: Double(p.x) + dx / d * margin, y: Double(p.y) + dy / d * margin)
        }
    }
}
