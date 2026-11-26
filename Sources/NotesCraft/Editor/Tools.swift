import NotesCraftCore
import PencilKit
import UIKit

enum ToolKind: String, Codable, CaseIterable, Identifiable {
    case pen, highlighter, eraser, shape, lasso, text, laser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .shape: "Shapes"
        case .lasso: "Lasso"
        case .text: "Text"
        case .laser: "Laser pointer"
        }
    }

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .shape: "skew"
        case .lasso: "lasso"
        case .text: "textformat"
        case .laser: "rays"
        }
    }

    /// Tools that put ink on the page through PencilKit.
    var isInking: Bool { self == .pen || self == .highlighter || self == .shape }

    /// Tools that use PencilKit's own drawing gesture (inking and erasing).
    var usesCanvasDrawing: Bool { isInking || self == .eraser }

    var shortcutKey: Character? {
        switch self {
        case .pen: "p"
        case .highlighter: "h"
        case .eraser: "e"
        case .shape: "s"
        case .lasso: "l"
        case .text: "t"
        case .laser: nil
        }
    }
}

enum PenStyle: String, Codable, CaseIterable, Identifiable {
    case ballpoint, fountain, brush, calligraphy, pencil, crayon, watercolor

    var id: String { rawValue }

    /// The styles this iPad can draw (the calligraphy nib needs iOS 26).
    static var available: [PenStyle] {
        if #available(iOS 26, *) { return allCases }
        return allCases.filter { $0 != .calligraphy }
    }

    var title: String {
        switch self {
        case .ballpoint: "Ballpoint"
        case .fountain: "Fountain"
        case .brush: "Brush"
        case .calligraphy: "Calligraphy"
        case .pencil: "Pencil"
        case .crayon: "Crayon"
        case .watercolor: "Watercolor"
        }
    }

    var symbol: String {
        switch self {
        case .ballpoint: "pencil.tip"
        case .fountain: "pencil.tip.crop.circle"
        case .brush: "paintbrush.pointed"
        case .calligraphy: "signature"
        case .pencil: "pencil"
        case .crayon: "pencil.and.scribble"
        case .watercolor: "paintbrush"
        }
    }

    var inkType: PKInk.InkType {
        switch self {
        case .ballpoint: return .monoline
        case .fountain: return .fountainPen
        case .brush: return .pen
        case .calligraphy:
            if #available(iOS 26, *) { return .reed }
            return .fountainPen
        case .pencil: return .pencil
        case .crayon: return .crayon
        case .watercolor: return .watercolor
        }
    }

    /// The nib angle, for inks drawn with a flat nib.
    var nibAngle: CGFloat? {
        self == .calligraphy ? .pi / 4 : nil
    }

    /// Three starting thicknesses that look distinct for this ink (the inks have
    /// very different ranges: crayon and watercolor start at 10 points).
    var defaultWidths: [Double] {
        switch self {
        case .ballpoint: [1.6, 2.6, 3.8]
        case .fountain: [1.8, 3.0, 5.0]
        case .brush: [1.6, 3.0, 6.0]
        case .calligraphy: [5.0, 8.0, 14.0]
        case .pencil: [2.4, 4.0, 7.0]
        case .crayon: [10, 16, 26]
        case .watercolor: [10, 20, 36]
        }
    }
}

enum EraserMode: String, Codable, CaseIterable, Identifiable {
    case stroke, partial
    var id: String { rawValue }
    var title: String { self == .stroke ? "Whole stroke" : "Partial" }
}

/// Three favorite colors and three widths for one tool, GoodNotes-style.
struct InkPreset: Codable, Equatable {
    var colors: [RGBA]
    var widths: [Double]
    var colorIndex: Int
    var widthIndex: Int

    var color: RGBA {
        get { colors.indices.contains(colorIndex) ? colors[colorIndex] : (colors.first ?? .black) }
        set {
            if colors.indices.contains(colorIndex) { colors[colorIndex] = newValue } else { colors.append(newValue) }
        }
    }

    var width: Double {
        get { widths.indices.contains(widthIndex) ? widths[widthIndex] : (widths.first ?? 2) }
        set {
            if widths.indices.contains(widthIndex) { widths[widthIndex] = newValue } else { widths.append(newValue) }
        }
    }
}

struct ToolState: Codable, Equatable {
    var tool: ToolKind = .pen
    var previousTool: ToolKind = .highlighter
    var penStyle: PenStyle = .ballpoint
    var pen = InkPreset(colors: [RGBA(hex: "#111413")!, RGBA(hex: "#1F4FBF")!, RGBA(hex: "#D62E4D")!], widths: PenStyle.ballpoint.defaultWidths, colorIndex: 0, widthIndex: 1)
    /// Each pen type keeps its own three thicknesses (keyed by style).
    var penWidthsByStyle: [String: [Double]]?
    var highlighter = InkPreset(colors: [RGBA(hex: "#FFE45C")!, RGBA(hex: "#B9F18C")!, RGBA(hex: "#FF8FB1")!], widths: [10, 16, 26], colorIndex: 0, widthIndex: 1)
    var shape = InkPreset(colors: [RGBA(hex: "#111413")!, RGBA(hex: "#1F4FBF")!, RGBA(hex: "#4D6B40")!], widths: [1.6, 2.6, 4.2], colorIndex: 0, widthIndex: 1)
    var eraserMode: EraserMode = .stroke
    var eraserWidthIndex: Int = 1
    var laserColor: RGBA = RGBA(hex: "#FF3B30")!
    var textFamily: TextFontFamily = .system
    var textSize: Double = 17
    var textColor: RGBA = RGBA(hex: "#111413")!

