import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Lays pages out top to bottom in one continuous "document space" (points),
/// each page centered horizontally.
public struct DocumentLayout: Equatable, Sendable {
    public static let pageGap: Double = 28
    public static let topPadding: Double = 28
    public static let sidePadding: Double = 28
    /// Space below the last page (holds the "add page" button).
    public static let bottomPadding: Double = 150

    public private(set) var pageFrames: [CGRect]
    public private(set) var contentSize: CGSize

    public init(pageSizes: [CGSize]) {
        let maxWidth = pageSizes.map(\.width).max() ?? 595
        let width = maxWidth + DocumentLayout.sidePadding * 2
        var y = DocumentLayout.topPadding
        var frames: [CGRect] = []
        frames.reserveCapacity(pageSizes.count)
        for size in pageSizes {
            let x = (width - size.width) / 2
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            y += size.height + DocumentLayout.pageGap
        }
        if !pageSizes.isEmpty { y -= DocumentLayout.pageGap }
        pageFrames = frames
        contentSize = CGSize(width: width, height: y + DocumentLayout.bottomPadding)
    }

    public var pageCount: Int { pageFrames.count }

    public func frame(of index: Int) -> CGRect? {
        pageFrames.indices.contains(index) ? pageFrames[index] : nil
    }

    /// The page that owns a point, splitting each gap halfway between pages.
    /// Points above the first page belong to it; below the last, to the last.
    public func pageIndex(forY y: Double) -> Int? {
        guard !pageFrames.isEmpty else { return nil }
        var lo = 0, hi = pageFrames.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            let boundary = pageFrames[mid].maxY + DocumentLayout.pageGap / 2
            if y < boundary { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }

    /// Page whose rectangle contains the point, if any.
    public func pageIndex(containing point: CGPoint) -> Int? {
        guard let i = pageIndex(forY: point.y) else { return nil }
        return pageFrames[i].contains(point) ? i : nil
    }

    /// Indices of pages intersecting a rectangle.
    public func pages(intersecting rect: CGRect) -> Range<Int> {
        guard !pageFrames.isEmpty, !rect.isNull, !rect.isInfinite else { return 0 ..< 0 }
        guard let first = pageIndex(forY: rect.minY), let last = pageIndex(forY: rect.maxY) else { return 0 ..< 0 }
        var lo = first, hi = last
        while lo <= hi, !pageFrames[lo].intersects(rect) { lo += 1 }
        while hi >= lo, !pageFrames[hi].intersects(rect) { hi -= 1 }
        return lo <= hi ? lo ..< (hi + 1) : 0 ..< 0
    }

    /// The page that occupies most of a viewport (used for "page 3 of 12").
    public func dominantPage(in viewport: CGRect) -> Int? {
        let range = pages(intersecting: viewport)
        guard !range.isEmpty else { return pageIndex(forY: viewport.midY) }
        var best = range.lowerBound
        var bestArea = -1.0
        for i in range {
            let inter = pageFrames[i].intersection(viewport)
            let area = inter.isNull ? 0 : inter.width * inter.height
            // Prefer the page that fills more of the screen; ties go to the upper page.
            if area > bestArea + 1 {
                best = i
                bestArea = area
            }
        }
        return best
    }
}
