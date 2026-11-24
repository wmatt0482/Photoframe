import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where the photo sits in the crop, in the same terms as the web editor
/// (server/public/app.js): `zoom` scales source pixels to view pixels, and the
/// offsets move the picture's centre away from the view's centre.
public struct CropGeometry: Equatable, Sendable {
    public let viewWidth: Int
    public let viewHeight: Int
    public let imageWidth: Int
    public let imageHeight: Int
    public var zoom: Double
    public var offsetX: Double = 0
    public var offsetY: Double = 0

    /// Starts as the web page does: the picture fills the frame, centred.
    public init(viewWidth: Int, viewHeight: Int, imageWidth: Int, imageHeight: Int) {
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        zoom = 1
        zoom = coverZoom
    }

    /// Whole picture visible.
    public var minZoom: Double { min(Double(viewWidth) / Double(imageWidth), Double(viewHeight) / Double(imageHeight)) }
    /// Picture fills the frame.
    public var coverZoom: Double { max(Double(viewWidth) / Double(imageWidth), Double(viewHeight) / Double(imageHeight)) }
    public var maxZoom: Double { coverZoom * 4 }

    /// 0...1 slider position, logarithmic, from "whole picture" to 4x "fills".
    public var slider: Double {
        get { log(zoom / minZoom) / log(maxZoom / minZoom) }
        set {
            zoom = minZoom * pow(maxZoom / minZoom, min(1, max(0, newValue)))
            clampOffset()
        }
    }

    /// Keeps the picture from being dragged off the view.
    public mutating func clampOffset() {
        zoom = min(maxZoom, max(minZoom, zoom))
        let maxX = abs(Double(imageWidth) * zoom - Double(viewWidth)) / 2
        let maxY = abs(Double(imageHeight) * zoom - Double(viewHeight)) / 2
        offsetX = max(-maxX, min(maxX, offsetX))
        offsetY = max(-maxY, min(maxY, offsetY))
    }
}

/// Contrast and saturation multipliers. Stored as whole steps of 0.05 (the web
/// sliders' step) so values like 1.15 are exactly the doubles the web page
/// parses from its sliders.
public struct Adjustments: Equatable, Sendable {
    public static let stepsPerUnit = 20
    public static let contrastSteps = 16...32   // 0.8 ... 1.6
    public static let saturationSteps = 12...40 // 0.6 ... 2.0

    public var contrastStep = 23   // 1.15, the web default
    public var saturationStep = 26 // 1.3, the web default

    public init() {}

    public var contrast: Double { Double(contrastStep) / Double(Self.stepsPerUnit) }
    public var saturation: Double { Double(saturationStep) / Double(Self.stepsPerUnit) }
}

