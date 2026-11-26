import NotesCraftCore
import Observation
import SwiftUI

enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum PencilDoubleTapAction: String, CaseIterable, Identifiable, Codable {
    case system, eraser, previous, colors, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "Follow system setting"
        case .eraser: "Switch to eraser"
        case .previous: "Switch to previous tool"
        case .colors: "Show color palette"
        case .off: "Do nothing"
        }
    }
}

enum LibraryLayoutMode: String, CaseIterable, Identifiable, Codable {
    case grid, list
    var id: String { rawValue }
}

/// User preferences, persisted in UserDefaults.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    @ObservationIgnored private let defaults = UserDefaults.standard

    var drawWithFinger: Bool { didSet { defaults.set(drawWithFinger, forKey: "drawWithFinger") } }
    var pencilDoubleTap: PencilDoubleTapAction { didSet { defaults.set(pencilDoubleTap.rawValue, forKey: "pencilDoubleTap") } }
    var holdToSnapShapes: Bool { didSet { defaults.set(holdToSnapShapes, forKey: "holdToSnapShapes") } }
    var scribbleToErase: Bool { didSet { defaults.set(scribbleToErase, forKey: "scribbleToErase") } }
    var transcribeRecordings: Bool { didSet { defaults.set(transcribeRecordings, forKey: "transcribeRecordings") } }
    /// Locale identifier for transcripts; empty means the iPad's language.
    var transcriptionLanguage: String { didSet { defaults.set(transcriptionLanguage, forKey: "transcriptionLanguage") } }
    var straightHighlighter: Bool { didSet { defaults.set(straightHighlighter, forKey: "straightHighlighter") } }
    var eraserAutoDeselect: Bool { didSet { defaults.set(eraserAutoDeselect, forKey: "eraserAutoDeselect") } }
    var tapGesturesUndo: Bool { didSet { defaults.set(tapGesturesUndo, forKey: "tapGesturesUndo") } }
    var haptics: Bool { didSet { defaults.set(haptics, forKey: "haptics") } }
    var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    var defaultPaper: PaperStyle { didSet { store(defaultPaper, "defaultPaper") } }
    var librarySort: LibrarySort { didSet { defaults.set(librarySort.rawValue, forKey: "librarySort") } }
    var libraryLayout: LibraryLayoutMode { didSet { defaults.set(libraryLayout.rawValue, forKey: "libraryLayout") } }
    var showPageNumbers: Bool { didSet { defaults.set(showPageNumbers, forKey: "showPageNumbers") } }
    var indexHandwriting: Bool { didSet { defaults.set(indexHandwriting, forKey: "indexHandwriting") } }
    var vectorInkExport: Bool { didSet { defaults.set(vectorInkExport, forKey: "vectorInkExport") } }
    var hasSeenWelcome: Bool { didSet { defaults.set(hasSeenWelcome, forKey: "hasSeenWelcome") } }
    var hasSeenEditorTips: Bool { didSet { defaults.set(hasSeenEditorTips, forKey: "hasSeenEditorTips") } }
    var autoBackup: Bool { didSet { defaults.set(autoBackup, forKey: "autoBackup") } }
    var lastAutoBackup: Date? { didSet { defaults.set(lastAutoBackup, forKey: "lastAutoBackup") } }

    private init() {
        defaults.register(defaults: [
            "drawWithFinger": false,
            "holdToSnapShapes": true,
            "scribbleToErase": true,
            "transcribeRecordings": true,
            "straightHighlighter": true,
            "eraserAutoDeselect": false,
            "tapGesturesUndo": true,
            "haptics": true,
            "showPageNumbers": true,
            "indexHandwriting": true,
            "vectorInkExport": true,
            "hasSeenWelcome": false,
            "autoBackup": true,
        ])
        drawWithFinger = defaults.bool(forKey: "drawWithFinger")
        pencilDoubleTap = PencilDoubleTapAction(rawValue: defaults.string(forKey: "pencilDoubleTap") ?? "") ?? .system
        holdToSnapShapes = defaults.bool(forKey: "holdToSnapShapes")
        scribbleToErase = defaults.bool(forKey: "scribbleToErase")
        transcribeRecordings = defaults.bool(forKey: "transcribeRecordings")
        transcriptionLanguage = defaults.string(forKey: "transcriptionLanguage") ?? ""
        straightHighlighter = defaults.bool(forKey: "straightHighlighter")
        eraserAutoDeselect = defaults.bool(forKey: "eraserAutoDeselect")
        tapGesturesUndo = defaults.bool(forKey: "tapGesturesUndo")
        haptics = defaults.bool(forKey: "haptics")
        appearance = AppearanceMode(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        defaultPaper = AppSettings.load(PaperStyle.self, "defaultPaper", defaults) ?? .default
        librarySort = LibrarySort(rawValue: defaults.string(forKey: "librarySort") ?? "") ?? .modified
        libraryLayout = LibraryLayoutMode(rawValue: defaults.string(forKey: "libraryLayout") ?? "") ?? .grid
        showPageNumbers = defaults.bool(forKey: "showPageNumbers")
        indexHandwriting = defaults.bool(forKey: "indexHandwriting")
        vectorInkExport = defaults.bool(forKey: "vectorInkExport")
        hasSeenWelcome = defaults.bool(forKey: "hasSeenWelcome")
        autoBackup = defaults.bool(forKey: "autoBackup")
        hasSeenEditorTips = defaults.bool(forKey: "hasSeenEditorTips")
        lastAutoBackup = defaults.object(forKey: "lastAutoBackup") as? Date
    }

    private func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, _ defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
