import NotesCraftCore
import PencilKit
import SwiftUI

/// The floating tool capsule: tools on the left, quick presets for the active tool on the right.
struct ToolRow: View {
    @Bindable var model: EditorModel
    var onInsertPhoto: () -> Void
    var onInsertCamera: () -> Void

    private let tools: [ToolKind] = [.pen, .highlighter, .eraser, .shape, .lasso, .text, .laser]

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal, showsIndicators: false) {
                row
                    .frame(minWidth: geo.size.width)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
        .frame(height: 50)
    }

    private var row: some View {
        ToolbarLayout {
            FavoritesCapsule(model: model)
            toolsCapsule
            ContextualTools(model: model)
                .padding(.horizontal, 8)
                .frame(height: 50)
                .glassCapsule()
        }
        .padding(.horizontal, 12)
        .opacity(model.isReplaying ? 0.6 : 1)
    }

    private var toolsCapsule: some View {
        HStack(spacing: 2) {
            ForEach(tools) { tool in
                toolButton(tool)
            }
            Menu {
                Button(action: onInsertPhoto) { Label("Photo library", systemImage: "photo.on.rectangle") }
                Button(action: onInsertCamera) { Label("Camera", systemImage: "camera") }
                Button { model.sheet = .elements } label: { Label("Elements", systemImage: "star.square.on.square") }
                Button { model.paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .disabled(!Clipboard.hasContent)
            } label: {
                Image(systemName: "photo")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Insert image")
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        .glassCapsule()
    }

    private func toolButton(_ tool: ToolKind) -> some View {
        let selected = model.tools.tool == tool
        return Button {
            model.toggleTool(tool)
        } label: {
            ZStack(alignment: .bottom) {
                Image(systemName: tool.symbol)
                if tool.isInking, let color = preset(for: tool)?.color {
                    Capsule()
                        .fill(color.color)
                        .frame(width: 14, height: 3)
                        .offset(y: 6)
                        .opacity(selected ? 0 : 0.9)
                }
            }
        }
        .buttonStyle(IconButtonStyle(isSelected: selected))
        .accessibilityLabel(tool.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .popover(isPresented: Binding(get: { model.palette == tool }, set: { if !$0 { model.palette = nil } }), arrowEdge: .top) {
            ToolOptions(model: model, tool: tool)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func preset(for tool: ToolKind) -> InkPreset? {
        switch tool {
        case .pen: model.tools.pen
        case .highlighter: model.tools.highlighter
        case .shape: model.tools.shape
        default: nil
        }
    }
}

/// Keeps the tool capsule centered (so tools never move when switching), with
/// the active tool's options just to its right. Shifts left only if needed.
struct ToolbarLayout: Layout {
    var gap: CGFloat = 10

    /// Subviews: favorites, tools, the active tool's options.
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let natural = sizes.reduce(0) { $0 + $1.width } + gap * CGFloat(max(0, sizes.count - 1))
        let height = sizes.map(\.height).max() ?? 50
        return CGSize(width: max(proposal.width ?? natural, natural), height: height)
    }

    /// The tools stay centered (so they never move when switching), favorites
    /// sit to their left and options to their right; shifted only if needed.
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else { return }
        let favorites = subviews[0], tools = subviews[1]
        let favSize = favorites.sizeThatFits(.unspecified)
        let toolSize = tools.sizeThatFits(.unspecified)
        let extra = subviews.count > 2 ? subviews[2].sizeThatFits(.unspecified) : .zero
        let leftNeeded = favSize.width > 0 ? favSize.width + gap : 0
        let rightNeeded = extra.width > 0 ? gap + extra.width : 0
        var x = bounds.midX - toolSize.width / 2
        if x + toolSize.width + rightNeeded > bounds.maxX { x = bounds.maxX - toolSize.width - rightNeeded }
        if x - leftNeeded < bounds.minX { x = bounds.minX + leftNeeded }
        if favSize.width > 0 {
            favorites.place(at: CGPoint(x: x - leftNeeded, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(favSize))
        }
        tools.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(toolSize))
        if subviews.count > 2 {
            subviews[2].place(at: CGPoint(x: x + toolSize.width + gap, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(extra))
        }
    }
}

/// Saved pens and highlighters, one tap away; "+" saves the current one.
struct FavoritesCapsule: View {
    @Bindable var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(model.favorites) { fav in
                FavoriteChip(favorite: fav, selected: model.tools.activeFavoriteID == fav.id && model.tools.tool == fav.tool) {
                    model.useFavorite(fav)
                }
                .contextMenu {
                    Button {
                        model.moveFavorite(fav.id, by: -1)
                    } label: {
                        Label("Move left", systemImage: "arrow.left")
                    }
                    Button {
                        model.moveFavorite(fav.id, by: 1)
                    } label: {
                        Label("Move right", systemImage: "arrow.right")
                    }
                    Button(role: .destructive) {
                        model.removeFavorite(fav.id)
                    } label: {
                        Label("Remove from favorites", systemImage: "star.slash")
                    }
                }
            }
            Button {
                model.saveCurrentAsFavorite()
            } label: {
                Image(systemName: model.favorites.isEmpty ? "star" : "plus")
                    .font(.system(size: model.favorites.isEmpty ? 16 : 14, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.tools.currentSetup == nil)
            .opacity(model.tools.currentSetup == nil ? 0.4 : 1)
            .accessibilityLabel("Save this pen as a favorite")
            .help("Save this pen as a favorite")
        }
        .padding(.horizontal, 6)
        .frame(height: 50)
        .glassCapsule()
    }
}

struct FavoriteChip: View {
    let favorite: FavoritePen
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(selected ? Theme.ink : .clear, lineWidth: 2)
                    .frame(width: 34, height: 34)
                Circle()
                    .fill(favorite.color.withAlpha(favorite.tool == .highlighter ? 0.55 : 1).color)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(Theme.ink.opacity(0.2), lineWidth: 0.75))
                Image(systemName: favorite.tool == .highlighter ? "highlighter" : favorite.style.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(favorite.color.luminance > 0.6 ? Color.black.opacity(0.75) : Color.white)
                // Thickness, as a short bar under the dot.
                Capsule()
                    .fill(Theme.ink2)
                    .frame(width: 12, height: min(4, max(1.2, favorite.width / (favorite.tool == .highlighter ? 6 : 1.2))))
                    .offset(y: 20)
            }
            .frame(width: 40, height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Favorite: \(favorite.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Quick controls for whatever tool is active. The capsule keeps one width for
/// every tool, so switching tools never resizes or moves the toolbar.
struct ContextualTools: View {
    @Bindable var model: EditorModel

    /// Fits the widest set of controls (pen colors and thicknesses).
    static let contentWidth: CGFloat = 270

    var body: some View {
        controls
            .frame(width: Self.contentWidth, height: 50)
            .clipped()
    }

    @ViewBuilder
    private var controls: some View {
        switch model.tools.tool {
        case .pen, .highlighter, .shape:
            inkPresets
        case .eraser:
            eraserControls
        case .text:
            TextStyleControls(model: model)
        case .lasso:
            Text(model.hasSelection ? "Drag to move · corners to resize" : "Circle ink, text or images")
                .font(.footnote)
                .foregroundStyle(Theme.ink3)
                .padding(.horizontal, 8)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        case .laser:
            HStack(spacing: 6) {
                ForEach(["#FF3B30", "#34C759", "#0A84FF"], id: \.self) { hex in
                    let c = RGBA(hex: hex)!
                    ColorDot(color: c, selected: model.tools.laserColor == c) {
                        var t = model.tools
                        t.laserColor = c
                        model.tools = t
                    }
                }
            }
        }
    }

    private var inkPresets: some View {
        let preset = model.tools.activePreset ?? model.tools.pen
        let tool = model.tools.tool
        let ranked = preset.widths.enumerated().sorted { $0.element < $1.element }.map(\.offset)
        return HStack(spacing: 2) {
            ForEach(preset.colors.indices, id: \.self) { i in
                ColorDot(color: preset.colors[i], selected: preset.colorIndex == i && model.tools.activeFavorite == nil) {
                    if preset.colorIndex == i, model.tools.activeFavorite == nil {
                        model.editingColorSlot = i
                    } else {
                        var t = model.tools
                        t.activeFavoriteID = nil
                        t.activePreset?.colorIndex = i
                        model.tools = t
                    }
                }
                .popover(isPresented: Binding(get: { model.editingColorSlot == i }, set: { if !$0 { model.editingColorSlot = nil } }), arrowEdge: .top) {
                    ColorPalettePopover(
                        palette: tool == .highlighter ? RGBA.highlighterPalette : RGBA.inkPalette,
                        current: preset.colors[i],
                        title: tool == .highlighter ? "Highlighter color" : "Color"
                    ) { color in
                        var t = model.tools
                        if var p = t.activePreset, p.colors.indices.contains(i) {
                            p.colors[i] = color
                            p.colorIndex = i
                            t.activePreset = p
                        }
                        model.tools = t
                    }
                    .presentationCompactAdaptation(.popover)
                }
            }
            Rectangle().fill(Theme.hair).frame(width: 1, height: 22).padding(.horizontal, 6)
            ForEach(preset.widths.indices, id: \.self) { i in
                WidthDot(rank: ranked.firstIndex(of: i) ?? i, selected: preset.widthIndex == i && model.tools.activeFavorite == nil, highlighter: tool == .highlighter) {
                    if preset.widthIndex == i, model.tools.activeFavorite == nil {
                        model.editingWidthSlot = i
                    } else {
                        var t = model.tools
                        t.activeFavoriteID = nil
                        t.activePreset?.widthIndex = i
                        model.tools = t
                    }
                }
                .popover(isPresented: Binding(get: { model.editingWidthSlot == i }, set: { if !$0 { model.editingWidthSlot = nil } }), arrowEdge: .top) {
                    ThicknessPopover(
                        width: Binding(get: { model.tools.activePreset?.widths[safe: i] ?? 2 }, set: { w in
                            var t = model.tools
                            if var p = t.activePreset, p.widths.indices.contains(i) {
                                p.widths[i] = w
                                t.activePreset = p
                            }
                            model.tools = t
                        }),
                        range: WidthPresets.range(for: tool, style: model.tools.penStyle),
                        color: preset.color,
                        highlighter: tool == .highlighter
                    )
                    .presentationCompactAdaptation(.popover)
                }
            }
        }
    }

    private var eraserControls: some View {
        HStack(spacing: 6) {
            Picker("Eraser", selection: Binding(get: { model.tools.eraserMode }, set: { m in
                var t = model.tools
                t.eraserMode = m
                model.tools = t
            })) {
                Text("Stroke").tag(EraserMode.stroke)
                Text("Partial").tag(EraserMode.partial)
            }
            .pickerStyle(.segmented)
            .frame(width: model.tools.eraserMode == .partial ? 130 : 200)
            if model.tools.eraserMode == .partial {
                ForEach(ToolState.eraserWidths.indices, id: \.self) { i in
                    WidthDot(rank: i, selected: model.tools.eraserWidthIndex == i) {
                        var t = model.tools
                        t.eraserWidthIndex = i
                        model.tools = t
                    }
                }
            }
        }
    }
}

struct ColorDot: View {
    let color: RGBA
    let selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(selected ? Theme.ink : .clear, lineWidth: 2)
                    .frame(width: 34, height: 34)
                Circle()
                    .fill(color.withAlpha(1).color)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(Theme.ink.opacity(0.22), lineWidth: 0.75))
            }
            .frame(width: 40, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(ColorNames.name(for: color))
        .accessibilityHint(selected ? "Double-tap to change this color" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A thickness preset drawn as a short stroke; thicker presets look thicker.
struct WidthDot: View {
    /// 0 = thinnest preset, 2 = thickest.
    let rank: Int
    let selected: Bool
    var highlighter = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Theme.ink.opacity(0.1) : .clear)
                    .frame(width: 36, height: 34)
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Theme.ink : .clear, lineWidth: 1.5)
                    .frame(width: 36, height: 34)
                Capsule()
                    .fill(Theme.ink.opacity(highlighter ? 0.55 : 0.9))
                    .frame(width: 20, height: thickness)
                    .rotationEffect(.degrees(-30))
            }
            .frame(width: 40, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(["Fine", "Medium", "Bold"][min(max(rank, 0), 2)])
        .accessibilityHint(selected ? "Double-tap to change this thickness" : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var thickness: CGFloat {
        highlighter ? [5, 8, 12][min(max(rank, 0), 2)] : [2, 4, 7][min(max(rank, 0), 2)]
    }
}

/// Palette for one color slot.
struct ColorPalettePopover: View {
    let palette: [RGBA]
    let current: RGBA
    var title = "Color"
    var onPick: (RGBA) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var custom: Color = .black

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Circle().fill(current.withAlpha(1).color).frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                Text(ColorNames.name(for: current)).font(.caption).foregroundStyle(Theme.ink2)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 8), count: 6), spacing: 8) {
                ForEach(palette, id: \.self) { c in
                    let isCurrent = current.withAlpha(1).distance(to: c) < 0.02
                    Button {
                        onPick(c)
                        Haptics.tap()
                        dismiss()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(c.color)
                                .frame(width: 34, height: 34)
                                .overlay(Circle().strokeBorder(.black.opacity(c.luminance > 0.75 ? 0.22 : 0.08), lineWidth: 0.75))
                            if isCurrent {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(c.luminance > 0.55 ? Color.black : Color.white)
                            }
                        }
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(ColorNames.name(for: c))
                    .accessibilityAddTraits(isCurrent ? .isSelected : [])
                }
            }
            Divider()
            ColorPicker(selection: Binding(get: { custom }, set: { c in
                custom = c
                onPick(c.rgba.withAlpha(1))
            }), supportsOpacity: false) {
                Label("Custom color…", systemImage: "eyedropper")
                    .font(.subheadline)
            }
        }
        .padding(18)
        .frame(width: 300)
        .onAppear { custom = current.withAlpha(1).color }
    }
}

/// Thickness for one width slot, with a live preview.
struct ThicknessPopover: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let color: RGBA
    let highlighter: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Thickness").font(.headline)
                Spacer()
                Text(String(format: "%.1f pt", width))
                    .font(Theme.mono(13, weight: .medium))
                    .foregroundStyle(Theme.ink2)
            }
            StrokePreview(color: color, width: width, highlighter: highlighter)
                .frame(height: 64)
            HStack(spacing: 10) {
                Image(systemName: "circle.fill").font(.system(size: 5)).foregroundStyle(Theme.ink3)
                Slider(value: Binding(get: { width }, set: { width = ($0 * 10).rounded() / 10 }), in: range)
                Image(systemName: "circle.fill").font(.system(size: 14)).foregroundStyle(Theme.ink3)
            }
        }
        .padding(18)
        .frame(width: 300)
    }
}