/// Everything between "the person picked a photo" and "bytes to POST":
/// load -> crop to RGBA -> epd.js (adjust, dither, pack) -> frame + preview.
/// It is an actor so the heavy work runs off the main thread, one job at a
/// time, on its own JavaScriptCore context.
public actor ImagePipeline {
    public struct Preview: @unchecked Sendable {
        /// The crop as the panel will show it, in the six inks.
        public let dithered: CGImage
        /// The crop before adjustment and dithering.
        public let original: CGImage
    }

    public struct Upload: Sendable {
        public let frame: Data
        public let previewJPEG: Data
    }

    public enum Failure: LocalizedError {
        case unreadableImage
        case renderFailed
        public var errorDescription: String? {
            switch self {
            case .unreadableImage: return "That file could not be opened as a picture."
            case .renderFailed: return "The picture could not be prepared."
            }
        }
    }

    private let bundle: Bundle
    private var script: EPDScript?

    public init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    private func epd() throws -> EPDScript {
        if let script { return script }
        let loaded = try EPDScript(bundle: bundle)
        script = loaded
        return loaded
    }

    public func viewSize(for orientation: Orientation) throws -> (width: Int, height: Int) {
        try epd().viewSize(orientation)
    }

    /// Decodes a photo the right way up, scaled down so the long side is at
    /// most `maxPixelSize` (plenty for a 4x zoom on an 800-pixel view).
    public nonisolated static func loadImage(data: Data, maxPixelSize: Int = 4000) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw Failure.unreadableImage }
        return try thumbnail(source, maxPixelSize: maxPixelSize)
    }

    /// The same, reading straight from a file (HEIC, JPEG, PNG...) so the
    /// whole file never has to sit in memory. ImageIO decodes only what the
    /// thumbnail needs, which keeps the share extension far under its limit.
    public nonisolated static func loadImage(url: URL, maxPixelSize: Int = 4000) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw Failure.unreadableImage }
        return try thumbnail(source, maxPixelSize: maxPixelSize)
    }

    private nonisolated static func thumbnail(_ source: CGImageSource, maxPixelSize: Int) throws -> CGImage {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { throw Failure.unreadableImage }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize, max(w, h)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.unreadableImage
        }
        return image
    }

    public func preview(image: CGImage, geometry: CropGeometry, adjustments: Adjustments) throws -> Preview {
        let rgba = try Self.cropRGBA(image: image, geometry: geometry)
        let dithered = try epd().dither(rgba: rgba, width: geometry.viewWidth, height: geometry.viewHeight,
                                        contrast: adjustments.contrast, saturation: adjustments.saturation)
        guard let ditheredImage = Self.makeImage(rgba: dithered.previewRGBA, width: geometry.viewWidth, height: geometry.viewHeight),
              let original = Self.makeImage(rgba: rgba, width: geometry.viewWidth, height: geometry.viewHeight)
        else { throw Failure.renderFailed }
        return Preview(dithered: ditheredImage, original: original)
    }

    /// What the web page's "Send to frame" builds: the packed frame for the
    /// current settings, and a half-size JPEG of the undithered crop.
    public func makeUpload(image: CGImage, geometry: CropGeometry, adjustments: Adjustments,
                           orientation: Orientation, flip: Bool) throws -> Upload {
        let script = try epd()
        let rgba = try Self.cropRGBA(image: image, geometry: geometry)
        let dithered = try script.dither(rgba: rgba, width: geometry.viewWidth, height: geometry.viewHeight,
                                         contrast: adjustments.contrast, saturation: adjustments.saturation)
        let frame = try script.pack(indices: dithered.indices, orientation: orientation, flip: flip)

        let small = try Self.cropRGBA(image: image, geometry: geometry, scale: 0.5)
        let sw = Int(Double(geometry.viewWidth) * 0.5), sh = Int(Double(geometry.viewHeight) * 0.5)
        guard let smallImage = Self.makeImage(rgba: small, width: sw, height: sh),
              let jpeg = Self.jpeg(smallImage, quality: 0.82) else { throw Failure.renderFailed }
        return Upload(frame: frame, previewJPEG: jpeg)
    }

    // MARK: - CoreGraphics helpers

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Draws the photo into a white view-sized canvas, like drawSource() in
    /// app.js, and returns opaque RGBA bytes.
    public nonisolated static func cropRGBA(image: CGImage, geometry g: CropGeometry, scale: Double = 1) throws -> Data {
        let cw = Int(Double(g.viewWidth) * scale), ch = Int(Double(g.viewHeight) * scale)
        var data = Data(count: cw * ch * 4)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: cw, height: ch, bitsPerComponent: 8,
                                      bytesPerRow: cw * 4, space: sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
            ctx.interpolationQuality = .high
            let w = Double(g.imageWidth) * g.zoom * scale
            let h = Double(g.imageHeight) * g.zoom * scale
            let x = (Double(cw) - w) / 2 + g.offsetX * scale
            let top = (Double(ch) - h) / 2 + g.offsetY * scale
            // CoreGraphics puts the origin at the bottom left.
            ctx.draw(image, in: CGRect(x: x, y: Double(ch) - top - h, width: w, height: h))
            return true
        }
        guard ok else { throw Failure.renderFailed }
        return data
    }

    public nonisolated static func makeImage(rgba: Data, width: Int, height: Int) -> CGImage? {
        guard rgba.count == width * height * 4, let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    public nonisolated static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
