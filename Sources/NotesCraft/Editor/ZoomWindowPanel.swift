import NotesCraftCore
import SwiftUI
import UIKit

/// The zoom window at the bottom of the editor: write big, it lands small and
/// neat inside the box on the page.
struct ZoomWindowPanel: View {
    @Bindable var model: EditorModel
    @State private var magnification: CGFloat = 2.5
    @State private var autoAdvance = true

    static let height: CGFloat = 236

    private var zoom: ZoomWindowController? { model.canvas.zoomWindow }

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 2) {
                arrow("chevron.up", "Move up") { zoom?.nudge(dx: 0, dy: -0.6) }
                HStack(spacing: 2) {
                    arrow("chevron.left", "Move left") { zoom?.nudge(dx: -0.5, dy: 0) }
                    arrow("chevron.right", "Move right") { zoom?.nudge(dx: 0.5, dy: 0) }
                }
                arrow("chevron.down", "Move down") { zoom?.nudge(dx: 0, dy: 0.6) }
            }
            ZoomWindowRepresentable(controller: model.canvas)
                .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
            VStack(spacing: 8) {
                Button {
                    zoom?.newLine()
                } label: {
                    Image(systemName: "return")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .accessibilityLabel("New line")
                Menu {
                    Picker("Magnification", selection: $magnification) {
                        ForEach([1.5, 2.0, 2.5, 3.0, 4.0], id: \.self) { m in
                            Text(String(format: m == m.rounded() ? "%.0f×" : "%.1f×", m)).tag(CGFloat(m))
                        }
                    }
                    Toggle("Move along as I write", isOn: $autoAdvance)
                } label: {
                    Text(String(format: magnification == magnification.rounded() ? "%.0f×" : "%.1f×", magnification))
                        .font(Theme.mono(13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 48, height: 36)
                        .background(Theme.hair, in: Capsule())
                }
                .accessibilityLabel("Zoom window options")
                Spacer(minLength: 0)
                Button {
                    model.showZoomWindow = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(IconButtonStyle(size: 36))
                .accessibilityLabel("Close zoom window")
            }
            .padding(.vertical, 4)
        }
        .padding(10)
        .frame(height: Self.height)
        .glassBackground(cornerRadius: 24)
        .onChange(of: magnification) { _, m in zoom?.magnification = m }
        .onChange(of: autoAdvance) { _, on in
            zoom?.autoAdvance = on
            zoom?.layout()
        }
    }

    private func arrow(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(IconButtonStyle(size: 34))
        .accessibilityLabel(label)
    }
}

/// Hosts the zoom window's canvas (UIKit) inside the panel.
struct ZoomWindowRepresentable: UIViewRepresentable {
    let controller: CanvasController

    func makeUIView(context: Context) -> ZoomHostView {
        let host = ZoomHostView()
        host.zoom = controller.openZoomWindow()
        return host
    }

    func updateUIView(_ uiView: ZoomHostView, context: Context) {}

    static func dismantleUIView(_ uiView: ZoomHostView, coordinator: ()) {
        uiView.zoom?.canvas?.closeZoomWindow()
    }
}

final class ZoomHostView: UIView {
    var zoom: ZoomWindowController? {
        didSet {
            oldValue?.view.removeFromSuperview()
            if let zoom { addSubview(zoom.view) }
        }
    }
    private var placed = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let zoom, bounds.width > 0 else { return }
        zoom.view.frame = bounds
        zoom.layout()
        if !placed {
            placed = true
            zoom.placeInitially()
        }
    }
}
