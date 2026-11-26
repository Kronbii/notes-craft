import Foundation
import NotesCraftCore
import PencilKit
import UIKit
import Vision

/// On-device handwriting recognition (Vision), for search and "convert to text".
nonisolated enum HandwritingRecognizer {
    struct Line: Sendable {
        var text: String
        /// Normalized rect, origin top-left.
        var rect: CGRect
    }

    @concurrent
    static func recognize(_ image: Unchecked<CGImage>) async -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image.value, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let observations = request.results ?? []
        var lines: [Line] = []
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first, candidate.confidence > 0.25 else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let b = obs.boundingBox
            lines.append(Line(text: text, rect: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height)))
        }
        // Reading order: top to bottom, then left to right.
        lines.sort { a, b in
            if abs(a.rect.midY - b.rect.midY) > min(a.rect.height, b.rect.height) * 0.5 { return a.rect.midY < b.rect.midY }
            return a.rect.minX < b.rect.minX
        }
        return lines
    }

    /// Text of an image, joined into lines.
    static func text(from image: UIImage) async -> String {
        guard let cg = image.cgImage else { return "" }
        let lines = await recognize(Unchecked(cg))
        return lines.map(\.text).joined(separator: "\n")
    }

    /// Renders a page's ink (no background) on white for recognition.
    static func inkImage(_ drawing: PKDrawing, pageSize: CGSize) -> CGImage? {
        guard !drawing.strokes.isEmpty else { return nil }
        let bounds = CGRect(origin: .zero, size: pageSize)
        // Recognize dark ink: highlighters are skipped, light colors darkened.
        let strokes = drawing.strokes.compactMap { s -> PKStroke? in
            if s.ink.inkType == .marker { return nil }
            return PKStroke(ink: PKInk(s.ink.inkType == .watercolor ? .pen : s.ink.inkType, color: .black), path: s.path, transform: s.transform, mask: s.mask)
        }
        guard !strokes.isEmpty else { return nil }
        let scale: CGFloat = min(2, 2400 / max(pageSize.width, pageSize.height, 1))
        guard let ink = InkRenderer.image(of: PKDrawing(strokes: strokes), in: bounds, scale: scale) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: pageSize, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(bounds)
            ink.draw(in: bounds)
        }
        return image.cgImage
    }
}

/// Recognizes handwriting on pages in the background so it becomes searchable.
final class InkIndexer {
    private weak var document: NotebookDocument?
    private var queue: [UUID] = []
    private var running = false

    init(document: NotebookDocument) {
        self.document = document
    }

    /// Queues pages whose ink changed since they were last recognized.
    func refresh() {
        guard AppSettings.shared.indexHandwriting, let document else { return }
        for page in document.pages {
            let drawing = document.drawing(for: page.id)
            let fp = InkFingerprint.of(drawing)
            if drawing.strokes.isEmpty {
                if page.recognition != nil {
                    var p = page
                    p.recognition = nil
                    document.updatePage(p)
                }
                continue
            }
            if page.recognition?.fingerprint != fp, !queue.contains(page.id) {
                queue.append(page.id)
            }
        }
        pump()
    }

    private func pump() {
        guard !running, let document, !queue.isEmpty else { return }
        let pageID = queue.removeFirst()
        guard let page = document.pages.first(where: { $0.id == pageID }) else {
            pump()
            return
        }
        let drawing = document.drawing(for: pageID)
        let fp = InkFingerprint.of(drawing)
        // On a whiteboard, recognize just the area with ink (at a readable resolution).
        let region = page.isBoard ? BoardRegion.renderRect(page: Page(id: page.id, size: page.size, background: page.background, isBoard: true), drawing: drawing, margin: 24)
            : CGRect(origin: .zero, size: page.size)
        let regionInk = page.isBoard ? drawing.transformed(using: CGAffineTransform(translationX: -region.minX, y: -region.minY)) : drawing
        guard let image = HandwritingRecognizer.inkImage(regionInk, pageSize: region.size) else {
            pump()
            return
        }
        running = true
        Task {
            let lines = await HandwritingRecognizer.recognize(Unchecked(image))
            self.running = false
            guard let doc = self.document, var current = doc.pages.first(where: { $0.id == pageID }) else { return }
            // Only store if the ink hasn't changed meanwhile.
            if InkFingerprint.of(doc.drawing(for: pageID)) == fp {
                let size = region.size
                current.recognition = InkRecognition(fingerprint: fp, lines: lines.map {
                    RecognizedLine(text: $0.text, rect: CGRect(x: region.minX + $0.rect.minX * size.width, y: region.minY + $0.rect.minY * size.height,
                                                               width: $0.rect.width * size.width, height: $0.rect.height * size.height))
                })
                doc.updatePageRecognition(current)
                // Counts only: recognized text is the user's content.
                log.notice("handwriting indexed: \(lines.count, privacy: .public) lines")
            }
            try? await Task.sleep(for: .milliseconds(150))
            self.pump()
        }
    }

    func cancel() {
        queue.removeAll()
    }
}

extension NotebookDocument {
    /// Stores recognition results without counting as a visual change.
    func updatePageRecognition(_ page: Page) {
        guard let i = pageIndex(of: page.id) else { return }
        content.pages[i].recognition = page.recognition
        markContentChanged()
    }
}
