import Foundation
import ImageIO
import UIKit

/// Thread-safe cache of a notebook's decoded assets (PDFs and images). Page tiles
/// render on background threads, so everything here is lock-protected.
nonisolated final class AssetStore: @unchecked Sendable {
    let folder: URL
    private let lock = NSLock()
    private var pdfs: [String: CGPDFDocument] = [:]
    private var missing: Set<String> = []
    private let images = NSCache<NSString, CGImageBox>()
    /// CGPDF rendering of one document is serialized; it is not documented as thread-safe.
    let pdfRenderLock = NSLock()

    init(folder: URL) {
        self.folder = folder
        images.countLimit = 24
        images.totalCostLimit = 160 * 1024 * 1024
    }

    func url(for name: String) -> URL {
        folder.appendingPathComponent(name)
    }

    func pdf(_ name: String) -> CGPDFDocument? {
        lock.lock()
        defer { lock.unlock() }
        if let doc = pdfs[name] { return doc }
        if missing.contains(name) { return nil }
        guard let doc = CGPDFDocument(url(for: name) as CFURL) else {
            missing.insert(name)
            return nil
        }
        pdfs[name] = doc
        return doc
    }

    func pdfPage(_ name: String, index: Int) -> CGPDFPage? {
        guard let doc = pdf(name), index >= 0, index < doc.numberOfPages else { return nil }
        return doc.page(at: index + 1)
    }

    /// A decoded image, downsampled to at most `maxPixels` on its longest side.
    func image(_ name: String, maxPixels: Int = 3000) -> CGImage? {
        let key = "\(name)@\(maxPixels)" as NSString
        if let box = images.object(forKey: key) { return box.image }
        guard let cg = ImageTools.downsample(url: url(for: name), maxPixels: maxPixels) else { return nil }
        images.setObject(CGImageBox(cg), forKey: key, cost: cg.bytesPerRow * cg.height)
        return cg
    }

    func imageSize(_ name: String) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url(for: name) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double
        else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    func purgeImages() {
        images.removeAllObjects()
    }

    func forget(_ name: String) {
        lock.lock()
        pdfs[name] = nil
        missing.remove(name)
        lock.unlock()
    }
}

nonisolated final class CGImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
