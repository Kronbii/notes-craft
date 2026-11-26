import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// MARK: - Page

/// What is printed underneath the ink on a page.
public enum PageBackground: Codable, Hashable, Sendable {
    /// Ruled, grid, dotted, ... paper.
    case paper(kind: PaperKind, color: PaperColor)
    /// A page of an imported PDF stored as an asset of the notebook (0-based index).
    case pdf(asset: String, index: Int)
    /// A full-page image (scans, photos imported as pages).
    case image(asset: String)

    public var paperColor: PaperColor {
        if case let .paper(_, color) = self { return color }
        return .white
    }

    public var paperKind: PaperKind? {
        if case let .paper(kind, _) = self { return kind }
        return nil
    }

    public var assetName: String? {
        switch self {
        case .paper: nil
        case let .pdf(asset, _): asset
        case let .image(asset): asset
        }
    }
}

public enum TextFontFamily: String, Codable, CaseIterable, Sendable, Identifiable {
    case system
    case serif
    case rounded
    case mono
    case marker

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: "Sans"
        case .serif: "Serif"
        case .rounded: "Rounded"
        case .mono: "Mono"
        case .marker: "Marker"
        }
    }
}

public enum TextAlign: String, Codable, CaseIterable, Sendable {
    case left, center, right
}

/// A styled run of text inside a text box.
public struct TextRun: Codable, Hashable, Sendable {
    public var text: String
    public var family: TextFontFamily
    public var size: Double
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var strikethrough: Bool
    public var color: RGBA
    public var highlight: RGBA?

    public init(
        text: String,
        family: TextFontFamily = .system,
        size: Double = 17,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false,
        color: RGBA = .black,
        highlight: RGBA? = nil
    ) {
        self.text = text
        self.family = family
        self.size = size
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.color = color
        self.highlight = highlight
    }

    /// True when both runs render identically and can be merged.
    public func hasSameStyle(as other: TextRun) -> Bool {
        family == other.family && abs(size - other.size) < 0.01 && bold == other.bold && italic == other.italic
            && underline == other.underline && strikethrough == other.strikethrough && color == other.color
            && highlight == other.highlight
    }
}

public struct TextContent: Codable, Hashable, Sendable {
    public var runs: [TextRun]
    public var alignment: TextAlign
    /// Optional fill behind the whole box.
    public var fill: RGBA?

    public init(runs: [TextRun], alignment: TextAlign = .left, fill: RGBA? = nil) {
        self.runs = TextContent.normalized(runs)
        self.alignment = alignment
        self.fill = fill
    }

    public var plainText: String { runs.map(\.text).joined() }

    public var isEmpty: Bool {
        plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Merges adjacent runs with identical style and drops empty runs.
    public static func normalized(_ runs: [TextRun]) -> [TextRun] {
        var out: [TextRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = out.last, last.hasSameStyle(as: run) {
                out[out.count - 1].text += run.text
            } else {
                out.append(run)
            }
        }
        return out
    }
}

public enum ElementContent: Codable, Hashable, Sendable {
    case image(asset: String)
    case text(TextContent)
}

/// A typed text box or a picture placed on a page, below the ink.
public struct PageElement: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    /// Page-local frame in points.
    public var frame: CGRect
    public var content: ElementContent

    public init(id: UUID = UUID(), frame: CGRect, content: ElementContent) {
        self.id = id
        self.frame = frame
        self.content = content
    }

    public var isText: Bool {
        if case .text = content { return true }
        return false
    }

    public var textContent: TextContent? {
        if case let .text(t) = content { return t }
        return nil
    }

    public var imageAsset: String? {
        if case let .image(asset) = content { return asset }
        return nil
    }
}

/// A line of handwriting recognized on a page, used for search.
public struct RecognizedLine: Codable, Hashable, Sendable {
    public var text: String
    /// Page-local rectangle.
    public var rect: CGRect

    public init(text: String, rect: CGRect) {
        self.text = text
        self.rect = rect
    }
}

