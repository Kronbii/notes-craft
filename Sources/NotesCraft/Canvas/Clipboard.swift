import NotesCraftCore
import PencilKit
import UIKit
import UniformTypeIdentifiers

/// Copy/paste of ink and elements, inside the app and with other apps.
enum Clipboard {
    static let type = "com.kronbii.notescraft.clip"

    struct Payload: Codable {
        var ink: Data
        var elements: [PageElement]
        var assets: [String: Data]
        var width: Double
        var height: Double
    }

    struct Content {
        var strokes: [PKStroke]
        var elements: [PageElement]
        var size: CGSize
    }

    static var hasContent: Bool {
        let pb = UIPasteboard.general
        return pb.contains(pasteboardTypes: [type]) || pb.hasImages || pb.hasStrings
    }

    /// Packs a selection (ink relative to its top-left corner, elements and image data).
    static func payload(selection: CanvasSelection, state: CanvasState, layout: DocumentLayout, assets: AssetStore) -> Payload {
        let bounds = selection.bounds
        let toOrigin = CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)
        var strokes: [PKStroke] = []
        for i in selection.strokeIndices where i < state.drawing.strokes.count {
            var s = state.drawing.strokes[i]
            s.transform = s.transform.concatenating(toOrigin)
            strokes.append(s)
        }
        var elements: [PageElement] = []
        var assetData: [String: Data] = [:]
        for ref in selection.elements {
            guard let pi = state.pages.firstIndex(where: { $0.id == ref.pageID }),
                  var el = state.pages[pi].elements.first(where: { $0.id == ref.elementID }) else { continue }
            let origin = layout.pageFrames[pi].origin
            el.frame = el.frame.offsetBy(dx: origin.x - bounds.minX, dy: origin.y - bounds.minY)
            if let name = el.imageAsset, assetData[name] == nil, let data = try? Data(contentsOf: assets.url(for: name)) {
                assetData[name] = data
            }
            elements.append(el)
        }
        return Payload(ink: PKDrawing(strokes: strokes).dataRepresentation(), elements: elements, assets: assetData,
                       width: Double(bounds.width), height: Double(bounds.height))
    }

    static func write(selection: CanvasSelection, state: CanvasState, layout: DocumentLayout, assets: AssetStore, image: UIImage) {
        let payload = payload(selection: selection, state: state, layout: layout, assets: assets)
        var item: [String: Any] = [:]
        if let data = try? JSONEncoder().encode(payload) { item[type] = data }
        if let png = image.pngData() { item[UTType.png.identifier] = png }
        UIPasteboard.general.setItems([item], options: [.expirationDate: Date().addingTimeInterval(3600 * 24)])
    }

    /// Unpacks a payload into a notebook, copying its images into the notebook's assets.
    static func content(from payload: Payload, into document: NotebookDocument) async -> Content {
        var renamed: [String: String] = [:]
        for (name, bytes) in payload.assets {
            let ext = (name as NSString).pathExtension.isEmpty ? "jpg" : (name as NSString).pathExtension
            if let newName = try? await document.addAsset(data: bytes, ext: ext) { renamed[name] = newName }
        }
        var elements: [PageElement] = []
        for var el in payload.elements {
            if let old = el.imageAsset {
                guard let new = renamed[old] else { continue }
                el.content = .image(asset: new)
            }
            elements.append(el)
        }
        let strokes = (try? PKDrawing(data: payload.ink))?.strokes ?? []
        return Content(strokes: strokes, elements: elements, size: CGSize(width: payload.width, height: payload.height))
    }

    /// Reads the clipboard, copying any images into the notebook's assets.
    static func read(into document: NotebookDocument) async -> Content? {
        let pb = UIPasteboard.general
        if let data = pb.data(forPasteboardType: type), let payload = try? JSONDecoder().decode(Payload.self, from: data) {
            return await content(from: payload, into: document)
        }
        if pb.hasImages, let image = pb.image {
            guard let element = await ImageInsertion.element(for: image, document: document, maxSize: CGSize(width: 320, height: 420)) else { return nil }
            return Content(strokes: [], elements: [element], size: element.frame.size)
        }
        if pb.hasStrings, let string = pb.string, !string.isEmpty {
            let tools = ToolState.load()
            let content = TextContent(runs: [TextRun(text: String(string.prefix(20000)), family: tools.textFamily, size: tools.textSize, color: tools.textColor)])
            let width: CGFloat = 320
            let el = PageElement(frame: CGRect(x: 0, y: 0, width: width, height: TextStyling.measuredHeight(content, width: width)), content: .text(content))
            return Content(strokes: [], elements: [el], size: el.frame.size)
        }
        return nil
    }
}

enum ImageInsertion {
    /// Encodes an image into the notebook and returns an element sized to fit.
    static func element(for image: UIImage, document: NotebookDocument, maxSize: CGSize) async -> PageElement? {
        guard let prepared = await prepare(Unchecked(image)) else { return nil }
        guard let name = try? await document.addAsset(data: prepared.data, ext: prepared.ext) else { return nil }
        let size = prepared.size
        let scale = min(1, maxSize.width / max(size.width, 1), maxSize.height / max(size.height, 1))
        let frame = CGRect(x: 0, y: 0, width: max(24, size.width * scale), height: max(24, size.height * scale))
        return PageElement(frame: frame, content: .image(asset: name))
    }

    struct Prepared: Sendable {
        var data: Data
        var ext: String
        var size: CGSize
    }

    @concurrent
    static func prepare(_ image: Unchecked<UIImage>) async -> Prepared? {
        let ui = image.value
        // Normalize orientation and size by redrawing.
        let maxSide: CGFloat = 2600
        let pixelSize = CGSize(width: ui.size.width * ui.scale, height: ui.size.height * ui.scale)
        let factor = min(1, maxSide / max(pixelSize.width, pixelSize.height, 1))
        let target = CGSize(width: max(1, (pixelSize.width * factor).rounded()), height: max(1, (pixelSize.height * factor).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let hasAlpha = ui.cgImage.map(ImageTools.hasAlpha) ?? false
        format.opaque = !hasAlpha
        let redrawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            ui.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let cg = redrawn.cgImage, let (data, ext) = ImageTools.encode(cg, quality: 0.85) else { return nil }
        // Points: show photos at a comfortable size (1 pt per 2 px, like a retina screenshot).
        return Prepared(data: data, ext: ext, size: CGSize(width: target.width / 2, height: target.height / 2))
    }
}
