import NotesCraftCore
import SwiftUI
import UIKit

/// House style: sage on soft charcoal, warm paper whites in light mode, one serif
/// italic "human word" in titles, monospaced figures for data.
enum Theme {
    // MARK: Colors

    static let accentUI = UIColor.dynamic(light: "#4D6B40", dark: "#B7D3A8")
    static let accentInkUI = UIColor.dynamic(light: "#FFFFFF", dark: "#10180D")
    static let backgroundUI = UIColor.dynamic(light: "#F4F4EF", dark: "#1D211F")
    static let surfaceUI = UIColor.dynamic(light: "#FFFFFF", dark: "#252A27")
    static let raisedUI = UIColor.dynamic(light: "#FFFFFF", dark: "#2D332F")
    static let sunkUI = UIColor.dynamic(light: "#EAEAE3", dark: "#171A18")
    static let inkUI = UIColor.dynamic(light: "#111413", dark: "#E8ECE6")
    static let deskUI = UIColor.dynamic(light: "#E6E6DF", dark: "#2A2F2C")
    static let hairUI = UIColor.dynamic(light: UIColor(hex: "#111413").withAlphaComponent(0.10), dark: UIColor(hex: "#E8ECE6").withAlphaComponent(0.13))
    static let recordUI = UIColor.dynamic(light: "#D0342C", dark: "#FF6159")
    /// Accent drawn over paper (always the darker sage: pages are mostly light).
    static let canvasAccentUI = UIColor(hex: "#4D6B40")
    static let canvasAccent = Color(uiColor: canvasAccentUI)
    /// Sidebar selection: a mid sage that keeps white text readable in dark mode.
    static let sidebarSelection = Color(uiColor: UIColor.dynamic(light: "#4D6B40", dark: "#56744A"))

    static let accent = Color(uiColor: accentUI)
    static let accentInk = Color(uiColor: accentInkUI)
    static let background = Color(uiColor: backgroundUI)
    static let surface = Color(uiColor: surfaceUI)
    static let raised = Color(uiColor: raisedUI)
    static let sunk = Color(uiColor: sunkUI)
    static let ink = Color(uiColor: inkUI)
    static let ink2 = Color(uiColor: inkUI).opacity(0.72)
    static let ink3 = Color(uiColor: inkUI).opacity(0.5)
    static let hair = Color(uiColor: hairUI)
    static let desk = Color(uiColor: deskUI)
    static let record = Color(uiColor: recordUI)

    /// The chromatic-aberration fringe from the brand: green out, magenta in.
    static let fringeGreen = Color(red: 166 / 255, green: 230 / 255, blue: 143 / 255)
    static let fringeMagenta = Color(red: 224 / 255, green: 143 / 255, blue: 208 / 255)

    // MARK: Type

    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func serif(_ size: CGFloat, italic: Bool = true) -> Font {
        let f = Font.system(size: size, weight: .regular, design: .serif)
        return italic ? f.italic() : f
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: Metrics

    static let radiusSmall: CGFloat = 10
    static let radius: CGFloat = 16
    static let radiusLarge: CGFloat = 24
}

// MARK: - Title with one serif word

/// "All *notes*" — the house style: one human word set in the serif italic.
struct HouseTitle: View {
    var lead: String
    var human: String
    var trail: String = ""
    var size: CGFloat = 34

    var body: some View {
        (Text(lead.isEmpty ? "" : lead + " ").font(Theme.display(size, weight: .semibold))
            + Text(human).font(Theme.serif(size + 2))
            + Text(trail).font(Theme.display(size, weight: .semibold)))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .accessibilityElement(children: .combine)
    }
}

// MARK: - Buttons

struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .primary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(kind == .secondary ? Theme.hair : .clear, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
            .contentShape(Capsule())
    }

    private var foreground: Color {
        switch kind {
        case .primary: Theme.accentInk
        case .secondary: Theme.ink
        case .destructive: .white
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Theme.accent
        case .secondary: Theme.raised
        case .destructive: Theme.record
        }
    }
}

/// A 44pt-tappable icon button with a soft selected state.
struct IconButtonStyle: ButtonStyle {
    var isSelected = false
    var tint: Color? = nil
    var size: CGFloat = 38

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(isSelected ? Theme.accentInk : (tint ?? Theme.ink))
            .frame(width: size, height: size)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(isSelected ? Theme.accent : (configuration.isPressed ? Theme.hair : .clear))
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Materials

extension View {
    /// Liquid Glass on iOS 26, a thin material before that.
    @ViewBuilder
    func glassBackground(cornerRadius: CGFloat = 18) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.hair, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
        }
    }

    @ViewBuilder
    func glassCapsule() -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hair, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        }
    }

    /// A card on the page: raised surface, hairline, soft shadow.
    func cardSurface(cornerRadius: CGFloat = Theme.radius) -> some View {
        self
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Theme.hair, lineWidth: 0.5))
    }
}

// MARK: - Color bridging

nonisolated extension UIColor {
    convenience init(hex: String) {
        let c = RGBA(hex: hex) ?? .black
        self.init(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    convenience init(_ rgba: RGBA) {
        self.init(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }

    static func dynamic(light: String, dark: String) -> UIColor {
        dynamic(light: UIColor(hex: light), dark: UIColor(hex: dark))
    }

    static func dynamic(light: UIColor, dark: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }

    /// sRGB components, resolving dynamic colors in the light appearance.
    var rgba: RGBA {
        let resolved = resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !resolved.getRed(&r, green: &g, blue: &b, alpha: &a) {
            var w: CGFloat = 0
            if resolved.getWhite(&w, alpha: &a) {
                return RGBA(r: w, g: w, b: w, a: a)
            }
            return .black
        }
        return RGBA(r: r, g: g, b: b, a: a)
    }
}

nonisolated extension RGBA {
    var uiColor: UIColor { UIColor(self) }
    var color: Color { Color(uiColor: uiColor) }
    var cgColor: CGColor { UIColor(self).cgColor }
}

extension Color {
    var rgba: RGBA { UIColor(self).rgba }
}

// MARK: - Haptics

enum Haptics {
    static func tap() {
        guard AppSettings.shared.haptics else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func snap() {
        guard AppSettings.shared.haptics else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred(intensity: 0.8)
    }

    static func success() {
        guard AppSettings.shared.haptics else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        guard AppSettings.shared.haptics else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

/// A button label for form and list rows, drawn in the accent color directly.
/// Rows backed by UIKit can lose the app tint in dark mode and fall back to
/// system blue, so the color is not left to tint inheritance.
struct AccentLabel: View {
    let title: String
    let systemImage: String
    @Environment(\.isEnabled) private var isEnabled

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
        }
        .foregroundStyle(Theme.accent)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// A selectable form row with an accent checkmark (instead of an inline picker,
/// whose checkmark turns system blue in dark mode).
struct CheckRow: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title).foregroundStyle(Theme.ink)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
