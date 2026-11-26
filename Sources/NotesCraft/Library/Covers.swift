import NotesCraftCore
import SwiftUI
import UIKit

/// A notebook cover: a designed cover, or the first page as a sheet of paper.
struct CoverView: View {
    let meta: NotebookMeta
    var showsTitle = true
    @State private var thumbnail: UIImage?
    private var library: LibraryStore { LibraryStore.shared }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Group {
                switch meta.cover {
                case let .design(color, pattern):
                    DesignedCover(color: color, pattern: pattern, title: showsTitle ? meta.title : nil, size: size)
                case .firstPage:
                    paperCover(size: size)
                }
            }
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .task(id: thumbnailKey) {
            guard meta.cover == .firstPage else { return }
            let version = library.thumbnailVersions[meta.id, default: 0]
            if let cached = ThumbnailCache.shared.cached(meta.id, version: version) {
                thumbnail = cached
            } else {
                thumbnail = await ThumbnailCache.shared.load(meta.id, version: version)
            }
        }
    }

    private var thumbnailKey: String {
        "\(meta.id)-\(library.thumbnailVersions[meta.id, default: 0])-\(meta.cover == .firstPage)"
    }

    private func paperCover(size: CGSize) -> some View {
        ZStack {
            // A second sheet peeking out behind, like a stack of paper.
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                .offset(x: 3, y: 3)
                .opacity(meta.pageCount > 1 ? 1 : 0)
            ZStack {
                Color.white
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    ProgressView().controlSize(.small).tint(.gray)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
        }
        .padding(.trailing, meta.pageCount > 1 ? 3 : 0)
        .padding(.bottom, meta.pageCount > 1 ? 3 : 0)
    }
}

struct DesignedCover: View {
    let color: CoverColor
    let pattern: CoverPattern
    var title: String?
    let size: CGSize

    var body: some View {
        let base = color.base
        let ink: Color = base.luminance > 0.45 ? Color.black.opacity(0.75) : Color.white.opacity(0.92)
        ZStack(alignment: .leading) {
            LinearGradient(colors: [base.color.opacity(0.92), base.color], startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { ctx, size in
                CoverPatternPainter.paint(pattern, in: &ctx, size: size, light: base.luminance > 0.45)
            }
            // Spine
            Rectangle()
                .fill(.black.opacity(0.16))
                .frame(width: max(6, size.width * 0.06))
            Rectangle()
                .fill(.white.opacity(0.10))
                .frame(width: 1)
                .offset(x: max(6, size.width * 0.06))
            if let title, size.width > 60 {
                VStack {
                    Text(title)
                        .font(.system(size: max(9, size.width * 0.085), weight: .regular, design: .serif).italic())
                        .foregroundStyle(ink)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, size.width * 0.08)
                        .padding(.vertical, size.width * 0.05)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(base.luminance > 0.45 ? Color.white.opacity(0.55) : Color.black.opacity(0.18))
                        )
                        .padding(.leading, size.width * 0.16)
                        .padding(.trailing, size.width * 0.1)
                        .padding(.top, size.height * 0.16)
                    Spacer()
                }
            }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3, bottomTrailingRadius: 9, topTrailingRadius: 9, style: .continuous))
        .overlay(
            UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3, bottomTrailingRadius: 9, topTrailingRadius: 9, style: .continuous)
                .strokeBorder(.black.opacity(0.12), lineWidth: 0.5)
        )
    }
}