public struct InkRecognition: Codable, Hashable, Sendable {
    /// Fingerprint of the ink that was recognized; when it differs the page is re-indexed.
    public var fingerprint: Int
    public var lines: [RecognizedLine]

    public init(fingerprint: Int, lines: [RecognizedLine]) {
        self.fingerprint = fingerprint
        self.lines = lines
    }

    public var text: String { lines.map(\.text).joined(separator: "\n") }
}

public struct Page: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var size: CGSize
    public var background: PageBackground
    public var elements: [PageElement]
    public var bookmarked: Bool
    public var recognition: InkRecognition?
    /// The single, growing page of a whiteboard.
    public var isBoard: Bool

    public init(
        id: UUID = UUID(),
        size: CGSize,
        background: PageBackground,
        elements: [PageElement] = [],
        bookmarked: Bool = false,
        recognition: InkRecognition? = nil,
        isBoard: Bool = false
    ) {
        self.id = id
        self.isBoard = isBoard
        self.size = Page.sanitized(size, board: isBoard)
        self.background = background
        self.elements = elements
        self.bookmarked = bookmarked
        self.recognition = recognition
    }

    public init(style: PaperStyle) {
        self.init(size: style.pageSize, background: .paper(kind: style.kind, color: style.color))
    }

    /// A new blank page that continues the look of this one (same size and paper).
    public func continuation() -> Page {
        switch background {
        case .paper:
            Page(size: size, background: background)
        case .pdf, .image:
            Page(size: size, background: .paper(kind: .blank, color: .white))
        }
    }

    public var bounds: CGRect { CGRect(origin: .zero, size: size) }

    enum CodingKeys: String, CodingKey {
        case id, size, background, elements, bookmarked, recognition
        case isBoard = "board"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        let rawSize = try c.decodeIfPresent(CGSize.self, forKey: .size) ?? PaperStyle.default.pageSize
        // Boards made before the flag existed have the starting board size.
        isBoard = (try? c.decodeIfPresent(Bool.self, forKey: .isBoard)) ?? (rawSize == NotebookKind.legacyBoardSize)
        size = Page.sanitized(rawSize, board: isBoard)
        background = (try? c.decode(PageBackground.self, forKey: .background)) ?? .paper(kind: .blank, color: .white)
        elements = (try? c.decodeIfPresent([PageElement].self, forKey: .elements)) ?? []
        bookmarked = (try? c.decodeIfPresent(Bool.self, forKey: .bookmarked)) ?? false
        recognition = try? c.decodeIfPresent(InkRecognition.self, forKey: .recognition)
    }

    static func sanitized(_ size: CGSize, board: Bool = false) -> CGSize {
        let w = size.width.isFinite ? size.width : 595
        let h = size.height.isFinite ? size.height : 842
        let limit = board ? NotebookKind.maxBoardSide : 14400
        return CGSize(width: min(max(w, 72), limit), height: min(max(h, 72), limit))
    }
}

// MARK: - Audio

/// An audio recording attached to a notebook. Ink written while it was recording
/// can be replayed in sync with the audio.
public struct Recording: Codable, Hashable, Identifiable, Sendable {
    /// A stretch of continuous recording. Pausing and resuming starts a new segment.
    public struct Segment: Codable, Hashable, Sendable {
        public var wallStart: Date
        public var mediaStart: TimeInterval
        public var duration: TimeInterval

        public init(wallStart: Date, mediaStart: TimeInterval, duration: TimeInterval) {
            self.wallStart = wallStart
            self.mediaStart = mediaStart
            self.duration = duration
        }
    }

    public var id: UUID
    public var asset: String
    public var title: String
    public var createdAt: Date
    public var duration: TimeInterval
    public var segments: [Segment]
    /// What was said, once transcribed on the iPad.
    public var transcript: Transcript?

    public init(id: UUID = UUID(), asset: String, title: String, createdAt: Date, duration: TimeInterval, segments: [Segment], transcript: Transcript? = nil) {
        self.id = id
        self.asset = asset
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.segments = segments
        self.transcript = transcript
    }

