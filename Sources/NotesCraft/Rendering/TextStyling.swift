import CoreText
import NotesCraftCore
import UIKit

extension NSAttributedString.Key {
    /// Our font family choice, stored so round-trips are exact.
    nonisolated static let ncFamily = NSAttributedString.Key("com.kronbii.notescraft.family")
}

/// Converts between stored text runs and attributed strings.
nonisolated enum TextStyling {
    /// `opticalSize` pins the system font's optical design (it changes shape at
    /// large sizes). The editor draws zoomed text with the page-size optics so
    /// it lines up exactly with how the page renders it.
    static func font(family: TextFontFamily, size: Double, bold: Bool, italic: Bool, opticalSize: Double? = nil) -> UIFont {
        let pointSize = CGFloat(max(4, min(size, 400)))
        var font: UIFont
        switch family {
        case .marker:
            font = UIFont(name: bold ? "Noteworthy-Bold" : "Noteworthy-Light", size: pointSize)
                ?? UIFont.systemFont(ofSize: pointSize, weight: bold ? .bold : .regular)
            if italic, let d = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
                font = UIFont(descriptor: d, size: pointSize)
            }
            return font
        default:
            font = UIFont.systemFont(ofSize: pointSize, weight: bold ? .bold : .regular)
        }
        var descriptor = font.fontDescriptor
        switch family {
        case .serif: descriptor = descriptor.withDesign(.serif) ?? descriptor
        case .rounded: descriptor = descriptor.withDesign(.rounded) ?? descriptor
        case .mono: descriptor = descriptor.withDesign(.monospaced) ?? descriptor
        default: break
        }
        var traits = descriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        descriptor = descriptor.withSymbolicTraits(traits) ?? descriptor
        if let opticalSize {
            descriptor = descriptor.addingAttributes([UIFontDescriptor.AttributeName(rawValue: kCTFontOpticalSizeAttribute as String): opticalSize])
        }
        return UIFont(descriptor: descriptor, size: pointSize)
    }

    /// Attributes for a run drawn at `scale` times its page size.
    static func attributes(for run: TextRun, alignment: TextAlign, scale: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        let scaled = abs(scale - 1) > 0.001
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font(family: run.family, size: run.size * Double(scale), bold: run.bold, italic: run.italic,
                        opticalSize: scaled ? run.size : nil),
            .foregroundColor: UIColor(run.color),
            .paragraphStyle: paragraph(alignment),
            .ncFamily: run.family.rawValue,
        ]
        if run.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if run.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let h = run.highlight { attrs[.backgroundColor] = UIColor(h) }
        return attrs
    }

    static func paragraph(_ alignment: TextAlign) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        switch alignment {
        case .left: p.alignment = .natural
        case .center: p.alignment = .center
        case .right: p.alignment = .right
        }
        p.lineBreakMode = .byWordWrapping
        return p
    }

    static func attributedString(_ content: TextContent, scale: CGFloat = 1) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in content.runs {
            out.append(NSAttributedString(string: run.text, attributes: attributes(for: run, alignment: content.alignment, scale: scale)))
        }
        return out
    }

    /// Reads runs back from an attributed string (as edited in a text view).
    static func content(from string: NSAttributedString, scale: CGFloat = 1, fill: RGBA?) -> TextContent {
        var runs: [TextRun] = []
        var alignment: TextAlign = .left
        let full = NSRange(location: 0, length: string.length)
        string.enumerateAttributes(in: full) { attrs, range, _ in
            let text = (string.string as NSString).substring(with: range)
            let font = attrs[.font] as? UIFont ?? UIFont.systemFont(ofSize: 17 * scale)
            let traits = font.fontDescriptor.symbolicTraits
            let family: TextFontFamily
            if let raw = attrs[.ncFamily] as? String, let f = TextFontFamily(rawValue: raw) {
                family = f
            } else {
                family = guessFamily(font)
            }
            let color = (attrs[.foregroundColor] as? UIColor)?.rgba ?? .black
            let highlight = (attrs[.backgroundColor] as? UIColor)?.rgba
            let underline = ((attrs[.underlineStyle] as? Int) ?? 0) != 0
            let strike = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
            if let p = attrs[.paragraphStyle] as? NSParagraphStyle {
                switch p.alignment {
                case .center: alignment = .center
                case .right: alignment = .right
                default: alignment = .left
                }
            }
            runs.append(TextRun(
                text: text,
                family: family,
                size: Double(font.pointSize / max(scale, 0.01)),
                bold: traits.contains(.traitBold),
                italic: traits.contains(.traitItalic),
                underline: underline,
                strikethrough: strike,
                color: color,
                highlight: highlight
            ))
        }
        return TextContent(runs: runs, alignment: alignment, fill: fill)
    }

    static func guessFamily(_ font: UIFont) -> TextFontFamily {
        let name = (font.familyName + " " + font.fontName).lowercased()
        if name.contains("noteworthy") || name.contains("marker") { return .marker }
        if name.contains("new york") || name.contains("newyork") || name.contains("serif") || name.contains("times") || name.contains("georgia") { return .serif }
        if name.contains("rounded") { return .rounded }
        if name.contains("mono") || name.contains("courier") || name.contains("menlo") { return .mono }
        return .system
    }

    /// Height needed to show the text at a given width.
    static func measuredHeight(_ content: TextContent, width: CGFloat) -> CGFloat {
        let s = attributedString(content)
        let probe = s.length == 0 ? NSAttributedString(string: "Ag", attributes: attributes(for: TextRun(text: "Ag"), alignment: .left)) : s
        let rect = probe.boundingRect(with: CGSize(width: max(width - 2 * textInset, 10), height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return ceil(rect.height) + 2 * textInset
    }

    /// Padding between a text box's frame and its text.
    static let textInset: CGFloat = 6
}
