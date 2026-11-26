import Foundation
import NotesCraftCore
import Observation
import PencilKit
import UIKit

/// Lets values that are safe in practice (immutable snapshots) cross isolation.
nonisolated struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Deterministic FNV-1a hasher (Swift's Hasher is randomly seeded per launch).
nonisolated struct StableHasher {
    private var state: UInt64 = 0xCBF2_9CE4_8422_2325

    mutating func combine(_ value: UInt64) {
        var v = value
        for _ in 0 ..< 8 {
            state ^= v & 0xFF
            state = state &* 0x0000_0100_0000_01B3
            v >>= 8
        }
    }

    mutating func combine(_ value: Double) { combine(value.bitPattern) }
    mutating func combine(_ value: CGFloat) { combine(Double(value).bitPattern) }
    mutating func combine(_ value: Int) { combine(UInt64(bitPattern: Int64(value))) }

    var value: Int { Int(truncatingIfNeeded: state) }
}

nonisolated enum InkFingerprint {
    static func of(_ drawing: PKDrawing) -> Int {
        var h = StableHasher()
        h.combine(drawing.strokes.count)
        for s in drawing.strokes {
            let b = s.renderBounds
            h.combine((b.minX * 4).rounded())
            h.combine((b.minY * 4).rounded())
            h.combine((b.width * 4).rounded())
            h.combine((b.height * 4).rounded())
            h.combine(s.path.count)
            h.combine(s.path.creationDate.timeIntervalSinceReferenceDate)
            let c = s.ink.color.rgba
            h.combine((c.r * 255).rounded() * 65536 + (c.g * 255).rounded() * 256 + (c.b * 255).rounded())
            h.combine(s.mask == nil ? 0 : 1)
        }
        return h.value
    }
}

/// An open notebook: its content, per-page ink and assets, with crash-safe saving.
@Observable
final class NotebookDocument {
    let id: UUID
    var content: NotebookContent
    /// Bumped whenever a page's look changes, to refresh thumbnails.
    private(set) var pageVersions: [UUID: Int] = [:]

    @ObservationIgnored private(set) var drawings: [UUID: PKDrawing]
    @ObservationIgnored let assets: AssetStore
    @ObservationIgnored private var inkFingerprints: [UUID: Int] = [:]
    @ObservationIgnored private var dirtyInk: Set<UUID> = []
    @ObservationIgnored private var contentDirty = false
    @ObservationIgnored private var savedPageIDs: Set<UUID>
    @ObservationIgnored private var firstPageVersionAtLastThumbnail = -1

    private init(id: UUID, content: NotebookContent, drawings: [UUID: PKDrawing]) {
        self.id = id
        self.content = content
        self.drawings = drawings
        self.assets = AssetStore(folder: StoragePaths.assets(id))
        self.savedPageIDs = Set(content.pages.map(\.id))
        for (pid, d) in drawings { inkFingerprints[pid] = InkFingerprint.of(d) }
    }

    // MARK: Loading

    struct LoadedFiles: Sendable {
        var content: NotebookContent
        var ink: [UUID: Data]
    }

    static func open(id: UUID) async throws -> NotebookDocument {
        await DiskWriter.shared.flush()
        let files = try await readFiles(id: id)
        var content = files.content
        if let meta = LibraryStore.shared.meta(id) { content.meta = meta }
        content.meta.id = id
        var drawings: [UUID: PKDrawing] = [:]
        var damaged = 0
        for (pageID, data) in files.ink {
            do {
                drawings[pageID] = try PKDrawing(data: data)
            } catch {
                damaged += 1
                log.error("ink for page \(pageID.uuidString, privacy: .public) unreadable")
            }
        }
        if content.pages.isEmpty {
            content.pages = [Page(style: AppSettings.shared.defaultPaper)]
        }
        let doc = NotebookDocument(id: id, content: content, drawings: drawings)
        if damaged > 0 {
            LibraryStore.shared.report("Ink on \(damaged) page\(damaged == 1 ? "" : "s") couldn't be read and was skipped.")
        }
        return doc
    }

    @concurrent
    private static func readFiles(id: UUID) async throws -> LoadedFiles {
        let docURL = StoragePaths.document(id)
        let data: Data
        do {
            data = try Data(contentsOf: docURL)
        } catch {
            throw LibraryError.notFound
        }
        let content = try Coders.decoder().decode(NotebookContent.self, from: data)
        var ink: [UUID: Data] = [:]
        for page in content.pages {
            let url = StoragePaths.ink(id, page: page.id)
            if let d = try? Data(contentsOf: url) { ink[page.id] = d }
        }
        return LoadedFiles(content: content, ink: ink)
    }

    // MARK: Access

    var pages: [Page] { content.pages }

    func drawing(for pageID: UUID) -> PKDrawing {
        drawings[pageID] ?? PKDrawing()
    }

    func pageIndex(of pageID: UUID) -> Int? {
        content.pages.firstIndex { $0.id == pageID }
    }

    func version(of pageID: UUID) -> Int { pageVersions[pageID, default: 0] }

    /// Stores a page's ink; returns true if it actually changed.
    @discardableResult
    func setDrawing(_ drawing: PKDrawing, for pageID: UUID) -> Bool {
        let fp = InkFingerprint.of(drawing)
        if inkFingerprints[pageID] == fp, drawings[pageID] != nil || drawing.strokes.isEmpty { return false }
        drawings[pageID] = drawing
        inkFingerprints[pageID] = fp
        dirtyInk.insert(pageID)
        bump(pageID)
        return true
    }

    func bump(_ pageID: UUID) {
        pageVersions[pageID, default: 0] += 1
    }

    func markContentChanged() {
        contentDirty = true
    }

    var hasUnsavedChanges: Bool { contentDirty || !dirtyInk.isEmpty }

    /// Replaces all pages and ink at once (page operations, undo).
    func replacePages(_ pages: [Page], drawings newDrawings: [UUID: PKDrawing]) {
        let oldIDs = Set(content.pages.map(\.id))
        content.pages = pages
        for page in pages {
            let d = newDrawings[page.id] ?? PKDrawing()
            setDrawing(d, for: page.id)
            if !oldIDs.contains(page.id) { dirtyInk.insert(page.id) }
        }
        let live = Set(pages.map(\.id))
        for key in drawings.keys where !live.contains(key) {
            drawings[key] = nil
            inkFingerprints[key] = nil
        }
        contentDirty = true
    }

    func updatePage(_ page: Page) {
        guard let i = pageIndex(of: page.id) else { return }
        if content.pages[i] != page {
            content.pages[i] = page
            contentDirty = true
            bump(page.id)
        }
    }

    // MARK: Assets

    /// Writes an asset file and returns its name. Done before inserting the element
    /// that references it, so nothing ever points at a missing file.
    func addAsset(data: Data, ext: String) async throws -> String {
        let name = UUID().uuidString + "." + ext
        let url = StoragePaths.assets(id).appendingPathComponent(name)
        try await Self.writeFile(data, to: url)
        return name
    }

    @concurrent
    private static func writeFile(_ data: Data, to url: URL) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: Saving

    /// Writes changed parts to disk. Cheap when nothing changed.
    func save(force: Bool = false) {
        guard force || hasUnsavedChanges else { return }
        let library = LibraryStore.shared
        if let meta = library.meta(id) { content.meta = meta }
        content.meta.pageCount = content.pages.count
        content.meta.recordingCount = content.recordings.count
        content.meta.modifiedAt = Date()

        let onError: @Sendable (Error) -> Void = { error in
            Task { @MainActor in
                LibraryStore.shared.report("Couldn't save your notebook: \(error.localizedDescription)")
            }
        }
        do {
            let data = try Coders.encoder().encode(content)
            DiskWriter.shared.write(data, to: StoragePaths.document(id), onError: onError)
        } catch {
            LibraryStore.shared.report("Couldn't save your notebook: \(error.localizedDescription)")
            return
        }
        let live = Set(content.pages.map(\.id))
        for pageID in dirtyInk where live.contains(pageID) {
            let drawing = drawings[pageID] ?? PKDrawing()
            DiskWriter.shared.write(drawing.dataRepresentation(), to: StoragePaths.ink(id, page: pageID), onError: onError)
        }
        // Remove ink files of deleted pages.
        for removed in savedPageIDs.subtracting(live) {
            DiskWriter.shared.remove(StoragePaths.ink(id, page: removed))
        }
        savedPageIDs = live
        dirtyInk.removeAll()
        contentDirty = false

        updateSearchText()
        var thumbnailChanged = false
        if let first = content.pages.first {
            let v = version(of: first.id) &+ first.id.hashValue
            if v != firstPageVersionAtLastThumbnail {
                firstPageVersionAtLastThumbnail = v
                thumbnailChanged = true
                writeLibraryThumbnail()
            }
        }
        library.notebookSaved(id: id, pageCount: content.pages.count, recordingCount: content.recordings.count, thumbnailChanged: false)
        _ = thumbnailChanged
    }

    private func updateSearchText() {
        let search = LibraryStore.shared.search
        let existing = search.entry(for: id)
        let pdfByPage = Dictionary((existing?.pages ?? []).map { ($0.pageID, $0.pdf) }, uniquingKeysWith: { a, _ in a })
        let entry = NotebookSearchText(pages: content.pages.map { page in
            PageSearchText(
                pageID: page.id,
                typed: page.elements.compactMap { $0.textContent?.plainText }.joined(separator: "\n"),
                pdf: pdfByPage[page.id] ?? "",
                ink: page.recognition?.text ?? ""
            )
        }, transcripts: content.recordings.compactMap { $0.transcript?.text })
        search.set(entry, for: id)
    }

    private func writeLibraryThumbnail() {
        guard let first = content.pages.first else { return }
        let page = Unchecked(first)
        let drawing = Unchecked(drawing(for: first.id))
        let assets = assets
        let notebookID = id
        Task {
            let data = await ThumbnailRenderer.jpeg(page: page, drawing: drawing, assets: assets, maxWidth: 360)
            if let data {
                DiskWriter.shared.write(data, to: StoragePaths.thumbnail(notebookID))
                await DiskWriter.shared.flush()
                LibraryStore.shared.thumbnailUpdated(notebookID)
            }
        }
    }

    /// Deletes asset files that nothing references any more. Only safe once the
    /// editor (and its undo history) is gone.
    func removeUnreferencedAssets() {
        let referenced = content.referencedAssets
        let folder = StoragePaths.assets(id)
        DiskWriter.shared.run {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in files where !referenced.contains(name) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }
}