enum ColorNames {
    /// A plain name for VoiceOver and the palette header.
    static func name(for c: RGBA) -> String {
        let named: [(String, String)] = [
            ("#111413", "Black"), ("#3D4240", "Charcoal"), ("#6E7471", "Gray"), ("#A3A8A5", "Silver"), ("#D9DCDA", "Light gray"), ("#FFFFFF", "White"),
            ("#0B3C8C", "Navy"), ("#1F4FBF", "Blue"), ("#2F80ED", "Sky blue"), ("#16A3B8", "Teal"), ("#1E7A4F", "Green"), ("#4D6B40", "Sage"),
            ("#8DB86B", "Leaf"), ("#F2B705", "Yellow"), ("#F08A24", "Orange"), ("#E0573A", "Vermilion"), ("#D62E4D", "Red"), ("#9B1B30", "Crimson"),
            ("#E76FA6", "Pink"), ("#B04FCB", "Magenta"), ("#7A4FD6", "Purple"), ("#4B3A8F", "Indigo"), ("#8B5A2B", "Brown"), ("#5C3A21", "Dark brown"),
            ("#FFE45C", "Yellow"), ("#FFC94A", "Gold"), ("#FFB547", "Orange"), ("#FF8FB1", "Pink"), ("#FF6B6B", "Coral"), ("#F7A1FF", "Orchid"),
            ("#C9A7FF", "Lavender"), ("#8FD8FF", "Blue"), ("#7CE3D3", "Aqua"), ("#B9F18C", "Green"), ("#D7F57A", "Lime"), ("#D9D9D9", "Gray"),
        ]
        var best = "Custom"
        var bestDistance = 0.04
        for (hex, name) in named {
            guard let ref = RGBA(hex: hex) else { continue }
            let d = ref.distance(to: c.withAlpha(1))
            if d < bestDistance {
                bestDistance = d
                best = name
            }
        }
        return best
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Popover with every option for a tool.
struct ToolOptions: View {
    @Bindable var model: EditorModel
    let tool: ToolKind
    @State private var customColor: Color = .black

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(tool.title).font(.headline)
            switch tool {
            case .pen, .highlighter, .shape:
                inkOptions
            case .eraser:
                eraserOptions
            default:
                Text("No options").foregroundStyle(Theme.ink3)
            }
        }
        .padding(20)
        .frame(width: tool == .pen ? 372 : 320)
    }

