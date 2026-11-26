import Foundation
import NotesCraftCore
import PencilKit
import UIKit

nonisolated enum ThumbnailRenderer {
    /// Renders a page to JPEG data off the main thread.
    @concurrent
    static func jpeg(page: Unchecked<Page>, drawing: Unchecked<PKDrawing>, assets: AssetStore, maxWidth: CGFloat) async -> Data? {
        let image = render(page: page.value, drawing: drawing.value, assets: assets, maxWidth: maxWidth)
        return image.jpegData(compressionQuality: 0.82)
    }

    @concurrent
    static func image(page: Unchecked<Page>, drawing: Unchecked<PKDrawing>, assets: AssetStore, maxWidth: CGFloat) async -> UIImage {
        render(page: page.value, drawing: drawing.value, assets: assets, maxWidth: maxWidth)
    }

    static func render(page board: Page, drawing boardInk: PKDrawing, assets: AssetStore, maxWidth: CGFloat) -> UIImage {
        // A whiteboard shows the area around its content, shaped like a cover.
        let (page, drawing) = BoardRegion.prepared(page: board, drawing: boardInk, aspect: 3 / 4)
        let scale = min(2, maxWidth / max(page.size.width, 1))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: max(1, (page.size.width * scale).rounded()), height: max(1, (page.size.height * scale).rounded()))
        let ink = InkRenderer.image(of: drawing, in: page.bounds, scale: scale * 1.5)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let ctx = context.cgContext
            ctx.scaleBy(x: scale, y: scale)
            PageRenderer.drawBackground(page.background, size: page.size, assets: assets, in: ctx, board: page.isBoard)
            PageRenderer.drawElements(page.elements, assets: assets, in: ctx, imageMaxPixels: Int(maxWidth * 2))
            ink?.draw(in: page.bounds)
        }
    }

    /// Renders the first page of a closed notebook from disk into thumbnail.jpg.
    @concurrent
    static func renderLibraryThumbnail(notebookID: UUID) async {
        guard let data = try? Data(contentsOf: StoragePaths.document(notebookID)),
              let content = try? Coders.decoder().decode(NotebookContent.self, from: data),
              let first = content.pages.first else { return }
        var drawing = PKDrawing()
        if let inkData = try? Data(contentsOf: StoragePaths.ink(notebookID, page: first.id)), let d = try? PKDrawing(data: inkData) {
            drawing = d
        }
        let assets = AssetStore(folder: StoragePaths.assets(notebookID))
        let image = render(page: first, drawing: drawing, assets: assets, maxWidth: 360)
        if let jpeg = image.jpegData(compressionQuality: 0.82) {
            try? jpeg.write(to: StoragePaths.thumbnail(notebookID), options: .atomic)
        }
    }
}

/// In-memory cache of library cover thumbnails loaded from disk.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: Set<String> = []

    init() {
        cache.countLimit = 300
    }

    func cached(_ id: UUID, version: Int) -> UIImage? {
        cache.object(forKey: "\(id.uuidString)-\(version)" as NSString)
    }

    func load(_ id: UUID, version: Int) async -> UIImage? {
        let key = "\(id.uuidString)-\(version)"
        if let img = cache.object(forKey: key as NSString) { return img }
        let url = StoragePaths.thumbnail(id)
        var image = await Self.read(url)
        if image == nil {
            // Older notebooks or a missing file: render it now.
            await ThumbnailRenderer.renderLibraryThumbnail(notebookID: id)
            image = await Self.read(url)
        }
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }

    @concurrent
    private static func read(_ url: URL) async -> UIImage? {
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else { return nil }
        return image.preparingForDisplay() ?? image
    }

    func forget(_ id: UUID) {
        // NSCache cannot enumerate; versions change on update so stale entries age out.
        _ = id
    }
}

/// Thumbnails of pages inside an open notebook, keyed by page version.
@Observable
final class PageThumbnailStore {
    private(set) var images: [UUID: UIImage] = [:]
    @ObservationIgnored private var renderedVersions: [UUID: Int] = [:]
    @ObservationIgnored private var pending: Set<UUID> = []
    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var running = false
    @ObservationIgnored weak var document: NotebookDocument?

    func image(for pageID: UUID) -> UIImage? { images[pageID] }

    /// Requests a thumbnail; renders lazily and only when the page changed.
    func request(_ pageID: UUID) {
        guard let document else { return }
        let v = document.version(of: pageID)
        if renderedVersions[pageID] == v, images[pageID] != nil { return }
        if pending.contains(pageID) { return }
        pending.insert(pageID)
        queue.append(pageID)
        pump()
    }

    func invalidateAll() {
        renderedVersions.removeAll()
    }

    private func pump() {
        guard !running, let document else { return }
        guard let pageID = queue.first else { return }
        queue.removeFirst()
        guard let page = document.pages.first(where: { $0.id == pageID }) else {
            pending.remove(pageID)
            pump()
            return
        }
        running = true
        let version = document.version(of: pageID)
        let drawing = Unchecked(document.drawing(for: pageID))
        let assets = document.assets
        Task {
            let img = await ThumbnailRenderer.image(page: Unchecked(page), drawing: drawing, assets: assets, maxWidth: 220)
            self.images[pageID] = img
            self.renderedVersions[pageID] = version
            self.pending.remove(pageID)
            self.running = false
            // If it changed while rendering, render again.
            if let doc = self.document, doc.version(of: pageID) != version { self.request(pageID) }
            self.pump()
        }
    }
}
