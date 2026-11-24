import CoreGraphics
import Foundation
import UIKit
import UniformTypeIdentifiers

/// Gets the one shared picture out of the share sheet's item providers,
/// decoded small. Share extensions are killed at about 120 MB, so a 48 MP
/// photo must never be decoded at full size: everything goes through an
/// ImageIO thumbnail with the long side at most `maxPixelSize`.
enum SharedImageLoader {
    /// Comfortably above the 800x480 panel, with room to zoom in about 2x.
    static let maxPixelSize = 2400

    enum Failure: LocalizedError {
        case noImage
        var errorDescription: String? { "No picture was shared." }
    }

    static func loadImage(from items: [NSExtensionItem]) async throws -> CGImage {
        let providers = items.flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) })
        else { throw Failure.noImage }
        // Photos offers a file (HEIC or JPEG): decode straight from it.
        if let image = try? await loadFile(provider) { return image }
        // Other apps may hand over a URL, Data or a UIImage instead.
        return try await loadItem(provider)
    }

    /// The file only exists until the completion handler returns, so it is
    /// decoded inside the handler.
    private static func loadFile(_ provider: NSItemProvider) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? ImagePipeline.Failure.unreadableImage)
                    return
                }
                continuation.resume(with: Result { try ImagePipeline.loadImage(url: url, maxPixelSize: maxPixelSize) })
            }
        }
    }

    private static func loadItem(_ provider: NSItemProvider) async throws -> CGImage {
        let item = try await provider.loadItem(forTypeIdentifier: UTType.image.identifier)
        switch item {
        case let url as URL:
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try ImagePipeline.loadImage(url: url, maxPixelSize: maxPixelSize)
        case let data as Data:
            return try ImagePipeline.loadImage(data: data, maxPixelSize: maxPixelSize)
        case let image as UIImage:
            return try downsample(image)
        default:
            throw ImagePipeline.Failure.unreadableImage
        }
    }

    /// A UIImage is already decoded; redraw it upright and no larger than
    /// `maxPixelSize` so the crop works on a known, small bitmap.
    private static func downsample(_ image: UIImage) throws -> CGImage {
        let longSide = max(image.size.width * image.scale, image.size.height * image.scale)
        guard longSide > 0 else { throw ImagePipeline.Failure.unreadableImage }
        let ratio = min(1, CGFloat(maxPixelSize) / longSide)
        let size = CGSize(width: (image.size.width * image.scale * ratio).rounded(),
                          height: (image.size.height * image.scale * ratio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let drawn = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let cgImage = drawn.cgImage else { throw ImagePipeline.Failure.unreadableImage }
        return cgImage
    }
}