    private var preset: InkPreset {
        switch tool {
        case .highlighter: model.tools.highlighter
        case .shape: model.tools.shape
        default: model.tools.pen
        }
    }

    private func update(_ change: (inout InkPreset) -> Void) {
        var t = model.tools
        switch tool {
        case .highlighter: change(&t.highlighter)
        case .shape: change(&t.shape)
        default: change(&t.pen)
        }
        model.tools = t
    }

    @ViewBuilder
    private var inkOptions: some View {
        if tool == .pen {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pen type").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(PenStyle.available) { style in
                        Button {
                            var t = model.tools
                            t.selectPenStyle(style)
                            model.tools = t
                        } label: {
                            let selected = model.tools.penStyle == style
                            VStack(spacing: 2) {
                                Image(uiImage: InkSample.image(type: style.inkType, color: model.tools.pen.color.luminance > 0.85 ? RGBA(hex: "#111413")! : model.tools.pen.color,
                                                               width: style == .watercolor || style == .crayon ? 7 : style == .calligraphy ? 5 : 3.5,
                                                               size: CGSize(width: 68, height: 30)))
                                    .resizable()
                                    .frame(width: 68, height: 30)
                                Text(style.title).font(.caption2.weight(selected ? .semibold : .regular))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .foregroundStyle(Theme.ink)
                            }
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .background(Color.white.opacity(0.92), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Theme.accent : Theme.hair, lineWidth: selected ? 2.5 : 1))
                            .environment(\.colorScheme, .light)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        Text("Tap the selected color or thickness in the toolbar to change it.")
            .font(.footnote)
            .foregroundStyle(Theme.ink3)
        if tool == .highlighter {
            Toggle("Straight lines", isOn: Binding(get: { AppSettings.shared.straightHighlighter }, set: { AppSettings.shared.straightHighlighter = $0 }))
                .font(.subheadline)
        }
        if tool == .pen {
            Toggle("Hold to snap shapes", isOn: Binding(get: { AppSettings.shared.holdToSnapShapes }, set: { AppSettings.shared.holdToSnapShapes = $0 }))
                .font(.subheadline)
            Toggle("Scribble to erase", isOn: Binding(get: { AppSettings.shared.scribbleToErase }, set: { AppSettings.shared.scribbleToErase = $0 }))
                .font(.subheadline)
            Toggle("Draw with finger", isOn: Binding(get: { AppSettings.shared.drawWithFinger }, set: {
                AppSettings.shared.drawWithFinger = $0
                model.canvas.applyTool(model.tools)
            }))
            .font(.subheadline)
        }
        if tool == .shape {
            Text("Draw a line, circle, rectangle or triangle and it becomes perfect.")
                .font(.footnote)
                .foregroundStyle(Theme.ink3)
        }
    }

    @ViewBuilder
    private var eraserOptions: some View {
        Picker("Mode", selection: Binding(get: { model.tools.eraserMode }, set: { m in
            var t = model.tools
            t.eraserMode = m
            model.tools = t
        })) {
            ForEach(EraserMode.allCases) { m in Text(m.title).tag(m) }
        }
        .pickerStyle(.segmented)
        Text(model.tools.eraserMode == .stroke ? "Removes whole strokes you touch." : "Erases only where you rub, like a real eraser.")
            .font(.footnote)
            .foregroundStyle(Theme.ink3)
        Toggle("Switch back after erasing", isOn: Binding(get: { AppSettings.shared.eraserAutoDeselect }, set: { AppSettings.shared.eraserAutoDeselect = $0 }))
            .font(.subheadline)
        Button(role: .destructive) {
            if model.document.pages.indices.contains(model.currentPage) {
                model.clearInk(on: model.document.pages[model.currentPage].id)
            }
            model.palette = nil
        } label: {
            Label("Clear ink on this page", systemImage: "trash")
        }
    }
}

struct StrokePreview: View {
    let color: RGBA
    let width: Double
    let highlighter: Bool

    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            path.move(to: CGPoint(x: 12, y: size.height * 0.6))
            path.addCurve(to: CGPoint(x: size.width - 12, y: size.height * 0.4),
                          control1: CGPoint(x: size.width * 0.35, y: -size.height * 0.2),
                          control2: CGPoint(x: size.width * 0.65, y: size.height * 1.2))
            ctx.stroke(path, with: .color(color.color.opacity(highlighter ? 0.45 : 1)),
                       style: StrokeStyle(lineWidth: width, lineCap: highlighter ? .butt : .round, lineJoin: .round))
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hair))
    }
}

