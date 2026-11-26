import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

public enum LibrarySort: String, Codable, CaseIterable, Sendable, Identifiable {
    case modified
    case created
    case opened
    case title

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .modified: "Date modified"
        case .created: "Date created"
        case .opened: "Last opened"
        case .title: "Name"
        }
    }
}

/// The library catalog: folders and notebook metadata. Pure value type so the
/// tree logic can be tested without any UI.
public struct LibraryIndex: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var folders: [Folder]
    public var notebooks: [NotebookMeta]

    public init(folders: [Folder] = [], notebooks: [NotebookMeta] = []) {
        self.version = LibraryIndex.currentVersion
        self.folders = folders
        self.notebooks = notebooks
    }

    enum CodingKeys: String, CodingKey { case version, folders, notebooks }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        folders = (try? c.decodeIfPresent([Folder].self, forKey: .folders)) ?? []
        notebooks = (try? c.decodeIfPresent([NotebookMeta].self, forKey: .notebooks)) ?? []
    }

    // MARK: Lookup

    public func folder(_ id: UUID?) -> Folder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    public func notebook(_ id: UUID) -> NotebookMeta? {
        notebooks.first { $0.id == id }
    }

    public func subfolders(of parent: UUID?) -> [Folder] {
        folders
            .filter { $0.parentID == parent }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The folder and all folders below it.
    public func descendantFolderIDs(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var frontier = [id]
        while let next = frontier.popLast() {
            for f in folders where f.parentID == next && !result.contains(f.id) {
                result.insert(f.id)
                frontier.append(f.id)
            }
        }
        return result
    }

    /// Folder names from the root down to the folder.
    public func path(to id: UUID?) -> [Folder] {
        var chain: [Folder] = []
        var current = folder(id)
        var guardCount = 0
        while let f = current, guardCount < 64 {
            chain.insert(f, at: 0)
            current = folder(f.parentID)
            guardCount += 1
        }
        return chain
    }

    public func notebooks(in folderID: UUID?, includeTrashed: Bool = false) -> [NotebookMeta] {
        notebooks.filter { $0.folderID == folderID && (includeTrashed || !$0.isTrashed) }
    }

    public var activeNotebooks: [NotebookMeta] { notebooks.filter { !$0.isTrashed } }

    public var trashedNotebooks: [NotebookMeta] {
        notebooks.filter(\.isTrashed).sorted { ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast) }
    }

    /// Number of live notebooks in a folder and everything below it.
    public func notebookCount(inTree id: UUID) -> Int {
        let ids = descendantFolderIDs(of: id)
        return notebooks.filter { !$0.isTrashed && $0.folderID.map(ids.contains) == true }.count
    }

    // MARK: Moving folders

    /// Whether `folder` may be moved into `newParent` (no cycles).
    public func canMove(folder id: UUID, to newParent: UUID?) -> Bool {
        guard let newParent else { return true }
        return !descendantFolderIDs(of: id).contains(newParent)
    }

    // MARK: Repair

    /// Fixes references to folders that no longer exist and breaks folder cycles.
    public mutating func repair() {
        let ids = Set(folders.map(\.id))
        for i in notebooks.indices {
            if let f = notebooks[i].folderID, !ids.contains(f) { notebooks[i].folderID = nil }
        }
        for i in folders.indices {
            if let p = folders[i].parentID, !ids.contains(p) || p == folders[i].id { folders[i].parentID = nil }
        }
        // Break cycles: walk up from each folder; if we revisit, detach.
        for i in folders.indices {
            var seen: Set<UUID> = [folders[i].id]
            var current = folders[i].parentID
            while let c = current {
                if seen.contains(c) {
                    folders[i].parentID = nil
                    break
                }
                seen.insert(c)
                current = folder(c)?.parentID
            }
        }
        // Drop duplicate notebook entries, keeping the most recently modified.
        var best: [UUID: NotebookMeta] = [:]
        for nb in notebooks {
            if let existing = best[nb.id], existing.modifiedAt >= nb.modifiedAt { continue }
            best[nb.id] = nb
        }
        if best.count != notebooks.count {
            notebooks = notebooks.compactMap { nb in
                guard let keep = best[nb.id] else { return nil }
                best[nb.id] = nil
                return keep
            }
        }
    }
}

// MARK: - Sorting and search

public enum LibraryLogic {
    public static func sorted(_ notebooks: [NotebookMeta], by sort: LibrarySort) -> [NotebookMeta] {
        notebooks.sorted { a, b in
            switch sort {
            case .modified:
                if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
            case .created:
                if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
            case .opened:
                let ao = a.openedAt ?? a.modifiedAt, bo = b.openedAt ?? b.modifiedAt
                if ao != bo { return ao > bo }
            case .title:
                let r = a.title.localizedStandardCompare(b.title)
                if r != .orderedSame { return r == .orderedAscending }
            }
            return a.id.uuidString < b.id.uuidString
        }
    }

    /// Lowercased, diacritic-free form used for matching.
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// All search terms must appear in the text (in any order).
    public static func matches(_ text: String, query: String) -> Bool {
        let terms = fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return false }
        let hay = fold(text)
        return terms.allSatisfy { hay.contains($0) }
    }

    /// A short excerpt around the first match of the first term, on one line.
    public static func snippet(of text: String, query: String, radius: Int = 48) -> String? {
        let terms = fold(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = terms.first else { return nil }
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        let folded = fold(flat)
        // Folding can change lengths for some scripts; fall back to the start.
        guard folded.count == flat.count, let range = folded.range(of: first) else {
            return flat.isEmpty ? nil : String(flat.prefix(radius * 2))
        }
        let startOffset = folded.distance(from: folded.startIndex, to: range.lowerBound)
        let lo = max(0, startOffset - radius)
        let hi = min(flat.count, startOffset + first.count + radius)
        let s = flat.index(flat.startIndex, offsetBy: lo)
        let e = flat.index(flat.startIndex, offsetBy: hi)
        var out = String(flat[s ..< e]).trimmingCharacters(in: .whitespaces)
        if lo > 0 { out = "…" + out }
        if hi < flat.count { out += "…" }
        return out
    }

    /// "Untitled", "Untitled 2", ... avoiding names already used.
    public static func uniqueTitle(_ base: String, existing: [String]) -> String {
        let taken = Set(existing.map { fold($0) })
        if !taken.contains(fold(base)) { return base }
        var n = 2
        while taken.contains(fold("\(base) \(n)")) { n += 1 }
        return "\(base) \(n)"
    }

    /// Strips characters that are invalid in file names, for exports.
    public static func fileSafeName(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.newlines).union(.controlCharacters)
        let cleaned = title.unicodeScalars.map { invalid.contains($0) ? "-" : String($0) }.joined()
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return trimmed.isEmpty ? "Notebook" : String(trimmed.prefix(120))
    }
}
