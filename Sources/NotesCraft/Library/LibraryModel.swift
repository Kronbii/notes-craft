import NotesCraftCore
import Observation
import PencilKit
import SwiftUI
import UniformTypeIdentifiers

struct OpenRequest: Identifiable, Hashable {
    var id: UUID
    var page: Int?
    /// Search text to highlight when the notebook opens (from library search).
    var query: String?
}

enum RenameTarget: Identifiable {
    case notebook(UUID)
    case folder(UUID)
    var id: String {
        switch self {
        case let .notebook(id): "n-\(id)"
        case let .folder(id): "f-\(id)"
        }
    }
}

struct PendingPassword: Identifiable {
    var id = UUID()
    var url: URL
    var folder: UUID?
    var wrongPassword = false
}

/// Per-window library UI state and actions.
@Observable
final class LibraryModel {
    var selection: LibrarySelection = .all
    var searchText = ""
    var isSelecting = false
    var selectedIDs: Set<UUID> = []
    var openRequest: OpenRequest?
    var showNewNotebook = false
    /// The "+ New" panel, and whether it shows its whiteboard step.
    var showNewPanel = false
    var newPanelShowsBoards = false
    var showSettings = false
    var showImporter = false
    var showPhotos = false
    var showScanner = false
    var renameTarget: RenameTarget?
    var renameText = ""
    var moveIDs: [UUID]?
    var coverTarget: UUID?
    var newFolderParent: UUID??
    var newFolderName = ""
    var pendingPassword: PendingPassword?
    var passwordText = ""
    var confirmEmptyTrash = false
    var confirmDeleteFolder: UUID?
    var confirmDeleteForever: [UUID]?

    var library: LibraryStore { LibraryStore.shared }

    /// Folder new items go into.
    var currentFolder: UUID? {
        if case let .folder(id) = selection { return id }
        return nil
    }

    // MARK: Opening

    func open(_ id: UUID, page: Int? = nil, query: String? = nil) {
        guard library.meta(id) != nil else { return }
        if library.isOpen(id) {
            library.report(LibraryError.alreadyOpen.localizedDescription)
            return
        }
        library.markOpened(id)
        openRequest = OpenRequest(id: id, page: page, query: query)
    }

    func newBoard(_ paper: PaperKind, color: PaperColor = .white) {
        do {
            let meta = try library.createBoard(paper: paper, color: color, folder: currentFolder)
            open(meta.id)
        } catch {
            library.report("Couldn't create the canvas: \(error.localizedDescription)")
        }
    }

    func quickNote() {
        do {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d, h:mm a"
            let meta = try library.createNotebook(title: "Quick note · \(formatter.string(from: Date()))",
                                                  paper: AppSettings.shared.defaultPaper, cover: .random(), folder: currentFolder)
            open(meta.id)
        } catch {
            library.report("Couldn't create the note: \(error.localizedDescription)")
        }
    }

    // MARK: Selection mode

