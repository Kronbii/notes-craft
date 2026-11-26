import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A device-independent sRGB color with alpha, stored as 0...1 components.
public struct RGBA: Codable, Hashable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = RGBA.clamp(r)
        self.g = RGBA.clamp(g)
        self.b = RGBA.clamp(b)
        self.a = RGBA.clamp(a)
    }

    /// Parses `#RGB`, `#RRGGBB` or `#RRGGBBAA` (the `#` is optional).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 {
            s = s.map { "\($0)\($0)" }.joined()
        }
        guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(
                r: Double((value >> 16) & 0xFF) / 255,
                g: Double((value >> 8) & 0xFF) / 255,
                b: Double(value & 0xFF) / 255
            )
        } else {
            self.init(
                r: Double((value >> 24) & 0xFF) / 255,
                g: Double((value >> 16) & 0xFF) / 255,
                b: Double((value >> 8) & 0xFF) / 255,
                a: Double(value & 0xFF) / 255
            )
        }
    }

    public var hex: String {
        func byte(_ v: Double) -> String {
            let n = Int((v * 255).rounded())
            let s = String(n, radix: 16, uppercase: true)
            return s.count == 1 ? "0" + s : s
        }
        let base = "#" + byte(r) + byte(g) + byte(b)
        return a < 0.999 ? base + byte(a) : base
    }

    public func withAlpha(_ alpha: Double) -> RGBA {
        RGBA(r: r, g: g, b: b, a: alpha)
    }

    /// Relative luminance (WCAG), used to pick readable foregrounds.
    public var luminance: Double {
        func lin(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    public var isDark: Bool { luminance < 0.22 }

    /// Approximate perceptual distance, good enough to match palette swatches.
    public func distance(to other: RGBA) -> Double {
        let dr = r - other.r, dg = g - other.g, db = b - other.b, da = a - other.a
        return (dr * dr * 0.3 + dg * dg * 0.59 + db * db * 0.11 + da * da * 0.5).squareRoot()
    }

    private static func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(1, max(0, v))
    }

    public static let black = RGBA(r: 0, g: 0, b: 0)
    public static let white = RGBA(r: 1, g: 1, b: 1)
    public static let clear = RGBA(r: 0, g: 0, b: 0, a: 0)
}

extension RGBA {
    /// Ink colors in the pen palette: 4 rows of 6 (neutrals, cool, warm, accents).
    public static let inkPalette: [RGBA] = [
        "#111413", "#3D4240", "#6E7471", "#A3A8A5", "#D9DCDA", "#FFFFFF",
        "#0B3C8C", "#1F4FBF", "#2F80ED", "#16A3B8", "#1E7A4F", "#4D6B40",
        "#8DB86B", "#F2B705", "#F08A24", "#E0573A", "#D62E4D", "#9B1B30",
        "#E76FA6", "#B04FCB", "#7A4FD6", "#4B3A8F", "#8B5A2B", "#5C3A21",
    ].compactMap(RGBA.init(hex:))

    /// Highlighter colors (drawn with the marker ink, which is translucent).
    public static let highlighterPalette: [RGBA] = [
        "#FFE45C", "#FFC94A", "#FFB547", "#FF8FB1", "#FF6B6B", "#F7A1FF",
        "#C9A7FF", "#8FD8FF", "#7CE3D3", "#B9F18C", "#D7F57A", "#D9D9D9",
    ].compactMap(RGBA.init(hex:))
}