    enum CodingKeys: String, CodingKey {
        case id, asset, title, createdAt, duration, segments, transcript
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        asset = try c.decode(String.self, forKey: .asset)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        segments = try c.decode([Segment].self, forKey: .segments)
        // A damaged transcript must never take the recording down with it.
        transcript = try? c.decodeIfPresent(Transcript.self, forKey: .transcript)
    }

    /// Position in the audio file that corresponds to a wall-clock moment, or nil
    /// if nothing was being recorded then. A small tolerance absorbs strokes that
    /// began just before recording started or just after a pause.
    public func mediaTime(for date: Date, tolerance: TimeInterval = 1.0) -> TimeInterval? {
        for segment in segments {
            let offset = date.timeIntervalSince(segment.wallStart)
            if offset >= -tolerance, offset <= segment.duration + tolerance {
                let clamped = min(max(offset, 0), segment.duration)
                return min(segment.mediaStart + clamped, duration)
            }
        }
        return nil
    }
}

// MARK: - Library

public enum CoverColor: String, Codable, CaseIterable, Sendable, Identifiable {
    case sage, forest, ink, slate, ocean, sky, plum, lavender, rose, clay, coral, mustard, sand, stone

    public var id: String { rawValue }

    public var title: String { rawValue.capitalized }

    public var base: RGBA {
        switch self {
        case .sage: RGBA(hex: "#6F8F5E")!
        case .forest: RGBA(hex: "#2F4A39")!
        case .ink: RGBA(hex: "#1C2220")!
        case .slate: RGBA(hex: "#56626B")!
        case .ocean: RGBA(hex: "#2E5B7A")!
        case .sky: RGBA(hex: "#7DA7C9")!
        case .plum: RGBA(hex: "#5D3A5C")!
        case .lavender: RGBA(hex: "#9C8BC4")!
        case .rose: RGBA(hex: "#C98A8F")!
        case .clay: RGBA(hex: "#B0614A")!
        case .coral: RGBA(hex: "#E07A5F")!
        case .mustard: RGBA(hex: "#C79A2E")!
        case .sand: RGBA(hex: "#D7C6A2")!
        case .stone: RGBA(hex: "#A9A89F")!
        }
    }
}

public enum CoverPattern: String, Codable, CaseIterable, Sendable, Identifiable {
    case plain, linen, stripes, grid, dots, waves

    public var id: String { rawValue }

    public var title: String { rawValue.capitalized }
}

public enum Cover: Codable, Hashable, Sendable {
    case design(color: CoverColor, pattern: CoverPattern)
    /// Shows a thumbnail of the first page, like a stack of paper.
    case firstPage

    public static let `default` = Cover.design(color: .sage, pattern: .linen)

    public static func random() -> Cover {
        .design(color: CoverColor.allCases.randomElement() ?? .sage, pattern: CoverPattern.allCases.randomElement() ?? .plain)
    }
}

public struct Folder: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?
    public var color: CoverColor
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, color: CoverColor = .sage, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.color = color
        self.createdAt = createdAt
        self.modifiedAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, name, parentID, color, createdAt, modifiedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Folder"
        parentID = try? c.decodeIfPresent(UUID.self, forKey: .parentID)
        color = (try? c.decodeIfPresent(CoverColor.self, forKey: .color)) ?? .sage
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        modifiedAt = (try? c.decodeIfPresent(Date.self, forKey: .modifiedAt)) ?? createdAt
    }
}

/// A notebook is a stack of pages; a whiteboard is one very large page you can
/// pan and zoom around freely.
public enum NotebookKind: String, Codable, Sendable {
    case notebook
    case board

    /// Starting size of a whiteboard's single page (you start in the middle).
    /// It is big enough that growing is rarely needed; the board still grows in
    /// any direction as you approach an edge.
    public static let boardSize = CGSize(width: 100_000, height: 100_000)
    /// Size of boards made before boards were flagged (recognized when loading).
    public static let legacyBoardSize = CGSize(width: 12000, height: 12000)
    /// A board never grows past this (points per side).
    public static let maxBoardSide: Double = 1_000_000
}