    func toggleSelected(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    func endSelecting() {
        isSelecting = false
        selectedIDs.removeAll()
    }

    // MARK: Rename

    func beginRename(_ target: RenameTarget) {
        switch target {
        case let .notebook(id): renameText = library.meta(id)?.title ?? ""
        case let .folder(id): renameText = library.folder(id)?.name ?? ""
        }
        renameTarget = target
    }

    func commitRename() {
        guard let target = renameTarget else { return }
        switch target {
        case let .notebook(id): library.rename(id, to: renameText)
        case let .folder(id): library.renameFolder(id, to: renameText)
        }
        renameTarget = nil
    }

    func beginNewFolder(parent: UUID?) {
        newFolderName = ""
        newFolderParent = .some(parent)
    }

    func commitNewFolder() {
        guard let parent = newFolderParent else { return }
        let folder = library.createFolder(name: newFolderName, parent: parent, color: CoverColor.allCases.randomElement() ?? .sage)
        newFolderParent = nil
        selection = .folder(folder.id)
    }

    // MARK: Import

    func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            Task { await importFiles(urls) }
        case let .failure(error):
            library.report("Import failed: \(error.localizedDescription)")
        }
    }

    func importFiles(_ urls: [URL]) async {
        var imported: [NotebookMeta] = []
        var images: [Data] = []
        let folder = currentFolder
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let type = UTType(filenameExtension: url.pathExtension.lowercased())
            do {
                if type?.conforms(to: .pdf) == true {
                    library.busyMessage = "Importing \(url.lastPathComponent)…"
                    do {
                        imported.append(try await library.importPDF(from: url, folder: folder))
                    } catch LibraryError.lockedPDF {
                        // Copy it now: security-scoped access ends after this call.
                        let copy = StoragePaths.freshExportFolder().appendingPathComponent(url.lastPathComponent)
                        try FileManager.default.copyItem(at: url, to: copy)
                        library.busyMessage = nil
                        pendingPassword = PendingPassword(url: copy, folder: folder)
                    }
                } else if url.pathExtension.lowercased() == PackageArchive.fileExtension {
                    library.busyMessage = "Importing \(url.lastPathComponent)…"
                    imported.append(contentsOf: try await library.importArchive(from: url, folder: folder))
                } else if type?.conforms(to: .image) == true {
                    if let data = try? Data(contentsOf: url) { images.append(data) }
                } else {
                    library.report("“\(url.lastPathComponent)” isn't a file NotesCraft can open.")
                }
            } catch {
                library.report(error.localizedDescription)
            }
        }
        if !images.isEmpty {
            library.busyMessage = "Importing images…"
            do {
                imported.append(try await library.importImages(images, title: "Imported images", folder: folder))
            } catch {
                library.report(error.localizedDescription)
            }
        }
        library.busyMessage = nil
        // Files handed over by other apps land in Documents/Inbox; don't keep copies.
        let inbox = StoragePaths.documents.appendingPathComponent("Inbox").standardizedFileURL.path
        for url in urls where url.standardizedFileURL.path.hasPrefix(inbox) {
            try? FileManager.default.removeItem(at: url)
        }
        if imported.count == 1, let first = imported.first { open(first.id) }
    }

    func submitPassword() {
        guard let pending = pendingPassword else { return }
        let password = passwordText
        passwordText = ""
        pendingPassword = nil
        Task {
            library.busyMessage = "Unlocking PDF…"
            defer { library.busyMessage = nil }
            do {
                let meta = try await library.importPDF(from: pending.url, folder: pending.folder, password: password)
                open(meta.id)
            } catch LibraryError.wrongPassword {
                var again = pending
                again.wrongPassword = true
                pendingPassword = again
            } catch {
                library.report(error.localizedDescription)
            }
        }
    }

    func importPhotos(_ datas: [Data]) {
        guard !datas.isEmpty else { return }
        let folder = currentFolder
        Task {
            library.busyMessage = "Importing photos…"
            do {
                let meta = try await library.importImages(datas, title: "Photos", folder: folder)
                library.busyMessage = nil
                open(meta.id)
            } catch {
                library.busyMessage = nil
                library.report(error.localizedDescription)
            }
        }
    }

    func importScan(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        let folder = currentFolder
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy"
        Task {
            library.busyMessage = "Saving scan…"
            let datas = images.compactMap { $0.jpegData(compressionQuality: 0.85) }
            do {
                let meta = try await library.importImages(datas, title: "Scan \(formatter.string(from: Date()))", folder: folder)
                library.busyMessage = nil
                open(meta.id)
            } catch {
                library.busyMessage = nil
                library.report(error.localizedDescription)
            }
        }
    }

    // MARK: Export

    func shareArchive(_ id: UUID) {
        Task {
            library.busyMessage = "Packaging notebook…"
            do {
                let url = try await library.exportArchive(id)
                library.busyMessage = nil
                SharePresenter.share([url])
            } catch {
                library.busyMessage = nil
                library.report(error.localizedDescription)
            }
        }
    }

    func sharePDF(_ id: UUID) {
        guard !library.isOpen(id) else {
            library.report(LibraryError.alreadyOpen.localizedDescription)
            return
        }
        Task {
            library.busyMessage = "Preparing PDF…"
            do {
                let doc = try await NotebookDocument.open(id: id)
                var drawings: [UUID: PKDrawing] = [:]
                for p in doc.pages { drawings[p.id] = doc.drawing(for: p.id) }
                let job = ExportJob(title: library.meta(id)?.title ?? "Notebook", pages: doc.pages,
                                    drawings: drawings, assets: doc.assets,
                                    vectorInk: AppSettings.shared.vectorInkExport, includeBackgrounds: true)
                let url = try await ExportService.pdf(job)
                library.busyMessage = nil
                SharePresenter.share([url])
            } catch {
                library.busyMessage = nil
                library.report("Couldn't create the PDF: \(error.localizedDescription)")
            }
        }
    }

    func duplicate(_ id: UUID) {
        Task {
            do {
                _ = try await library.duplicate(id)
            } catch {
                library.report("Couldn't duplicate: \(error.localizedDescription)")
            }
        }
    }
}
