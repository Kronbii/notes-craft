import Foundation
import NotesCraftCore
import PDFKit
import UIKit

/// One occurrence of the search text in a notebook.
nonisolated struct FindResult: Identifiable, Hashable, Sendable {
    var id: String { "\(pageID)-\(source.rawValue)-\(order)" }
    var pageIndex: Int
    var pageID: UUID
    var source: SearchSource
    /// Text around the match, split so the match can be emphasized.
    var before: String
    var match: String
    var after: String
    /// Page-local rectangle of the match, when known.
    var rect: CGRect?
    /// Position within the page, for ordering.
    var order: Int

    var snippet: String { before + match + after }
}

nonisolated enum SearchMatching {
    /// A case-insensitive pattern for the query in which any run of whitespace
    /// matches any whitespace (PDF text breaks lines between words).
    static func regex(for query: String) -> NSRegularExpression? {
        let words = query.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: words.joined(separator: "\\s+"), options: [.caseInsensitive])
    }

    static func ranges(of regex: NSRegularExpression, in text: String, limit: Int = 500) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, stop in
            if let m, m.range.length > 0 { out.append(m.range) }
            if out.count >= limit { stop.pointee = true }
        }
        return out
    }

    /// Context around a match, on one line, with the match separated out.
    static func snippet(_ text: String, range: NSRange, radius: Int = 42) -> (String, String, String) {
        let ns = text as NSString
        let lo = max(0, range.location - radius)
        let end = range.location + range.length
        let hi = min(ns.length, end + radius)
        func collapse(_ s: String) -> String {
            s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        }
        var before = collapse(ns.substring(with: NSRange(location: lo, length: range.location - lo)))
        let match = collapse(ns.substring(with: range))
        var after = collapse(ns.substring(with: NSRange(location: end, length: hi - end)))
        if lo > 0 {
            // Start at a word boundary.
            if let space = before.firstIndex(of: " ") { before = String(before[before.index(after: space)...]) }
            before = "…" + before
        }
        if hi < ns.length {
            if let space = after.lastIndex(of: " "), space != after.startIndex { after = String(after[..<space]) }
            after += "…"
        }
        return (before, match, after)
    }
}

/// Searches PDF pages. Each PDF is opened once per notebook and its page text
/// cached, so typing a query stays fast even for long textbooks.
actor PDFTextSearcher {
    struct PageRef: Sendable {
        var pageIndex: Int
        var pageID: UUID
        var asset: String
        var pdfIndex: Int
        var pageSize: CGSize
    }

    private let folder: URL
    private var documents: [String: PDFDocument] = [:]
    private var texts: [String: String] = [:]

    init(folder: URL) {
        self.folder = folder
    }

    private func document(_ asset: String) -> PDFDocument? {
        if let d = documents[asset] { return d }
        guard let d = PDFDocument(url: folder.appendingPathComponent(asset)) else { return nil }
        documents[asset] = d
        return d
    }

    func search(_ query: String, pages: [PageRef]) -> [FindResult] {
        guard let regex = SearchMatching.regex(for: query) else { return [] }
        var results: [FindResult] = []
        for ref in pages {
            if Task.isCancelled { return results }
            guard let doc = document(ref.asset), ref.pdfIndex < doc.pageCount, let page = doc.page(at: ref.pdfIndex) else { continue }
            let key = "\(ref.asset)#\(ref.pdfIndex)"
            let text: String
            if let cached = texts[key] {
                text = cached
            } else {
                text = page.string ?? ""
                texts[key] = text
            }
            guard !text.isEmpty else { continue }
            let box = page.bounds(for: .cropBox)
            for (n, range) in SearchMatching.ranges(of: regex, in: text).enumerated() {
                var rect: CGRect?
                if let selection = page.selection(for: range) {
                    let r = selection.bounds(for: page)
                    if !r.isNull, r.width > 0 {
                        rect = PDFImporter.convert(r, box: box, rotation: page.rotation, pageSize: ref.pageSize)
                    }
                }
                let (b, m, a) = SearchMatching.snippet(text, range: range)
                results.append(FindResult(pageIndex: ref.pageIndex, pageID: ref.pageID, source: .pdf, before: b, match: m, after: a,
                                          rect: rect, order: Int((rect?.minY ?? 0) * 10) * 1000 + n))
            }
        }
        return results
    }
}

/// Matches in typed text boxes and recognized handwriting (in memory, fast).
nonisolated enum InlineSearcher {
    static func search(_ query: String, pages: [Page]) -> [FindResult] {
        guard let regex = SearchMatching.regex(for: query) else { return [] }
        var results: [FindResult] = []
        for (i, page) in pages.enumerated() {
            for element in page.elements {
                guard let content = element.textContent else { continue }
                let text = content.plainText
                for (n, range) in SearchMatching.ranges(of: regex, in: text).enumerated() {
                    let (b, m, a) = SearchMatching.snippet(text, range: range)
                    let rect = textRect(content, range: range, frame: element.frame) ?? element.frame
                    results.append(FindResult(pageIndex: i, pageID: page.id, source: .typed, before: b, match: m, after: a,
                                              rect: rect, order: Int(rect.minY * 10) * 1000 + n))
                }
            }
            for (li, line) in (page.recognition?.lines ?? []).enumerated() {
                for (n, range) in SearchMatching.ranges(of: regex, in: line.text).enumerated() {
                    let (b, m, a) = SearchMatching.snippet(line.text, range: range)
                    // Narrow the line to the matched characters (proportionally).
                    let len = max((line.text as NSString).length, 1)
                    let x0 = line.rect.minX + line.rect.width * CGFloat(range.location) / CGFloat(len)
                    let w = max(line.rect.width * CGFloat(range.length) / CGFloat(len), 12)
                    let rect = CGRect(x: x0, y: line.rect.minY, width: w, height: line.rect.height).insetBy(dx: -4, dy: -2)
                    results.append(FindResult(pageIndex: i, pageID: page.id, source: .handwriting, before: b, match: m, after: a,
                                              rect: rect, order: Int(line.rect.minY * 10) * 1000 + li * 10 + n))
                }
            }
        }
        return results
    }

    /// Bounding rectangle of a character range inside a text box (page-local).
    static func textRect(_ content: TextContent, range: NSRange, frame: CGRect) -> CGRect? {
        let storage = NSTextStorage(attributedString: TextStyling.attributedString(content))
        guard range.location + range.length <= storage.length else { return nil }
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(frame.width - 2 * TextStyling.textInset, 10), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let r = manager.boundingRect(forGlyphRange: glyphs, in: container)
        guard !r.isNull, r.width > 0 else { return nil }
        return r.offsetBy(dx: frame.minX + TextStyling.textInset, dy: frame.minY + TextStyling.textInset).insetBy(dx: -2, dy: -1)
    }
}
