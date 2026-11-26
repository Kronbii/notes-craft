import Foundation
import NotesCraftCore

/// Searchable text for one page: typed text boxes, PDF text and recognized handwriting.
struct PageSearchText: Codable, Hashable {
    var pageID: UUID
    var typed: String = ""
    var pdf: String = ""
    var ink: String = ""

    var combined: String { [typed, pdf, ink].filter { !$0.isEmpty }.joined(separator: "\n") }
}

struct NotebookSearchText: Codable, Hashable {
    var pages: [PageSearchText]
}

enum SearchSource: String {
    case title, typed, pdf, handwriting

    var label: String {
        switch self {
        case .title: "Title"
        case .typed: "Text"
        case .pdf: "PDF"
        case .handwriting: "Handwriting"
        }
    }

    var symbol: String {
        switch self {
        case .title: "textformat"
        case .typed: "character.cursor.ibeam"
        case .pdf: "doc.richtext"
        case .handwriting: "pencil.and.scribble"
        }
    }
}

struct SearchHit: Identifiable, Hashable {
    var id: String { "\(notebookID)-\(pageIndex ?? -1)-\(source.rawValue)" }
    var notebookID: UUID
    var pageIndex: Int?
    var source: SearchSource
    var before: String
    var match: String
    var after: String

    var snippet: String { before + match + after }
}

/// Library-wide full-text index, persisted to search.json.
@Observable
final class SearchIndex {
    private(set) var entries: [UUID: NotebookSearchText] = [:]
    @ObservationIgnored private var saveScheduled = false

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: StoragePaths.searchIndex) else { return }
        if let decoded = try? Coders.decoder().decode([UUID: NotebookSearchText].self, from: data) {
            entries = decoded
        }
    }

    func entry(for id: UUID) -> NotebookSearchText? { entries[id] }

    func set(_ entry: NotebookSearchText?, for id: UUID) {
        if entries[id] == entry { return }
        entries[id] = entry
        scheduleSave()
    }

    func remove(_ id: UUID) {
        guard entries[id] != nil else { return }
        entries[id] = nil
        scheduleSave()
    }

    /// Updates PDF text for some pages (used after background extraction).
    func setPDFText(_ texts: [UUID: String], notebook id: UUID, pageOrder: [UUID]) {
        var entry = entries[id] ?? NotebookSearchText(pages: [])
        var byID = Dictionary(entry.pages.map { ($0.pageID, $0) }, uniquingKeysWith: { first, _ in first })
        for (pageID, text) in texts {
            var page = byID[pageID] ?? PageSearchText(pageID: pageID)
            page.pdf = text
            byID[pageID] = page
        }
        entry.pages = pageOrder.map { byID[$0] ?? PageSearchText(pageID: $0) }
        set(entry, for: id)
    }

    /// Every notebook whose title or text contains all the search words, with
    /// one snippet per page and source. The match is split out for highlighting.
    func search(_ query: String, in notebooks: [NotebookMeta]) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let phrase = SearchMatching.regex(for: q)
        let firstWord = q.split(whereSeparator: { $0.isWhitespace }).first.map(String.init).flatMap { SearchMatching.regex(for: $0) }

        func hit(_ text: String) -> (String, String, String)? {
            guard LibraryLogic.matches(text, query: q) else { return nil }
            for regex in [phrase, firstWord].compactMap({ $0 }) {
                if let range = SearchMatching.ranges(of: regex, in: text, limit: 1).first {
                    return SearchMatching.snippet(text, range: range)
                }
            }
            return ("", String(text.prefix(80)), "")
        }

        var hits: [SearchHit] = []
        for nb in notebooks {
            if let (b, m, a) = hit(nb.title) {
                hits.append(SearchHit(notebookID: nb.id, pageIndex: nil, source: .title, before: b, match: m, after: a))
            }
            guard let entry = entries[nb.id] else { continue }
            var perNotebook = 0
            for (i, page) in entry.pages.enumerated() where perNotebook < 20 {
                for (source, text) in [(SearchSource.typed, page.typed), (.pdf, page.pdf), (.handwriting, page.ink)] where !text.isEmpty {
                    if let (b, m, a) = hit(text) {
                        hits.append(SearchHit(notebookID: nb.id, pageIndex: i, source: source, before: b, match: m, after: a))
                        perNotebook += 1
                        break
                    }
                }
            }
        }
        return hits
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.saveScheduled = false
                self.saveNow()
            }
        }
    }

    func saveNow() {
        guard let data = try? Coders.encoder().encode(entries) else { return }
        DiskWriter.shared.write(data, to: StoragePaths.searchIndex)
    }
}