public struct NotebookMeta: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var kind: NotebookKind
    public var folderID: UUID?
    public var createdAt: Date
    public var modifiedAt: Date
    public var openedAt: Date?
    public var cover: Cover
    public var isFavorite: Bool
    public var trashedAt: Date?
    public var pageCount: Int
    public var recordingCount: Int

    public init(
        id: UUID = UUID(),
        title: String,
        folderID: UUID? = nil,
        createdAt: Date = Date(),
        cover: Cover = .default,
        pageCount: Int = 1,
        kind: NotebookKind = .notebook
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.folderID = folderID
        self.createdAt = createdAt
        self.modifiedAt = createdAt
        self.openedAt = nil
        self.cover = cover
        self.isFavorite = false
        self.trashedAt = nil
        self.pageCount = pageCount
        self.recordingCount = 0
    }

    public var isTrashed: Bool { trashedAt != nil }
    public var isBoard: Bool { kind == .board }

    enum CodingKeys: String, CodingKey {
        case id, title, kind, folderID, createdAt, modifiedAt, openedAt, cover, isFavorite, trashedAt, pageCount, recordingCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Untitled"
        kind = (try? c.decodeIfPresent(NotebookKind.self, forKey: .kind)) ?? .notebook
        folderID = try? c.decodeIfPresent(UUID.self, forKey: .folderID)
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        modifiedAt = (try? c.decodeIfPresent(Date.self, forKey: .modifiedAt)) ?? createdAt
        openedAt = try? c.decodeIfPresent(Date.self, forKey: .openedAt)
        cover = (try? c.decodeIfPresent(Cover.self, forKey: .cover)) ?? .default
        isFavorite = (try? c.decodeIfPresent(Bool.self, forKey: .isFavorite)) ?? false
        trashedAt = try? c.decodeIfPresent(Date.self, forKey: .trashedAt)
        pageCount = (try? c.decodeIfPresent(Int.self, forKey: .pageCount)) ?? 0
        recordingCount = (try? c.decodeIfPresent(Int.self, forKey: .recordingCount)) ?? 0
    }
}

/// Everything about a notebook except its ink and binary assets.
public struct NotebookContent: Codable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var meta: NotebookMeta
    public var pages: [Page]
    public var recordings: [Recording]
    public var lastPageIndex: Int

    public init(meta: NotebookMeta, pages: [Page], recordings: [Recording] = []) {
        self.version = NotebookContent.currentVersion
        self.meta = meta
        self.pages = pages
        self.recordings = recordings
        self.lastPageIndex = 0
    }

    enum CodingKeys: String, CodingKey { case version, meta, pages, recordings, lastPageIndex }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        meta = try c.decode(NotebookMeta.self, forKey: .meta)
        // Decode pages one by one so a single damaged page cannot take the notebook down.
        var pageList: [Page] = []
        if var arr = try? c.nestedUnkeyedContainer(forKey: .pages) {
            while !arr.isAtEnd {
                if let page = try? arr.decode(Page.self) {
                    pageList.append(page)
                } else {
                    _ = try? arr.decode(SkipDecodable.self)
                }
            }
        }
        pages = pageList
        recordings = (try? c.decodeIfPresent([Recording].self, forKey: .recordings)) ?? []
        lastPageIndex = (try? c.decodeIfPresent(Int.self, forKey: .lastPageIndex)) ?? 0
    }

    /// The recording that was running at a given moment, with the media time.
    public func recording(at date: Date) -> (Recording, TimeInterval)? {
        for rec in recordings {
            if let t = rec.mediaTime(for: date) { return (rec, t) }
        }
        return nil
    }

    /// Every asset filename referenced by the notebook.
    public var referencedAssets: Set<String> {
        var names = Set<String>()
        for page in pages {
            if let a = page.background.assetName { names.insert(a) }
            for el in page.elements {
                if let a = el.imageAsset { names.insert(a) }
            }
        }
        for rec in recordings { names.insert(rec.asset) }
        return names
    }
}

/// Consumes one value of any shape from an unkeyed container.
struct SkipDecodable: Decodable {
    init(from decoder: Decoder) throws {}
}
