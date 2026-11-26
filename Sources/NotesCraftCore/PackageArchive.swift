import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A simple single-file container for a notebook folder (`.notescraft`).
///
/// Layout: 8-byte magic, 4-byte little-endian manifest length, the JSON manifest,
/// then each file's bytes back to back in manifest order.
public enum PackageArchive {
    public static let magic = Array("NCARCH01".utf8)
    public static let fileExtension = "notescraft"

    public struct Entry: Codable, Equatable, Sendable {
        public var path: String
        public var size: Int64
    }

    struct Manifest: Codable {
        var format: Int
        var kind: String
        var entries: [Entry]
    }

    public enum ArchiveError: Error, LocalizedError, Equatable {
        case notAnArchive
        case unsupportedVersion(Int)
        case corrupt(String)
        case unsafePath(String)

        public var errorDescription: String? {
            switch self {
            case .notAnArchive: "This file isn't a NotesCraft notebook."
            case let .unsupportedVersion(v): "This notebook was made by a newer version of NotesCraft (format \(v))."
            case let .corrupt(detail): "The notebook file is damaged (\(detail))."
            case let .unsafePath(p): "The notebook file contains an invalid path (\(p))."
            }
        }
    }

    /// Writes every regular file under `directory` into a single archive at `destination`.
    public static func write(directory: URL, to destination: URL, kind: String = "notebook") throws {
        let fm = FileManager.default
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = fm.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            throw ArchiveError.corrupt("cannot read folder")
        }
        var files: [(URL, Entry)] = []
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(basePath) else { continue }
            let rel = String(full.dropFirst(basePath.count))
            files.append((url, Entry(path: rel, size: Int64(values.fileSize ?? 0))))
        }
        files.sort { $0.1.path < $1.1.path }
        // Re-read sizes from the actual data we write to stay consistent.
        let manifest = Manifest(format: 1, kind: kind, entries: files.map(\.1))
        let manifestData = try JSONEncoder().encode(manifest)

        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        guard fm.createFile(atPath: destination.path, contents: nil) else {
            throw ArchiveError.corrupt("cannot create file")
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var header = Data(magic)
        var len = UInt32(manifestData.count).littleEndian
        withUnsafeBytes(of: &len) { header.append(contentsOf: $0) }
        header.append(manifestData)
        try handle.write(contentsOf: header)
        for (url, entry) in files {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard Int64(data.count) == entry.size else {
                throw ArchiveError.corrupt("file changed while archiving: \(entry.path)")
            }
            try handle.write(contentsOf: data)
        }
    }

    /// Reads only the manifest kind, to identify an archive cheaply.
    public static func kind(of url: URL) throws -> String {
        let (manifest, _) = try readManifest(url)
        return manifest.kind
    }

    /// Extracts an archive into `directory` (created if needed).
    public static func extract(_ archive: URL, to directory: URL) throws {
        let fm = FileManager.default
        let (manifest, dataStart) = try readManifest(archive)
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var offset = dataStart
        for entry in manifest.entries {
            let parts = entry.path.split(separator: "/", omittingEmptySubsequences: true)
            guard !entry.path.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else {
                throw ArchiveError.unsafePath(entry.path)
            }
            guard entry.size >= 0, offset + Int(entry.size) <= data.count else {
                throw ArchiveError.corrupt("truncated at \(entry.path)")
            }
            let target = parts.reduce(directory) { $0.appendingPathComponent(String($1)) }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let slice = data.subdata(in: offset ..< offset + Int(entry.size))
            try slice.write(to: target, options: .atomic)
            offset += Int(entry.size)
        }
        guard offset == data.count else { throw ArchiveError.corrupt("unexpected trailing data") }
    }

    static func readManifest(_ url: URL) throws -> (Manifest, Int) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let head = try handle.read(upToCount: 12), head.count == 12 else { throw ArchiveError.notAnArchive }
        guard Array(head.prefix(8)) == magic else { throw ArchiveError.notAnArchive }
        let lenBytes = Array(head[8 ..< 12])
        let len = Int(UInt32(lenBytes[0]) | UInt32(lenBytes[1]) << 8 | UInt32(lenBytes[2]) << 16 | UInt32(lenBytes[3]) << 24)
        guard len > 0, len < 64 * 1024 * 1024 else { throw ArchiveError.corrupt("bad manifest length") }
        guard let manifestData = try handle.read(upToCount: len), manifestData.count == len else {
            throw ArchiveError.corrupt("truncated manifest")
        }
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        } catch {
            throw ArchiveError.corrupt("unreadable manifest")
        }
        guard manifest.format == 1 else { throw ArchiveError.unsupportedVersion(manifest.format) }
        return (manifest, 12 + len)
    }
}
