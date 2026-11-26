import Foundation
import NotesCraftCore
import Observation
import UIKit

/// Reusable stickers: lasso selections saved for inserting into any notebook.
@Observable
final class ElementsLibrary {
    static let shared = ElementsLibrary()

    struct Item: Codable, Identifiable, Hashable {
        var id: UUID
        var createdAt: Date
    }

    private(set) var items: [Item] = []
    @ObservationIgnored private let folder = StoragePaths.elementsLibrary
    @ObservationIgnored private var indexURL: URL { folder.appendingPathComponent("elements.json") }
    @ObservationIgnored private let previews = NSCache<NSString, UIImage>()

    private init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL), let list = try? Coders.decoder().decode([Item].self, from: data) {
            items = list.filter { FileManager.default.fileExists(atPath: payloadURL($0.id).path) }
        }
    }

    private func payloadURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).json") }
    private func previewURL(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).png") }

    func add(payload: Clipboard.Payload, preview: UIImage) throws {
        let id = UUID()
        try JSONEncoder().encode(payload).write(to: payloadURL(id), options: .atomic)
        if let png = preview.pngData() { try png.write(to: previewURL(id), options: .atomic) }
        items.insert(Item(id: id, createdAt: Date()), at: 0)
        persist()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: payloadURL(id))
        try? FileManager.default.removeItem(at: previewURL(id))
        persist()
    }

    func payload(_ id: UUID) -> Clipboard.Payload? {
        guard let data = try? Data(contentsOf: payloadURL(id)) else { return nil }
        return try? JSONDecoder().decode(Clipboard.Payload.self, from: data)
    }

    func preview(_ id: UUID) -> UIImage? {
        if let img = previews.object(forKey: id.uuidString as NSString) { return img }
        guard let img = UIImage(contentsOfFile: previewURL(id).path) else { return nil }
        previews.setObject(img, forKey: id.uuidString as NSString)
        return img
    }

    private func persist() {
        if let data = try? Coders.encoder().encode(items) {
            DiskWriter.shared.write(data, to: indexURL)
        }
    }
}
