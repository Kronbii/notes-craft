import Foundation
import NotesCraftCore
import os

nonisolated let log = Logger(subsystem: "com.kronbii.NotesCraft", category: "app")

/// Where everything lives on disk.
nonisolated enum StoragePaths {
    /// Private library: Application Support/NotesCraft (not visible in Files).
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("NotesCraft", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let notebooks: URL = {
        let url = root.appendingPathComponent("Notebooks", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let libraryIndex = root.appendingPathComponent("library.json")
    static let searchIndex = root.appendingPathComponent("search.json")
    static let elementsLibrary = root.appendingPathComponent("Elements", isDirectory: true)

    /// Visible in the Files app under "On My iPad › NotesCraft".
    static let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    static var backups: URL {
        let url = documents.appendingPathComponent("Backups", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Scratch space for exports handed to the share sheet; cleared at launch.
    static let exports: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func notebook(_ id: UUID) -> URL {
        notebooks.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func document(_ id: UUID) -> URL {
        notebook(id).appendingPathComponent("document.json")
    }

    static func inkFolder(_ id: UUID) -> URL {
        notebook(id).appendingPathComponent("ink", isDirectory: true)
    }

    static func ink(_ notebookID: UUID, page: UUID) -> URL {
        inkFolder(notebookID).appendingPathComponent(page.uuidString + ".drawing")
    }

    static func assets(_ id: UUID) -> URL {
        notebook(id).appendingPathComponent("assets", isDirectory: true)
    }

    static func thumbnail(_ id: UUID) -> URL {
        notebook(id).appendingPathComponent("thumbnail.jpg")
    }

    static func clearExports() {
        let fm = FileManager.default
        if let items = try? fm.contentsOfDirectory(at: exports, includingPropertiesForKeys: nil) {
            for item in items { try? fm.removeItem(at: item) }
        }
    }

    /// A fresh empty folder inside the export scratch space.
    static func freshExportFolder() -> URL {
        let url = exports.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Serial background writer so disk I/O never blocks drawing. Writes are atomic
/// (temp file + rename), so a crash mid-write never leaves a half-written file.
nonisolated final class DiskWriter: @unchecked Sendable {
    static let shared = DiskWriter()

    private let queue = DispatchQueue(label: "com.kronbii.NotesCraft.disk", qos: .utility)

    func write(_ data: Data, to url: URL, onError: (@Sendable (Error) -> Void)? = nil) {
        queue.async {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                log.error("write failed \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                onError?(error)
            }
        }
    }

    func remove(_ url: URL) {
        queue.async {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Runs work after all pending writes, on the writer queue.
    func run(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    /// Waits until every queued write has hit the disk.
    func flush() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { cont.resume() }
        }
    }

    /// Blocks until queued writes finish (used when the app is about to be suspended).
    func flushSync() {
        queue.sync {}
    }
}

/// Encoders shared across the app.
nonisolated enum Coders {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }
}
