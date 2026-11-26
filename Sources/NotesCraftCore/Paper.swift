import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// The ruling printed on a page.
public enum PaperKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case blank
    case collegeRuled
    case narrowRuled
    case wideRuled
    case legal
    case grid
    case smallGrid
    case dotted
    case cornell
    case checklist
    case music

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .blank: "Blank"
        case .collegeRuled: "Ruled"
        case .narrowRuled: "Narrow ruled"
        case .wideRuled: "Wide ruled"
        case .legal: "Legal"
        case .grid: "Grid"
        case .smallGrid: "Fine grid"
        case .dotted: "Dotted"
        case .cornell: "Cornell"
        case .checklist: "Checklist"
        case .music: "Music"
        }
    }

    /// Spacing between rules, grid lines or dots in points (1/72 in).
    public var spacing: Double {
        switch self {
        case .blank: 0
        case .collegeRuled, .cornell, .checklist: 20.4   // 7.1 mm
        case .narrowRuled: 17.0                          // 6 mm
        case .wideRuled, .legal: 24.7                    // 8.7 mm
        case .grid, .dotted: 14.17                       // 5 mm
        case .smallGrid: 9.92                            // 3.5 mm
        case .music: 7.0
        }
    }

    /// Pattern spacing on a whiteboard: wider, like GoodNotes boards.
    public var boardSpacing: Double {
        switch self {
        case .dotted, .grid: 25
        case .smallGrid: 12.5
        default: spacing
        }
    }

    /// Pattern repeat (document points) a whiteboard shows at a zoom: the base
    /// spacing times the smallest power of two that keeps marks at least
    /// `minGap` points apart on screen (GoodNotes thins its dots the same way).
    public static func boardPitch(base: Double, zoom: Double, minGap: Double) -> Double {
        guard base > 0, zoom > 0 else { return base }
        var step = 1.0
        while base * step * zoom < minGap, step < 65536 { step *= 2 }
        return base * step
    }

    /// Whether a whiteboard draws this kind with its own (board) pattern.
    public var hasBoardPattern: Bool { self == .dotted || self == .grid || self == .smallGrid }

    /// Ruled kinds get a header band and a left margin line.
    public var hasMarginLine: Bool {
        switch self {
        case .collegeRuled, .narrowRuled, .wideRuled, .legal: true
        default: false
        }
    }
}

/// The color of the paper itself.
public enum PaperColor: String, Codable, CaseIterable, Sendable, Identifiable {
    case white
    case ivory
    case yellow
    case sage
    case blue
    case gray
    case dark
    case black

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .white: "White"
        case .ivory: "Ivory"
        case .yellow: "Yellow"
        case .sage: "Sage"
        case .blue: "Blue"
        case .gray: "Gray"
        case .dark: "Charcoal"
        case .black: "Black"
        }
    }

    public var fill: RGBA {
        switch self {
        case .white: RGBA(hex: "#FFFFFF")!
        case .ivory: RGBA(hex: "#FBF7EC")!
        case .yellow: RGBA(hex: "#FDF3BF")!
        case .sage: RGBA(hex: "#EEF3E9")!
        case .blue: RGBA(hex: "#EDF2F9")!
        case .gray: RGBA(hex: "#EFEFEC")!
        case .dark: RGBA(hex: "#2A2D2B")!
        case .black: RGBA(hex: "#121413")!
        }
    }

    public var isDark: Bool { self == .dark || self == .black }

    /// Color of rules, grid lines and dots on this paper.
    public var ruleColor: RGBA {
        switch self {
        case .dark, .black: RGBA(r: 1, g: 1, b: 1, a: 0.16)
        case .yellow: RGBA(hex: "#7FA3C7")!.withAlpha(0.65)
        default: RGBA(hex: "#8FB0CF")!.withAlpha(0.55)
        }
    }

    public var marginColor: RGBA {
        switch self {
        case .dark, .black: RGBA(hex: "#E0573A")!.withAlpha(0.45)
        default: RGBA(hex: "#E0573A")!.withAlpha(0.55)
        }
    }

    /// Default ink for new notebooks on this paper.
    public var defaultInk: RGBA {
        isDark ? RGBA(hex: "#F2F2EE")! : RGBA(hex: "#111413")!
    }
}

/// Standard page sizes in points.
public enum PageSizePreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case a4
    case letter
    case a5
    case b5
    case legal
    case square
    case widescreen
    case tablet

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .a4: "A4"
        case .letter: "US Letter"
        case .a5: "A5"
        case .b5: "B5"
        case .legal: "US Legal"
        case .square: "Square"
        case .widescreen: "16:9"
        case .tablet: "iPad"
        }
    }

    /// Portrait size.
    public var portraitSize: CGSize {
        switch self {
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .letter: CGSize(width: 612, height: 792)
        case .a5: CGSize(width: 419.53, height: 595.28)
        case .b5: CGSize(width: 498.9, height: 708.66)
        case .legal: CGSize(width: 612, height: 1008)
        case .square: CGSize(width: 612, height: 612)
        case .widescreen: CGSize(width: 576, height: 1024)
        case .tablet: CGSize(width: 600, height: 840)
        }
    }

    public func size(landscape: Bool) -> CGSize {
        let s = portraitSize
        return landscape ? CGSize(width: s.height, height: s.width) : s
    }

    /// Finds the preset matching a size (either orientation), if any.
    public static func matching(_ size: CGSize) -> (preset: PageSizePreset, landscape: Bool)? {
        for preset in allCases {
            let p = preset.portraitSize
            if abs(p.width - size.width) < 1, abs(p.height - size.height) < 1 { return (preset, false) }
            if abs(p.height - size.width) < 1, abs(p.width - size.height) < 1 { return (preset, true) }
        }
        return nil
    }
}

/// Paper settings used when creating pages.
public struct PaperStyle: Codable, Hashable, Sendable {
    public var kind: PaperKind
    public var color: PaperColor
    public var size: PageSizePreset
    public var landscape: Bool

    public init(kind: PaperKind = .collegeRuled, color: PaperColor = .white, size: PageSizePreset = .a4, landscape: Bool = false) {
        self.kind = kind
        self.color = color
        self.size = size
        self.landscape = landscape
    }

    public var pageSize: CGSize { size.size(landscape: landscape) }

    public static let `default` = PaperStyle()
}