enum CoverPatternPainter {
    static func paint(_ pattern: CoverPattern, in ctx: inout GraphicsContext, size: CGSize, light: Bool) {
        let line = light ? Color.black.opacity(0.07) : Color.white.opacity(0.09)
        switch pattern {
        case .plain:
            break
        case .linen:
            var path = Path()
            var y: CGFloat = 0
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += 2.5
            }
            var x: CGFloat = 0
            while x < size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += 3.5
            }
            ctx.stroke(path, with: .color(line.opacity(0.6)), lineWidth: 0.5)
        case .stripes:
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 14
            }
            ctx.stroke(path, with: .color(line), lineWidth: 5)
        case .grid:
            var path = Path()
            let step = max(8, size.width / 12)
            var x: CGFloat = 0
            while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += step }
            var y: CGFloat = 0
            while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += step }
            ctx.stroke(path, with: .color(line), lineWidth: 0.8)
        case .dots:
            let step = max(8, size.width / 12)
            var y = step / 2
            while y < size.height {
                var x = step / 2
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 1.3, y: y - 1.3, width: 2.6, height: 2.6)), with: .color(line.opacity(1.6)))
                    x += step
                }
                y += step
            }
        case .waves:
            var path = Path()
            let amp = size.height / 60
            var y: CGFloat = 8
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                var x: CGFloat = 0
                while x <= size.width {
                    path.addLine(to: CGPoint(x: x, y: y + sin(x / 9) * amp))
                    x += 3
                }
                y += 9
            }
            ctx.stroke(path, with: .color(line), lineWidth: 1)
        }
    }
}

/// Small rendered preview of a paper template (uses the same renderer as pages).
struct PaperPreview: View {
    let kind: PaperKind
    let color: PaperColor
    var landscape = false
    var size: PageSizePreset = .a4

    var body: some View {
        let pageSize = size.size(landscape: landscape)
        Image(uiImage: PaperPreviewCache.image(kind: kind, color: color, pageSize: pageSize))
            .resizable()
            .aspectRatio(pageSize.width / pageSize.height, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
    }
}

enum PaperPreviewCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(kind: PaperKind, color: PaperColor, pageSize: CGSize, board: Bool = false) -> UIImage {
        let key = "\(kind.rawValue)-\(color.rawValue)-\(Int(pageSize.width))x\(Int(pageSize.height))-\(board)" as NSString
        if let img = cache.object(forKey: key) { return img }
        let target: CGFloat = 240
        let scale = target / max(pageSize.width, pageSize.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let img = UIGraphicsImageRenderer(size: CGSize(width: pageSize.width * scale, height: pageSize.height * scale), format: format).image { ctx in
            ctx.cgContext.scaleBy(x: scale, y: scale)
            // Thicker rules so the pattern reads at thumbnail size.
            PageRenderer.drawPaper(kind: kind, color: color, size: pageSize, in: ctx.cgContext, lineScale: max(1, 0.7 / scale), board: board)
        }
        cache.setObject(img, forKey: key)
        return img
    }
}

/// A folder tile glyph tinted with the folder's color.
struct FolderGlyph: View {
    let color: CoverColor
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                // Back panel with tab
                Path { p in
                    p.move(to: CGPoint(x: 0, y: h * 0.12))
                    p.addLine(to: CGPoint(x: w * 0.36, y: h * 0.12))
                    p.addLine(to: CGPoint(x: w * 0.44, y: h * 0.0))
                    p.addLine(to: CGPoint(x: w, y: h * 0.0))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.addLine(to: CGPoint(x: 0, y: h))
                    p.closeSubpath()
                }
                .fill(color.base.color.opacity(0.7))
                // Paper peeking out
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.95))
                    .frame(width: w * 0.82, height: h * 0.5)
                    .offset(x: w * 0.09, y: h * 0.14)
                // Front panel
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(LinearGradient(colors: [color.base.color.opacity(0.95), color.base.color], startPoint: .top, endPoint: .bottom))
                    .frame(width: w, height: h * 0.76)
                    .offset(y: h * 0.24)
            }
        }
        .aspectRatio(4 / 3, contentMode: .fit)
    }
}

/// The app mark: a sage nib with the brand's green/magenta fringe.
struct AppMark: View {
    var size: CGFloat = 28
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color(red: 11 / 255, green: 13 / 255, blue: 12 / 255))
            Image(systemName: "pencil.tip")
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(Theme.fringeMagenta.opacity(0.9))
                .offset(x: size * 0.035, y: size * 0.02)
            Image(systemName: "pencil.tip")
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(Theme.fringeGreen.opacity(0.9))
                .offset(x: -size * 0.035, y: -size * 0.02)
            Image(systemName: "pencil.tip")
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(Color(red: 0.72, green: 0.83, blue: 0.66))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
