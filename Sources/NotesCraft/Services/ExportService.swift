import Foundation
import NotesCraftCore
import PencilKit
import UIKit

/// Snapshot of what to export, safe to hand to a background task.
nonisolated struct ExportJob: @unchecked Sendable {
    var title: String
    var pages: [Page]
    var drawings: [UUID: PKDrawing]
    var assets: AssetStore
    var vectorInk: Bool
    var includeBackgrounds: Bool
}

nonisolated enum ExportService {
    /// Writes a PDF of the given pages and returns its URL.
    @concurrent
    static func pdf(_ job: ExportJob) async throws -> URL {
        let url = StoragePaths.freshExportFolder().appendingPathComponent(LibraryLogic.fileSafeName(job.title) + ".pdf")
        // Whiteboards export the area around what is drawn on them.
        let pages = job.pages.map { BoardRegion.prepared(page: $0, drawing: job.drawings[$0.id] ?? PKDrawing()) }
        let first = pages.first?.page.size ?? CGSize(width: 595, height: 842)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: job.title,
            kCGPDFContextCreator as String: "NotesCraft",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: first), format: format)
        try renderer.writePDF(to: url) { context in
            for (page, drawing) in pages {
                autoreleasepool {
                    let bounds = CGRect(origin: .zero, size: page.size)
                    context.beginPage(withBounds: bounds, pageInfo: [:])
                    let ctx = context.cgContext
                    if job.includeBackgrounds {
                        PageRenderer.drawBackground(page.background, size: page.size, assets: job.assets, in: ctx, board: page.isBoard)
                    } else {
                        ctx.setFillColor(UIColor.white.cgColor)
                        ctx.fill(bounds)
                    }
                    PageRenderer.drawElements(page.elements, assets: job.assets, in: ctx, imageMaxPixels: 2400)
                    ctx.saveGState()
                    ctx.clip(to: bounds)
                    if job.vectorInk {
                        InkRenderer.drawVector(drawing, pageRect: bounds, in: ctx)
                    } else if let ink = InkRenderer.image(of: drawing, in: bounds, scale: 3) {
                        ink.draw(in: bounds)
                    }
                    ctx.restoreGState()
                }
            }
        }
        return url
    }

    /// PNG images of pages.
    @concurrent
    static func images(_ job: ExportJob) async -> [URL] {
        let folder = StoragePaths.freshExportFolder()
        var urls: [URL] = []
        for (i, page) in job.pages.enumerated() {
            let image = autoreleasepool {
                let (shown, ink) = BoardRegion.prepared(page: page, drawing: job.drawings[page.id] ?? PKDrawing())
                return PageRenderer.image(page: shown, drawing: ink, assets: job.assets, scale: 2)
            }
            let name = job.pages.count == 1 ? LibraryLogic.fileSafeName(job.title) : "\(LibraryLogic.fileSafeName(job.title)) \(i + 1)"
            let url = folder.appendingPathComponent(name + ".png")
            if let data = image.pngData(), (try? data.write(to: url)) != nil { urls.append(url) }
        }
        return urls
    }
}