    static let eraserWidths: [Double] = [8, 20, 44]

    var eraserWidth: Double {
        ToolState.eraserWidths[min(max(eraserWidthIndex, 0), ToolState.eraserWidths.count - 1)]
    }

    /// The preset of the current inking tool, if any.
    var activePreset: InkPreset? {
        get {
            switch tool {
            case .pen: pen
            case .highlighter: highlighter
            case .shape: shape
            default: nil
            }
        }
        set {
            guard let newValue else { return }
            switch tool {
            case .pen: pen = newValue
            case .highlighter: highlighter = newValue
            case .shape: shape = newValue
            default: break
            }
        }
    }

    /// Switches pen type, keeping each type's own thicknesses.
    mutating func selectPenStyle(_ style: PenStyle) {
        guard style != penStyle else { return }
        var saved = penWidthsByStyle ?? [:]
        saved[penStyle.rawValue] = pen.widths
        penStyle = style
        pen.widths = ToolState.usableWidths(saved[style.rawValue], for: style)
        penWidthsByStyle = saved
    }

    /// Stored widths if they give three distinct strokes for the style's ink,
    /// otherwise the style's defaults.
    static func usableWidths(_ widths: [Double]?, for style: PenStyle) -> [Double] {
        guard let widths, widths.count == 3 else { return style.defaultWidths }
        let clamped = Set(widths.map { Double(WidthPresets.clamp(CGFloat($0), for: style.inkType)) })
        return clamped.count == widths.count ? widths : style.defaultWidths
    }

    // MARK: PencilKit tools

    func pkTool(for kind: ToolKind) -> PKTool? {
        switch kind {
        case .pen:
            return inkingTool(penStyle.inkType, preset: pen, nibAngle: penStyle.nibAngle)
        case .highlighter:
            return inkingTool(.marker, preset: highlighter)
        case .shape:
            return inkingTool(.monoline, preset: shape)
        case .eraser:
            switch eraserMode {
            case .stroke: return PKEraserTool(.vector)
            case .partial: return PKEraserTool(.bitmap, width: eraserWidth)
            }
        default:
            return nil
        }
    }

    private func inkingTool(_ type: PKInk.InkType, preset: InkPreset, nibAngle: CGFloat? = nil) -> PKInkingTool {
        let range = type.validWidthRange
        let width = min(max(preset.width, range.lowerBound), range.upperBound)
        var color = UIColor(preset.color)
        if type == .marker {
            // PencilKit applies its own transparency to markers; keep colors opaque.
            color = color.withAlphaComponent(1)
        }
        if let nibAngle, #available(iOS 26, *) {
            return PKInkingTool(type, color: color, width: width, azimuth: nibAngle)
        }
        return PKInkingTool(type, color: color, width: width)
    }

    // MARK: Persistence

    static func load() -> ToolState {
        guard let data = UserDefaults.standard.data(forKey: "toolState"),
              var state = try? JSONDecoder().decode(ToolState.self, from: data) else { return ToolState() }
        // Never start in a transient tool.
        if state.tool == .laser || state.tool == .lasso || state.tool == .text { state.tool = .pen }
        // Older versions shared one set of widths across pen types, which made
        // all three thicknesses identical for crayon and watercolor.
        state.pen.widths = usableWidths(state.pen.widths, for: state.penStyle)
        return state
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "toolState")
        }
    }
}

/// Shown in the width picker.
enum WidthPresets {
    /// The thickness range offered in the UI: PencilKit's valid range for the
    /// ink (strokes outside it are not drawn by the live canvas), capped to
    /// something sensible for handwriting.
    static func range(for tool: ToolKind, style: PenStyle) -> ClosedRange<Double> {
        let type: PKInk.InkType
        let cap: Double
        switch tool {
        case .highlighter: type = .marker; cap = 40
        case .shape: type = .monoline; cap = 14
        default: type = style.inkType; cap = 20
        }
        let valid = type.validWidthRange
        let lower = Double(valid.lowerBound)
        let upper = min(Double(valid.upperBound), max(cap, lower + 1))
        return lower ... max(upper, lower + 0.5)
    }

    /// A width clamped into the ink's valid range.
    static func clamp(_ width: CGFloat, for type: PKInk.InkType) -> CGFloat {
        let valid = type.validWidthRange
        return min(max(width, valid.lowerBound), valid.upperBound)
    }
}