/// Text formatting controls (shown for the text tool).
struct TextStyleControls: View {
    @Bindable var model: EditorModel

    private static let sizes: [Double] = [10, 12, 14, 17, 20, 24, 28, 34, 40, 48, 64]

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                ForEach(TextFontFamily.allCases) { f in
                    Button {
                        model.applyTextStyle(.family(f))
                    } label: {
                        Label(f.title, systemImage: model.tools.textFamily == f ? "checkmark" : "")
                    }
                }
            } label: {
                Text(model.tools.textFamily.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .frame(width: 52, height: 44)
            }
            .accessibilityLabel("Font")
            Menu {
                Button {
                    model.applyTextStyle(.size(min(96, model.tools.textSize + 1)))
                } label: { Label("Larger", systemImage: "textformat.size.larger") }
                Button {
                    model.applyTextStyle(.size(max(8, model.tools.textSize - 1)))
                } label: { Label("Smaller", systemImage: "textformat.size.smaller") }
                Divider()
                ForEach(Self.sizes, id: \.self) { size in
                    Button {
                        model.applyTextStyle(.size(size))
                    } label: {
                        Label("\(Int(size)) pt", systemImage: Int(model.tools.textSize) == Int(size) ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text("\(Int(model.tools.textSize))").font(Theme.mono(13))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .frame(width: 52, height: 44)
            }
            .accessibilityLabel("Text size, \(Int(model.tools.textSize)) points")
            Button { model.applyTextStyle(.bold) } label: { Image(systemName: "bold") }
                .buttonStyle(IconButtonStyle(size: 32))
                .accessibilityLabel("Bold")
            Button { model.applyTextStyle(.italic) } label: { Image(systemName: "italic") }
                .buttonStyle(IconButtonStyle(size: 32))
                .accessibilityLabel("Italic")
            Menu {
                ForEach(RGBA.inkPalette, id: \.self) { c in
                    Button {
                        model.applyTextStyle(.color(c))
                    } label: {
                        Label { Text(c.hex) } icon: { Image(uiImage: SelectionBar.swatch(c)) }
                    }
                }
            } label: {
                Circle()
                    .fill(model.tools.textColor.color)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(.black.opacity(0.15), lineWidth: 0.5))
                    .frame(width: 40, height: 44)
            }
            .accessibilityLabel("Text color")
            Menu {
                Button { model.applyTextStyle(.underline) } label: { Label("Underline", systemImage: "underline") }
                Button { model.applyTextStyle(.strikethrough) } label: { Label("Strikethrough", systemImage: "strikethrough") }
                Button { model.applyTextStyle(.highlight(RGBA(hex: "#FFE45C")?.withAlpha(0.6))) } label: { Label("Highlight", systemImage: "highlighter") }
                Divider()
                Button { model.applyTextStyle(.alignment(.left)) } label: { Label("Align left", systemImage: "text.alignleft") }
                Button { model.applyTextStyle(.alignment(.center)) } label: { Label("Center", systemImage: "text.aligncenter") }
                Button { model.applyTextStyle(.alignment(.right)) } label: { Label("Align right", systemImage: "text.alignright") }
                Divider()
                Button { model.applyTextStyle(.fill(RGBA(hex: "#FFF6C7"))) } label: { Label("Yellow note", systemImage: "note.text") }
                Button { model.applyTextStyle(.fill(RGBA(hex: "#EEF3E9"))) } label: { Label("Sage note", systemImage: "note.text") }
                Button { model.applyTextStyle(.fill(nil)) } label: { Label("No fill", systemImage: "square.dashed") }
            } label: {
                Image(systemName: "textformat")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 40, height: 44)
            }
            .accessibilityLabel("More text formatting")
        }
        .foregroundStyle(Theme.ink)
    }
}

/// A real ink sample for a pen style, rendered with PencilKit.
enum InkSample {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(type: PKInk.InkType, color: RGBA, width: Double, size: CGSize) -> UIImage {
        let key = "\(type.rawValue)-\(color.hex)-\(width)-\(Int(size.width))x\(Int(size.height))" as NSString
        if let img = cache.object(forKey: key) { return img }
        var points: [PKStrokePoint] = []
        let n = 60
        for i in 0 ... n {
            let t = CGFloat(i) / CGFloat(n)
            let x = 8 + (size.width - 16) * t
            let y = size.height / 2 + sin(t * .pi * 2.2) * size.height * 0.26
            // Pressure swells in the middle so pressure-sensitive pens show it.
            let force = 0.6 + 0.9 * sin(t * .pi)
            points.append(PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: Double(i) * 0.012,
                                        size: CGSize(width: width, height: width), opacity: 1, force: force,
                                        azimuth: .pi / 4, altitude: .pi / 3))
        }
        let ink = PKInk(type, color: UIColor(color.withAlpha(1)))
        let drawing = PKDrawing(strokes: [PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: CGRect(origin: .zero, size: size), scale: 2)
        }
        cache.setObject(image, forKey: key)
        return image
    }
}
