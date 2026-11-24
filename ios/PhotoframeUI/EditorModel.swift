import CoreGraphics
import Foundation
import Observation

// Shared by the app (EditorView) and the share extension (ShareView).

/// State of the crop-and-send screen. Every change re-renders the dithered
/// preview on the pipeline actor; while one render runs, further changes are
/// coalesced into a single follow-up render (like requestAnimationFrame on
/// the web page), so dragging stays responsive.
@MainActor
@Observable
final class EditorModel: Identifiable {
    let id = UUID()
    let image: CGImage
    let pipeline: ImagePipeline

    var geometry: CropGeometry { didSet { if geometry != oldValue { requestRender() } } }
    var adjustments = Adjustments() { didSet { if adjustments != oldValue { requestRender() } } }
    var showOriginal = false

    private(set) var preview: ImagePipeline.Preview?
    var error: String?
    var sending = false

    private var rendering = false
    private var dirty = false

    init(image: CGImage, viewSize: (width: Int, height: Int), pipeline: ImagePipeline) {
        self.image = image
        self.pipeline = pipeline
        geometry = CropGeometry(viewWidth: viewSize.width, viewHeight: viewSize.height,
                                imageWidth: image.width, imageHeight: image.height)
        requestRender()
    }

    var aspectRatio: CGFloat { CGFloat(geometry.viewWidth) / CGFloat(geometry.viewHeight) }

    func requestRender() {
        if rendering { dirty = true; return }
        rendering = true
        Task {
            repeat {
                dirty = false
                let (geometry, adjustments) = (self.geometry, self.adjustments)
                do {
                    preview = try await pipeline.preview(image: image, geometry: geometry, adjustments: adjustments)
                } catch {
                    self.error = error.localizedDescription
                }
            } while dirty
            rendering = false
        }
    }

    func move(dx: Double, dy: Double) {
        var g = geometry
        g.offsetX += dx
        g.offsetY += dy
        g.clampOffset()
        geometry = g
    }

    func makeUpload(orientation: Orientation, flip: Bool) async throws -> ImagePipeline.Upload {
        try await pipeline.makeUpload(image: image, geometry: geometry, adjustments: adjustments,
                                      orientation: orientation, flip: flip)
    }
}
