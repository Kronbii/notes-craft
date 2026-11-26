import Foundation
import NotesCraftCore
import PDFKit

nonisolated struct PDFImportInfo: Sendable {
    var pageSizes: [CGSize]
    var title: String?
}

nonisolated enum PDFImporter {
    /// Copies a PDF into the library (removing password protection if a password
    /// is given) and reads its page sizes.
    @concurrent
    static func importFile(from source: URL, to dest: URL, password: String?) async throws -> PDFImportInfo {
        guard let document = PDFDocument(url: source) else {
            throw LibraryError.unreadableFile(source.lastPathComponent)
        }
        let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        if document.isLocked {
            guard let password else { throw LibraryError.lockedPDF }
            guard document.unlock(withPassword: password) else { throw LibraryError.wrongPassword }
            guard document.write(to: dest) else { throw LibraryError.unreadableFile(source.lastPathComponent) }
        } else {
            try FileManager.default.copyItem(at: source, to: dest)
        }
        let sizes = try pageSizes(of: dest)
        guard !sizes.isEmpty else {
            try? FileManager.default.removeItem(at: dest)
            throw LibraryError.emptyPDF
        }
        return PDFImportInfo(pageSizes: sizes, title: title?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Page sizes in points, honoring the crop box and page rotation.
    static func pageSizes(of url: URL) throws -> [CGSize] {
        guard let doc = CGPDFDocument(url as CFURL) else { throw LibraryError.unreadableFile(url.lastPathComponent) }
        guard doc.isUnlocked else { throw LibraryError.lockedPDF }
        var sizes: [CGSize] = []
        sizes.reserveCapacity(doc.numberOfPages)
        guard doc.numberOfPages > 0 else { return [] }
        for i in 1 ... doc.numberOfPages {
            guard let page = doc.page(at: i) else { continue }
            let box = page.getBoxRect(.cropBox)
            let rotated = abs(page.rotationAngle) % 180 == 90
            var size = rotated ? CGSize(width: box.height, height: box.width) : box.size
            if size.width < 1 || size.height < 1 { size = CGSize(width: 612, height: 792) }
            sizes.append(size)
        }
        return sizes
    }

    /// Extracts text for the given PDF page indices (0-based) keyed by our page IDs.
    @concurrent
    static func extractText(url: URL, pages: [Int: UUID]) async -> [UUID: String] {
        guard let doc = PDFDocument(url: url) else { return [:] }
        var out: [UUID: String] = [:]
        for (index, pageID) in pages {
            guard index >= 0, index < doc.pageCount, let page = doc.page(at: index) else { continue }
            if let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                out[pageID] = String(text.prefix(20000))
            }
        }
        return out
    }

    /// Rectangles (page-local, y-down) of every occurrence of `query` on one PDF page.
    @concurrent
    static func matchRects(url: URL, index: Int, query: String, pageSize: CGSize) async -> [CGRect] {
        guard let doc = PDFDocument(url: url), index >= 0, index < doc.pageCount, let page = doc.page(at: index) else { return [] }
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return [] }
        var rects: [CGRect] = []
        let box = page.bounds(for: .cropBox)
        for term in terms {
            for selection in doc.findString(term, withOptions: [.caseInsensitive, .diacriticInsensitive]) {
                guard selection.pages.contains(page) else { continue }
                let r = selection.bounds(for: page)
                // PDF space (y-up, relative to the crop box) to page space (y-down).
                rects.append(convert(r, box: box, rotation: page.rotation, pageSize: pageSize))
            }
            if rects.count > 200 { break }
        }
        return rects
    }

    static func convert(_ r: CGRect, box: CGRect, rotation: Int, pageSize: CGSize) -> CGRect {
        let x = r.minX - box.minX, y = r.minY - box.minY
        let local = CGRect(x: x, y: box.height - y - r.height, width: r.width, height: r.height)
        switch ((rotation % 360) + 360) % 360 {
        case 90:
            return CGRect(x: box.height - local.maxY, y: local.minX, width: local.height, height: local.width)
        case 180:
            return CGRect(x: box.width - local.maxX, y: box.height - local.maxY, width: local.width, height: local.height)
        case 270:
            return CGRect(x: local.minY, y: box.width - local.maxX, width: local.height, height: local.width)
        default:
            return local
        }
    }
}

nonisolated struct OutlineItem: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var depth: Int
    /// 0-based page index inside the PDF asset.
    var pdfPage: Int
    var asset: String
}

extension PDFImporter {
    /// Table of contents of every PDF in the notebook, in reading order.
    @concurrent
    static func outline(assets: [(name: String, url: URL)]) async -> [OutlineItem] {
        var items: [OutlineItem] = []
        for (name, url) in assets {
            guard let doc = PDFDocument(url: url), let root = doc.outlineRoot else { continue }
            func walk(_ node: PDFOutline, depth: Int) {
                for i in 0 ..< node.numberOfChildren {
                    guard let child = node.child(at: i) else { continue }
                    if let label = child.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty,
                       let page = child.destination?.page ?? (child.action as? PDFActionGoTo)?.destination.page {
                        items.append(OutlineItem(title: label, depth: depth, pdfPage: doc.index(for: page), asset: name))
                    }
                    if items.count < 2000 { walk(child, depth: depth + 1) }
                }
            }
            walk(root, depth: 0)
        }
        return items
    }
}
