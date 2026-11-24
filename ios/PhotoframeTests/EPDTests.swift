import CryptoKit
import XCTest
@testable import Photoframe

/// Proves the app's JavaScriptCore run of server/public/epd.js gives the same
/// bytes as the web page. The expected hashes come from Node running the same
/// file (ios/tools/make-epd-fixture.mjs); re-run that when epd.js changes.
final class EPDTests: XCTestCase {
    struct Case: Decodable {
        let orientation: String
        let flip: Bool
        let contrast: Double
        let saturation: Double
        let width: Int
        let height: Int
        let inputSHA256: String
        let indicesSHA256: String
        let previewSHA256: String
        let frameSHA256: String
    }

    /// Must match fixtureRGBA() in ios/tools/make-epd-fixture.mjs.
    static func fixtureRGBA(width: Int, height: Int) -> Data {
        var rgba = Data(count: width * height * 4)
        rgba.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    p[i] = UInt8((x * 3 + y * 5) % 256)
                    p[i + 1] = UInt8((x * y + 7 * x) % 256)
                    p[i + 2] = UInt8(((x ^ y) * 11) % 256)
                    p[i + 3] = 255
                }
            }
        }
        return rgba
    }

    static func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testByteIdenticalToNode() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "epd-fixture", withExtension: "json"))
        let cases = try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
        XCTAssertEqual(cases.count, 4)
        let epd = try EPDScript(bundle: .main)
        XCTAssertEqual(epd.frameBytes, 192_000)

        for c in cases {
            let orientation = try XCTUnwrap(Orientation(rawValue: c.orientation))
            let size = try epd.viewSize(orientation)
            XCTAssertEqual(size.width, c.width)
            XCTAssertEqual(size.height, c.height)

            let input = Self.fixtureRGBA(width: c.width, height: c.height)
            XCTAssertEqual(Self.sha(input), c.inputSHA256, "fixture input differs from Node's")

            let dithered = try epd.dither(rgba: input, width: c.width, height: c.height,
                                          contrast: c.contrast, saturation: c.saturation)
            let frame = try epd.pack(indices: dithered.indices, orientation: orientation, flip: c.flip)
            let label = "\(c.orientation) flip=\(c.flip) contrast=\(c.contrast) saturation=\(c.saturation)"
            XCTAssertEqual(Self.sha(dithered.indices), c.indicesSHA256, "indices: \(label)")
            XCTAssertEqual(Self.sha(dithered.previewRGBA), c.previewSHA256, "preview: \(label)")
            XCTAssertEqual(frame.count, 192_000)
            XCTAssertEqual(Self.sha(frame), c.frameSHA256, "frame: \(label)")
        }
    }

    /// The slider steps must produce exactly the doubles the web page parses.
    func testAdjustmentDefaultsMatchWebSliders() {
        let a = Adjustments()
        XCTAssertEqual(a.contrast, Double("1.15"))
        XCTAssertEqual(a.saturation, Double("1.3"))
        XCTAssertEqual(Double(Adjustments.contrastSteps.lowerBound) / 20, Double("0.8"))
        XCTAssertEqual(Double(Adjustments.saturationSteps.upperBound) / 20, Double("2"))
    }

    func testModuleTransformRefusesUnknownSyntax() {
        XCTAssertThrowsError(try EPDScript(moduleSource: "import { x } from './y.js';\nexport const FRAME_BYTES = 1;"))
        XCTAssertThrowsError(try EPDScript(moduleSource: "export default function () {}"))
    }

    func testCropAndUploadShapes() async throws {
        // A 300x200 red-left / blue-right test picture.
        let w = 300, h = 200
        var rgba = Data(count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                rgba[i] = x < w / 2 ? 255 : 0
                rgba[i + 2] = x < w / 2 ? 0 : 255
                rgba[i + 3] = 255
            }
        }
        let image = try XCTUnwrap(ImagePipeline.makeImage(rgba: rgba, width: w, height: h))
        let pipeline = ImagePipeline(bundle: .main)
        let size = try await pipeline.viewSize(for: .portrait)
        var geometry = CropGeometry(viewWidth: size.width, viewHeight: size.height, imageWidth: w, imageHeight: h)
        XCTAssertEqual(geometry.zoom, geometry.coverZoom)
        geometry.offsetX = 10_000
        geometry.clampOffset()
        XCTAssertEqual(geometry.offsetX, (Double(w) * geometry.zoom - Double(size.width)) / 2, accuracy: 0.001)

        let upload = try await pipeline.makeUpload(image: image, geometry: geometry, adjustments: Adjustments(),
                                                   orientation: .portrait, flip: false)
        XCTAssertEqual(upload.frame.count, 192_000)
        XCTAssertEqual(Array(upload.previewJPEG.prefix(2)), [0xFF, 0xD8])
        let preview = try await pipeline.preview(image: image, geometry: geometry, adjustments: Adjustments())
        XCTAssertEqual(preview.dithered.width, 480)
        XCTAssertEqual(preview.dithered.height, 800)
    }

    func testDitherSpeed() throws {
        let epd = try EPDScript(bundle: .main)
        let input = Self.fixtureRGBA(width: 800, height: 480)
        measure {
            _ = try? epd.dither(rgba: input, width: 800, height: 480, contrast: 1.15, saturation: 1.3)
        }
    }
}
