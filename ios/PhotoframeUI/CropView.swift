import SwiftUI

/// The crop: the dithered preview (or the original colours) at the panel's
/// aspect ratio. Drag to move, pinch to zoom. Shared by the app's editor and
/// the share extension.
struct CropView: View {
    @Bindable var editor: EditorModel
    @State private var dragStart: CropGeometry?
    @State private var pinchStart: CropGeometry?

    var body: some View {
        GeometryReader { proxy in
            let scale = Double(editor.geometry.viewWidth) / max(1, proxy.size.width)
            ZStack {
                Color.white
                if let preview = editor.preview {
                    Image(decorative: editor.showOriginal ? preview.original : preview.dithered, scale: 1)
                        .resizable()
                        .interpolation(.none)
                } else {
                    ProgressView()
                }
            }
            .contentShape(Rectangle())
            .gesture(drag(scale: scale).simultaneously(with: pinch))
        }
        .aspectRatio(editor.aspectRatio, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Photo crop")
        .accessibilityHint("Drag to move.")
        .accessibilityIdentifier("crop")
        .accessibilityAction(named: "Move left") { editor.move(dx: -40, dy: 0) }
        .accessibilityAction(named: "Move right") { editor.move(dx: 40, dy: 0) }
        .accessibilityAction(named: "Move up") { editor.move(dx: 0, dy: -40) }
        .accessibilityAction(named: "Move down") { editor.move(dx: 0, dy: 40) }
    }

    private func drag(scale: Double) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? editor.geometry
                if dragStart == nil { dragStart = start }
                var g = editor.geometry
                g.offsetX = start.offsetX + value.translation.width * scale
                g.offsetY = start.offsetY + value.translation.height * scale
                g.clampOffset()
                editor.geometry = g
            }
            .onEnded { _ in dragStart = nil }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? editor.geometry
                if pinchStart == nil { pinchStart = start }
                var g = editor.geometry
                g.zoom = start.zoom * value.magnification
                g.clampOffset()
                editor.geometry = g
            }
            .onEnded { _ in pinchStart = nil }
    }
}
