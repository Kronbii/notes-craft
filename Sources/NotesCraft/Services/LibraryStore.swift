import Foundation
import NotesCraftCore
import Observation
import PDFKit
import UIKit

enum LibraryError: LocalizedError {
    case notFound
    case emptyPDF
    case lockedPDF
    case wrongPassword
    case unreadableFile(String)
    case alreadyOpen

    var errorDescription: String? {
        switch self {
        case .notFound: "That notebook couldn't be found."
        case .emptyPDF: "That PDF has no pages."
        case .lockedPDF: "That PDF is password protected."
        case .wrongPassword: "That password didn't unlock the PDF."
        case let .unreadableFile(name): "“\(name)” couldn't be read."
        case .alreadyOpen: "This notebook is already open in another window."
        }
    }
}

/// Which notebooks the library is showing.
enum LibrarySelection: Hashable {
    case all
    case recents
    case favorites
    case audio
    case trash
    case folder(UUID)

    var title: (lead: String, human: String) {
        switch self {
        case .all: ("All", "notes")
        case .recents: ("Recent", "notes")
        case .favorites: ("", "Favorites")
        case .audio: ("Audio", "notes")
        case .trash: ("", "Trash")
        case .folder: ("", "")
        }
    }
}

/// The library catalog and every operation on notebooks and folders.
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    private(set) var index = LibraryIndex()
    let search = SearchIndex()
    /// Bumped when a notebook's thumbnail file changes, so covers reload.
    private(set) var thumbnailVersions: [UUID: Int] = [:]
    /// A message shown as a blocking progress overlay during long imports.
    var busyMessage: String?
    /// The latest error to present to the user.
    var errorMessage: String?

    @ObservationIgnored private var openCounts: [UUID: Int] = [:]

    private init() {
        load()
    }

    // MARK: - Loading

    func load() {
        let fm = FileManager.default
        var loaded: LibraryIndex?
        if let data = try? Data(contentsOf: StoragePaths.libraryIndex) {
            do {
                loaded = try Coders.decoder().decode(LibraryIndex.self, from: data)
            } catch {
                log.error("library.json unreadable, rebuilding: \(error.localizedDescription, privacy: .public)")
                // Keep the damaged file for diagnosis.
                let backup = StoragePaths.root.appendingPathComponent("library-damaged-\(Int(Date().timeIntervalSince1970)).json")
                try? fm.copyItem(at: StoragePaths.libraryIndex, to: backup)
            }
        }
        var idx = loaded ?? LibraryIndex()

        // Reconcile with what is actually on disk: drop entries whose files are gone,
        // and recover notebooks that exist on disk but are missing from the index.
        // If the folder can't be listed, leave the index alone rather than
        // concluding that every notebook is gone.
        let onDisk = try? fm.contentsOfDirectory(at: StoragePaths.notebooks, includingPropertiesForKeys: nil)
        let diskIDs = Set((onDisk ?? []).compactMap { UUID(uuidString: $0.lastPathComponent) })
        if onDisk != nil {
            idx.notebooks.removeAll { nb in
                !diskIDs.contains(nb.id) || !fm.fileExists(atPath: StoragePaths.document(nb.id).path)
            }
        }
        let known = Set(idx.notebooks.map(\.id))
        for id in diskIDs where !known.contains(id) {
            if let data = try? Data(contentsOf: StoragePaths.document(id)),
               let content = try? Coders.decoder().decode(NotebookContent.self, from: data) {
                var meta = content.meta
                meta.id = id
                meta.pageCount = content.pages.count
                idx.notebooks.append(meta)
                log.notice("recovered notebook \(id.uuidString, privacy: .public)")
            }
        }
        idx.repair()
        index = idx
        purgeOldTrash()
        if loaded == nil || idx.notebooks.count != (loaded?.notebooks.count ?? -1) { persist() }
    }

    func persist() {
        do {
            let data = try Coders.encoder().encode(index)
            DiskWriter.shared.write(data, to: StoragePaths.libraryIndex) { error in
                Task { @MainActor in
                    LibraryStore.shared.report("Couldn't save the library: \(error.localizedDescription)")
                }
            }
        } catch {
            report("Couldn't save the library: \(error.localizedDescription)")
        }
    }

    func report(_ message: String) {
        log.error("\(message, privacy: .public)")
        errorMessage = message
    }

    // MARK: - Queries

    func meta(_ id: UUID) -> NotebookMeta? { index.notebook(id) }

    func notebooks(for selection: LibrarySelection, sort: LibrarySort) -> [NotebookMeta] {
        let list: [NotebookMeta]
        switch selection {
        case .all:
            list = index.activeNotebooks
        case .recents:
            let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
            let recent = index.activeNotebooks.filter { ($0.openedAt ?? $0.modifiedAt) > cutoff }
            return Array(LibraryLogic.sorted(recent, by: .opened).prefix(30))
        case .favorites:
            list = index.activeNotebooks.filter(\.isFavorite)
        case .audio:
            list = index.activeNotebooks.filter { $0.recordingCount > 0 }
        case .trash:
            return index.trashedNotebooks
        case let .folder(id):
            list = index.notebooks(in: id)
        }
        return LibraryLogic.sorted(list, by: sort)
    }

    func folders(for selection: LibrarySelection) -> [Folder] {
        switch selection {
        case .all: index.subfolders(of: nil)
        case let .folder(id): index.subfolders(of: id)
        default: []
        }
    }

    func folder(_ id: UUID) -> Folder? { index.folder(id) }

    // MARK: - Open tracking (multiple windows)

    func beginEditing(_ id: UUID) -> Bool {
        if openCounts[id, default: 0] > 0 { return false }
        openCounts[id] = 1
        return true
    }

    func endEditing(_ id: UUID) {
        openCounts[id] = nil
    }

    func isOpen(_ id: UUID) -> Bool { openCounts[id, default: 0] > 0 }

    // MARK: - Notebooks

    @discardableResult
    func createNotebook(title: String, paper: PaperStyle, cover: Cover, folder: UUID?) throws -> NotebookMeta {
        let siblings = index.notebooks(in: folder).map(\.title)
        let name = LibraryLogic.uniqueTitle(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : title, existing: siblings)
        var meta = NotebookMeta(title: name, folderID: folder, cover: cover, pageCount: 1)
        meta.openedAt = Date()
        let content = NotebookContent(meta: meta, pages: [Page(style: paper)])
        try writeContent(content)
        index.notebooks.append(meta)
        persist()
        return meta
    }

    /// A whiteboard: one very large page with a blank, dotted or grid background.
    func createBoard(paper: PaperKind, color: PaperColor, folder: UUID?) throws -> NotebookMeta {
        let siblings = index.notebooks(in: folder).map(\.title)
        let name = LibraryLogic.uniqueTitle("Canvas", existing: siblings)
        var meta = NotebookMeta(title: name, folderID: folder, cover: .firstPage, pageCount: 1, kind: .board)
        meta.openedAt = Date()
        let page = Page(size: NotebookKind.boardSize, background: .paper(kind: paper, color: color), isBoard: true)
        try writeContent(NotebookContent(meta: meta, pages: [page]))
        index.notebooks.append(meta)
        persist()
        return meta
    }

    func writeContent(_ content: NotebookContent) throws {
        let data = try Coders.encoder().encode(content)
        let id = content.meta.id
        try FileManager.default.createDirectory(at: StoragePaths.inkFolder(id), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: StoragePaths.assets(id), withIntermediateDirectories: true)
        DiskWriter.shared.write(data, to: StoragePaths.document(id))
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = index.notebooks.firstIndex(where: { $0.id == id }) else { return }
        index.notebooks[i].title = String(trimmed.prefix(200))
        index.notebooks[i].modifiedAt = Date()
        persist()
    }

    func setFavorite(_ ids: [UUID], _ value: Bool) {
        for id in ids {
            if let i = index.notebooks.firstIndex(where: { $0.id == id }) { index.notebooks[i].isFavorite = value }
        }
        persist()
    }

    func setCover(_ id: UUID, _ cover: Cover) {
        guard let i = index.notebooks.firstIndex(where: { $0.id == id }) else { return }
        index.notebooks[i].cover = cover
        persist()
    }

    func markOpened(_ id: UUID) {
        guard let i = index.notebooks.firstIndex(where: { $0.id == id }) else { return }
        index.notebooks[i].openedAt = Date()
        persist()
    }

    /// Called by an open notebook after it saves.
    func notebookSaved(id: UUID, pageCount: Int, recordingCount: Int, thumbnailChanged: Bool) {
        guard let i = index.notebooks.firstIndex(where: { $0.id == id }) else { return }
        index.notebooks[i].pageCount = pageCount
        index.notebooks[i].recordingCount = recordingCount
        index.notebooks[i].modifiedAt = Date()
        if thumbnailChanged { thumbnailVersions[id, default: 0] += 1 }
        persist()
    }

    func thumbnailUpdated(_ id: UUID) {
        thumbnailVersions[id, default: 0] += 1
    }

    func move(_ ids: [UUID], to folder: UUID?) {
        for id in ids {
            if let i = index.notebooks.firstIndex(where: { $0.id == id }) {
                index.notebooks[i].folderID = folder
            }
        }
        persist()
    }

    func trash(_ ids: [UUID]) {
        let now = Date()
        for id in ids where !isOpen(id) {
            if let i = index.notebooks.firstIndex(where: { $0.id == id }) {
                index.notebooks[i].trashedAt = now
            }
        }
        persist()
    }

    func restore(_ ids: [UUID]) {
        for id in ids {
            if let i = index.notebooks.firstIndex(where: { $0.id == id }) {
                index.notebooks[i].trashedAt = nil
                if let f = index.notebooks[i].folderID, index.folder(f) == nil { index.notebooks[i].folderID = nil }
            }
        }
        persist()
    }

    func deletePermanently(_ ids: [UUID]) {
        let set = Set(ids.filter { !isOpen($0) })
        index.notebooks.removeAll { set.contains($0.id) }
        for id in set {
            DiskWriter.shared.remove(StoragePaths.notebook(id))
            search.remove(id)
            ThumbnailCache.shared.forget(id)
        }
        persist()
    }

    func emptyTrash() {
        deletePermanently(index.trashedNotebooks.map(\.id))
    }

    private func purgeOldTrash() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        let old = index.notebooks.filter { ($0.trashedAt ?? .distantFuture) < cutoff }.map(\.id)
        if !old.isEmpty { deletePermanently(old) }
    }

    func duplicate(_ id: UUID) async throws -> NotebookMeta {
        guard let original = meta(id) else { throw LibraryError.notFound }
        await DiskWriter.shared.flush()
        let newID = UUID()
        let src = StoragePaths.notebook(id), dst = StoragePaths.notebook(newID)
        try await Self.copyItem(src, dst)
        var meta = original
        meta.id = newID
        meta.title = LibraryLogic.uniqueTitle(original.title + " copy", existing: index.notebooks(in: original.folderID).map(\.title))
        meta.createdAt = Date()
        meta.modifiedAt = Date()
        meta.isFavorite = false
        try rewriteMeta(meta)
        index.notebooks.append(meta)
        if let entry = search.entry(for: id) { search.set(entry, for: newID) }
        persist()
        return meta
    }

    /// Rewrites the meta stored inside a notebook's document.json (used after copying).
    private func rewriteMeta(_ meta: NotebookMeta) throws {
        let url = StoragePaths.document(meta.id)
        let data = try Data(contentsOf: url)
        var content = try Coders.decoder().decode(NotebookContent.self, from: data)
        content.meta = meta
        let out = try Coders.encoder().encode(content)
        try out.write(to: url, options: .atomic)
    }

    @concurrent
    private static func copyItem(_ src: URL, _ dst: URL) async throws {
        try FileManager.default.copyItem(at: src, to: dst)
    }

    // MARK: - Folders

    @discardableResult
    func createFolder(name: String, parent: UUID?, color: CoverColor = .sage) -> Folder {
        let siblings = index.subfolders(of: parent).map(\.name)
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = Folder(name: LibraryLogic.uniqueTitle(clean.isEmpty ? "New folder" : clean, existing: siblings), parentID: parent, color: color)
        index.folders.append(folder)
        persist()
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = index.folders.firstIndex(where: { $0.id == id }) else { return }
        index.folders[i].name = String(clean.prefix(120))
        index.folders[i].modifiedAt = Date()
        persist()
    }

    func setFolderColor(_ id: UUID, _ color: CoverColor) {
        guard let i = index.folders.firstIndex(where: { $0.id == id }) else { return }
        index.folders[i].color = color
        persist()
    }

    func moveFolder(_ id: UUID, to parent: UUID?) -> Bool {
        guard index.canMove(folder: id, to: parent), let i = index.folders.firstIndex(where: { $0.id == id }) else { return false }
        index.folders[i].parentID = parent
        persist()
        return true
    }

    /// Deletes a folder and its subfolders; their notebooks go to the Trash.
    func deleteFolder(_ id: UUID) {
        let tree = index.descendantFolderIDs(of: id)
        let now = Date()
        for i in index.notebooks.indices where index.notebooks[i].folderID.map(tree.contains) == true {
            if index.notebooks[i].trashedAt == nil { index.notebooks[i].trashedAt = now }
            index.notebooks[i].folderID = nil
        }
        index.folders.removeAll { tree.contains($0.id) }
        persist()
    }

    // MARK: - Import

    /// Imports a PDF as a new notebook. Throws `.lockedPDF` if a password is needed.
    func importPDF(from url: URL, folder: UUID?, password: String? = nil) async throws -> NotebookMeta {
        let id = UUID()
        let assetName = UUID().uuidString + ".pdf"
        let assets = StoragePaths.assets(id)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: StoragePaths.inkFolder(id), withIntermediateDirectories: true)
        let dest = assets.appendingPathComponent(assetName)
        let info: PDFImportInfo
        do {
            info = try await PDFImporter.importFile(from: url, to: dest, password: password)
        } catch {
            try? FileManager.default.removeItem(at: StoragePaths.notebook(id))
            throw error
        }
        let baseTitle = (info.title?.isEmpty == false ? info.title! : url.deletingPathExtension().lastPathComponent)
        var meta = NotebookMeta(
            id: id,
            title: LibraryLogic.uniqueTitle(baseTitle, existing: index.notebooks(in: folder).map(\.title)),
            folderID: folder,
            cover: .firstPage,
            pageCount: info.pageSizes.count
        )
        meta.openedAt = Date()
        let pages = info.pageSizes.enumerated().map { i, size in
            Page(size: size, background: .pdf(asset: assetName, index: i))
        }
        let content = NotebookContent(meta: meta, pages: pages)
        try writeContent(content)
        index.notebooks.append(meta)
        persist()
        indexPDFText(notebook: id, pages: pages, pdfURL: dest)
        Task {
            await DiskWriter.shared.flush()
            await ThumbnailRenderer.renderLibraryThumbnail(notebookID: id)
            self.thumbnailUpdated(id)
        }
        return meta
    }

    /// Extracts PDF text for search in the background.
    func indexPDFText(notebook id: UUID, pages: [Page], pdfURL: URL) {
        let order = pages.map(\.id)
        var targets: [Int: UUID] = [:]
        for page in pages {
            if case let .pdf(_, idx) = page.background { targets[idx] = page.id }
        }
        let wanted = targets
        Task {
            let texts = await PDFImporter.extractText(url: pdfURL, pages: wanted)
            guard !texts.isEmpty else { return }
            self.search.setPDFText(texts, notebook: id, pageOrder: order)
        }
    }

    /// Creates a notebook with one page per image (scans and photos).
    func importImages(_ images: [Data], title: String, folder: UUID?) async throws -> NotebookMeta {
        let id = UUID()
        let assets = StoragePaths.assets(id)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: StoragePaths.inkFolder(id), withIntermediateDirectories: true)
        let prepared = try await Self.prepareImagePages(images, assets: assets)
        guard !prepared.isEmpty else {
            try? FileManager.default.removeItem(at: StoragePaths.notebook(id))
            throw LibraryError.unreadableFile("images")
        }
        var meta = NotebookMeta(
            id: id,
            title: LibraryLogic.uniqueTitle(title, existing: index.notebooks(in: folder).map(\.title)),
            folderID: folder,
            cover: .firstPage,
            pageCount: prepared.count
        )
        meta.openedAt = Date()
        let pages = prepared.map { Page(size: $0.size, background: .image(asset: $0.name)) }
        try writeContent(NotebookContent(meta: meta, pages: pages))
        index.notebooks.append(meta)
        persist()
        Task {
            await DiskWriter.shared.flush()
            await ThumbnailRenderer.renderLibraryThumbnail(notebookID: id)
            self.thumbnailUpdated(id)
        }
        return meta
    }

    struct PreparedImage: Sendable {
        var name: String
        var size: CGSize
    }

    /// Downsamples, encodes and writes images as page backgrounds; returns page sizes.
    @concurrent
    static func prepareImagePages(_ images: [Data], assets: URL) async throws -> [PreparedImage] {
        var out: [PreparedImage] = []
        for data in images {
            guard let cg = ImageTools.downsample(data, maxPixels: 3000), let (encoded, ext) = ImageTools.encode(cg, quality: 0.82) else { continue }
            let name = UUID().uuidString + "." + ext
            try encoded.write(to: assets.appendingPathComponent(name), options: .atomic)
            // Page is A4-wide; height follows the image's aspect ratio.
            let width = 595.28
            let aspect = Double(cg.height) / Double(max(cg.width, 1))
            let height = min(max(width * aspect, 200), 4000)
            out.append(PreparedImage(name: name, size: CGSize(width: width, height: height)))
        }
        return out
    }

    /// Imports a `.notescraft` notebook archive or a full library backup.
    func importArchive(from url: URL, folder: UUID?) async throws -> [NotebookMeta] {
        let kind = try PackageArchive.kind(of: url)
        let temp = StoragePaths.freshExportFolder()
        defer { try? FileManager.default.removeItem(at: temp) }
        try await Self.extract(url, to: temp)
        if kind == "library" {
            return try restoreLibrary(from: temp)
        }
        let meta = try adoptExtractedNotebook(at: temp, folder: folder, keepFolder: false)
        return [meta]
    }

    @concurrent
    private static func extract(_ url: URL, to folder: URL) async throws {
        try PackageArchive.extract(url, to: folder)
    }

    /// Moves an extracted notebook folder into the library under a fresh ID if needed.
    private func adoptExtractedNotebook(at folder: URL, folder target: UUID?, keepFolder: Bool) throws -> NotebookMeta {
        let docURL = folder.appendingPathComponent("document.json")
        guard let data = try? Data(contentsOf: docURL),
              var content = try? Coders.decoder().decode(NotebookContent.self, from: data)
        else { throw LibraryError.unreadableFile(folder.lastPathComponent) }
        var meta = content.meta
        if index.notebook(meta.id) != nil || FileManager.default.fileExists(atPath: StoragePaths.notebook(meta.id).path) {
            meta.id = UUID()
        }
        if !keepFolder || (meta.folderID.flatMap { index.folder($0) } == nil) {
            meta.folderID = keepFolder ? nil : target
        }
        meta.trashedAt = nil
        meta.pageCount = content.pages.count
        meta.title = LibraryLogic.uniqueTitle(meta.title, existing: index.notebooks(in: meta.folderID).map(\.title))
        content.meta = meta
        try Coders.encoder().encode(content).write(to: docURL, options: .atomic)
        try FileManager.default.moveItem(at: folder, to: StoragePaths.notebook(meta.id))
        index.notebooks.append(meta)
        persist()
        reindexImported(meta.id)
        return meta
    }

    private func restoreLibrary(from folder: URL) throws -> [NotebookMeta] {
        // Merge folders first so notebooks can keep their place.
        if let data = try? Data(contentsOf: folder.appendingPathComponent("library.json")),
           let backup = try? Coders.decoder().decode(LibraryIndex.self, from: data) {
            for f in backup.folders where index.folder(f.id) == nil {
                index.folders.append(f)
            }
            index.repair()
        }
        let notebooksDir = folder.appendingPathComponent("Notebooks")
        let items = (try? FileManager.default.contentsOfDirectory(at: notebooksDir, includingPropertiesForKeys: nil)) ?? []
        var restored: [NotebookMeta] = []
        for item in items where UUID(uuidString: item.lastPathComponent) != nil {
            if let meta = try? adoptExtractedNotebook(at: item, folder: nil, keepFolder: true) {
                restored.append(meta)
            }
        }
        persist()
        return restored
    }

    /// Rebuilds search text for a notebook that arrived from outside.
    private func reindexImported(_ id: UUID) {
        guard let data = try? Data(contentsOf: StoragePaths.document(id)),
              let content = try? Coders.decoder().decode(NotebookContent.self, from: data) else { return }
        var entry = NotebookSearchText(pages: content.pages.map { page in
            PageSearchText(
                pageID: page.id,
                typed: page.elements.compactMap { $0.textContent?.plainText }.joined(separator: "\n"),
                pdf: "",
                ink: page.recognition?.text ?? ""
            )
        })
        search.set(entry, for: id)
        // PDF text
        var pdfPages: [String: [Page]] = [:]
        for page in content.pages {
            if case let .pdf(asset, _) = page.background { pdfPages[asset, default: []].append(page) }
        }
        for (asset, pages) in pdfPages {
            indexPDFText(notebook: id, pages: content.pages.filter { pages.contains($0) }, pdfURL: StoragePaths.assets(id).appendingPathComponent(asset))
        }
        entry.pages.removeAll()
        Task {
            await ThumbnailRenderer.renderLibraryThumbnail(notebookID: id)
            self.thumbnailUpdated(id)
        }
    }

    // MARK: - Export

    /// Writes a notebook to a single `.notescraft` file for sharing or backup.
    func exportArchive(_ id: UUID) async throws -> URL {
        guard let meta = meta(id) else { throw LibraryError.notFound }
        await DiskWriter.shared.flush()
        let dest = StoragePaths.freshExportFolder().appendingPathComponent(LibraryLogic.fileSafeName(meta.title) + "." + PackageArchive.fileExtension)
        try await Self.writeArchive(StoragePaths.notebook(id), to: dest, kind: "notebook")
        return dest
    }

    /// Backs up the whole library into Files › NotesCraft › Backups.
    func backupLibrary() async throws -> URL {
        await DiskWriter.shared.flush()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let dest = StoragePaths.backups.appendingPathComponent("NotesCraft Library \(formatter.string(from: Date())).\(PackageArchive.fileExtension)")
        // Stage a folder with only the library index and the notebooks (no caches).
        let stage = StoragePaths.freshExportFolder()
        defer { try? FileManager.default.removeItem(at: stage) }
        let data = try Coders.encoder().encode(index)
        try data.write(to: stage.appendingPathComponent("library.json"))
        try await Self.copyItem(StoragePaths.notebooks, stage.appendingPathComponent("Notebooks"))
        try await Self.writeArchive(stage, to: dest, kind: "library")
        return dest
    }

    /// Weekly automatic backup (keeps the three newest). Runs quietly; failures are logged.
    func autoBackupIfNeeded() {
        let settings = AppSettings.shared
        guard settings.autoBackup, !index.activeNotebooks.isEmpty else { return }
        if let last = settings.lastAutoBackup, Date().timeIntervalSince(last) < 7 * 24 * 3600 { return }
        Task {
            do {
                _ = try await backupLibrary()
                settings.lastAutoBackup = Date()
                let fm = FileManager.default
                let backups = (try? fm.contentsOfDirectory(at: StoragePaths.backups, includingPropertiesForKeys: [.creationDateKey])) ?? []
                let ours = backups.filter { $0.lastPathComponent.hasPrefix("NotesCraft Library ") && $0.pathExtension == PackageArchive.fileExtension }
                    .sorted { a, b in
                        let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                        let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                        return da > db
                    }
                for old in ours.dropFirst(3) { try? fm.removeItem(at: old) }
            } catch {
                log.error("auto backup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    @concurrent
    private static func writeArchive(_ folder: URL, to dest: URL, kind: String) async throws {
        try PackageArchive.write(directory: folder, to: dest, kind: kind)
    }
}
