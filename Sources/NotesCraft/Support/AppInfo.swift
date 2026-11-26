import Foundation
import NotesCraftCore
import UIKit

/// Version, build and support details shown in Settings and attached to bug reports.
enum AppInfo {
    static let repository = URL(string: "https://github.com/Kronbii/notes-craft")!
    static let releases = repository.appendingPathComponent("releases")

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// Debug builds made while developing NotesCraft (they include the test harness).
    static var isDevelopmentBuild: Bool {
        #if NOTESCRAFT_DEV
        return true
        #else
        return false
        #endif
    }

    /// "1.0.0 (1)", plus "development" for development builds.
    static var versionLabel: String {
        "\(version) (\(build))" + (isDevelopmentBuild ? " · development" : "")
    }

    /// Hardware model, e.g. "iPad13,18".
    static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    static var systemVersion: String { UIDevice.current.systemVersion }

    /// Everything a bug report needs, without any of the user's content.
    static func diagnostics(library: LibraryStore) -> String {
        let notebooks = library.index.activeNotebooks
        let canvases = notebooks.filter(\.isBoard).count
        let size = folderSize(StoragePaths.root)
        let free = (try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        var lines = [
            "NotesCraft \(versionLabel)",
            "iPadOS \(systemVersion) on \(deviceModel)",
            "Notebooks: \(notebooks.count - canvases), canvases: \(canvases), folders: \(library.index.folders.count), in trash: \(library.index.notebooks.count - notebooks.count)",
            "Library size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))",
        ]
        if let free {
            lines.append("Free space: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file))")
        }
        lines.append("Settings: finger drawing \(AppSettings.shared.drawWithFinger ? "on" : "off"), scribble to erase \(AppSettings.shared.scribbleToErase ? "on" : "off"), appearance \(AppSettings.shared.appearance.rawValue)")
        return lines.joined(separator: "\n")
    }

    /// A new GitHub issue from one of the repository's forms, with the version
    /// and device already filled in.
    static func newIssueURL(template: String) -> URL {
        var components = URLComponents(url: repository.appendingPathComponent("issues/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "template", value: template),
            URLQueryItem(name: "app-version", value: versionLabel),
            URLQueryItem(name: "ipados", value: systemVersion),
            URLQueryItem(name: "device", value: deviceModel),
        ]
        return components.url ?? repository
    }

    private static func folderSize(_ url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: []) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
