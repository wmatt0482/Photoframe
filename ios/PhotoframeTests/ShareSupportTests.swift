import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Photoframe

/// The PhotoframeKit pieces the share extension depends on.
final class ShareSupportTests: XCTestCase {
    /// A sign-in saved by the build before the share extension (default
    /// access group) moves into the shared group and stays readable.
    func testKeychainMigrationToSharedGroup() throws {
        let service = "com.matthuber.photoframe.tests.migration"
        let legacy = KeychainStore(service: service)
        let shared = KeychainStore(service: service, accessGroup: KeychainStore.sharedAccessGroup)
        try? shared.set(nil, for: "password")
        try? legacy.set(nil, for: "password")
        defer { try? legacy.set(nil, for: "password") }

        try legacy.set("old-secret", for: "password")
        XCTAssertNil(shared.string(for: "password"), "legacy item should not already be in the shared group")
        shared.migrateFromDefaultGroup(account: "password")
        XCTAssertEqual(shared.string(for: "password"), "old-secret")
        // Only one copy is left (the old one was removed).
        XCTAssertEqual(itemCount(service: service, account: "password"), 1)
        // Running it again changes nothing.
        shared.migrateFromDefaultGroup(account: "password")
        XCTAssertEqual(shared.string(for: "password"), "old-secret")
    }

    /// Big photos are decoded as a small thumbnail straight from the file,
    /// the way the share extension loads them.
    func testLoadFromFileURLDownsamples() throws {
        let url = try writeImage(width: 6000, height: 4000, type: .jpeg)
        let image = try ImagePipeline.loadImage(url: url, maxPixelSize: 2400)
        XCTAssertEqual(max(image.width, image.height), 2400)
        XCTAssertEqual(image.width * 2, image.height * 3)
    }

    func testLoadHEICFromFileURL() throws {
        guard let url = try? writeImage(width: 4032, height: 3024, type: .heic) else {
            throw XCTSkip("HEIC encoding is not available on this simulator")
        }
        let image = try ImagePipeline.loadImage(url: url, maxPixelSize: 2400)
        XCTAssertEqual(image.width, 2400)
        XCTAssertEqual(image.height, 1800)
    }

    // MARK: -

    private func itemCount(service: String, account: String) -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return 0 }
        return (result as? [Any])?.count ?? 0
    }

    private struct EncodeFailed: Error {}

    private func writeImage(width: Int, height: Int, type: UTType) throws -> URL {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw EncodeFailed() }
        ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = ctx.makeImage() else { throw EncodeFailed() }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(type.preferredFilenameExtension ?? "img")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw EncodeFailed()
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw EncodeFailed() }
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
