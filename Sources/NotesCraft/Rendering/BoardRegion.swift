import Foundation
import NotesCraftCore
import PencilKit
import UIKit

/// A whiteboard is one very large page that grows as you go. Anything that renders a page on its own
/// (covers, exports, handwriting recognition) renders just the area around what
/// is drawn on it, as if that area were a normal page.
nonisolated enum BoardRegion {
    /// Bounding box of the ink and items on a page, if any (page coordinates).
    static func contentRect(page: Page, drawing: PKDrawing) -> CGRect? {
        var rect = CGRect.null
        if !drawing.strokes.isEmpty { rect = drawing.bounds }
        for element in page.elements { rect = rect.union(element.frame) }
        return rect.isNull ? nil : rect
    }

    /// The part of a page to render: the whole page, or for a whiteboard the drawn
    /// area plus a margin, widened to `aspect` (width / height) if given.
    static func renderRect(page: Page, drawing: PKDrawing, aspect: CGFloat? = nil, margin: CGFloat = 48) -> CGRect {
        let bounds = CGRect(origin: .zero, size: page.size)
        guard page.isBoard else { return bounds }
        var rect = contentRect(page: page, drawing: drawing)?.insetBy(dx: -margin, dy: -margin)
            ?? CGRect(x: bounds.midX - 400, y: bounds.midY - 300, width: 800, height: 600)
        // Not too small: a few words shouldn't become a giant close-up.
        if rect.width < 600 { rect = rect.insetBy(dx: -(600 - rect.width) / 2, dy: 0) }
        if rect.height < 450 { rect = rect.insetBy(dx: 0, dy: -(450 - rect.height) / 2) }
        if let aspect, aspect > 0 {
            if rect.width / rect.height < aspect {
                rect = rect.insetBy(dx: -(rect.height * aspect - rect.width) / 2, dy: 0)
            } else {
                rect = rect.insetBy(dx: 0, dy: -(rect.width / aspect - rect.height) / 2)
            }
        }
        // Start on a whole pattern repeat, so a cover's dots line up with the board's.
        let snapX = rect.minX - (rect.minX / 50).rounded(.down) * 50
        let snapY = rect.minY - (rect.minY / 50).rounded(.down) * 50
        rect = CGRect(x: rect.minX - snapX, y: rect.minY - snapY, width: rect.width + snapX, height: rect.height + snapY)
        // Keep it on the board.
        rect.size.width = min(rect.width, bounds.width)
        rect.size.height = min(rect.height, bounds.height)
        rect.origin.x = min(max(rect.minX, 0), bounds.width - rect.width)
        rect.origin.y = min(max(rect.minY, 0), bounds.height - rect.height)
        return rect.integral
    }

    /// A stand-alone page showing `rect` of `page`, with its ink moved along.
    static func crop(page: Page, drawing: PKDrawing, to rect: CGRect) -> (page: Page, drawing: PKDrawing) {
        guard rect != CGRect(origin: .zero, size: page.size) else { return (page, drawing) }
        var cropped = page
        cropped.size = rect.size
        cropped.isBoard = false
        cropped.elements = page.elements.map { element in
            var e = element
            e.frame = e.frame.offsetBy(dx: -rect.minX, dy: -rect.minY)
            return e
        }
        cropped.recognition = nil
        let moved = drawing.transformed(using: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        return (cropped, moved)
    }

    /// The page as it should be rendered on its own (unchanged unless it is a whiteboard).
    static func prepared(page: Page, drawing: PKDrawing, aspect: CGFloat? = nil) -> (page: Page, drawing: PKDrawing) {
        guard page.isBoard else { return (page, drawing) }
        return crop(page: page, drawing: drawing, to: renderRect(page: page, drawing: drawing, aspect: aspect))
    }
}
