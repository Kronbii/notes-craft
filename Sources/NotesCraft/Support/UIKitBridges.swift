import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// Presents the system share sheet from the frontmost window.
enum SharePresenter {
    static func share(_ items: [Any], sourceRect: CGRect? = nil) {
        guard let top = topViewController() else { return }
        let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = top.view
            let bounds = top.view.bounds
            popover.sourceRect = sourceRect ?? CGRect(x: bounds.maxX - 80, y: bounds.minY + 60, width: 1, height: 1)
            popover.permittedArrowDirections = sourceRect == nil ? [.up] : .any
        }
        top.present(activity, animated: true)
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        guard let window = active?.windows.first(where: \.isKeyWindow) ?? active?.windows.first else { return nil }
        var top = window.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
}

/// Hosts the canvas UIKit view.
struct CanvasRepresentable: UIViewRepresentable {
    let controller: CanvasController

    func makeUIView(context: Context) -> CanvasRootView {
        controller.rootView
    }

    func updateUIView(_ uiView: CanvasRootView, context: Context) {}
}

/// Camera capture for inserting a photo.
struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

/// Document scanner (VisionKit) returning page images.
struct DocumentScanner: UIViewControllerRepresentable {
    var onScan: ([UIImage]) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let vc = VNDocumentCameraViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScanner
        init(_ parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var images: [UIImage] = []
            for i in 0 ..< scan.pageCount { images.append(scan.imageOfPage(at: i)) }
            parent.onScan(images)
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.dismiss()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.dismiss()
        }
    }
}

extension UIImage {
    /// JPEG data for import pipelines.
    var importData: Data? { jpegData(compressionQuality: 0.9) }
}

/// System photo picker (PHPicker) returning image data.
struct PhotoPicker: UIViewControllerRepresentable {
    var selectionLimit: Int = 1
    var onPick: ([Data]) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = selectionLimit
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: PhotoPicker
        init(_ parent: PhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard !results.isEmpty else { return }
            let providers = results.map(\.itemProvider)
            let onPick = parent.onPick
            Task { @MainActor in
                var datas: [Data] = []
                for provider in providers {
                    if let data = await Self.loadData(provider) { datas.append(data) }
                }
                onPick(datas)
            }
        }

        private static func loadData(_ provider: NSItemProvider) async -> Data? {
            let type = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .image) == true } ?? UTType.image.identifier
            return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                    cont.resume(returning: data)
                }
            }
        }
    }
}
