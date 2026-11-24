import XCTest
@testable import Photoframe

final class APITests: XCTestCase {
    func testParseServer() {
        XCTAssertEqual(ServerCredentials.parseServer(" https://example.com/ ")?.absoluteString, "https://example.com")
        XCTAssertEqual(ServerCredentials.parseServer("http://127.0.0.1:8787")?.absoluteString, "http://127.0.0.1:8787")
        XCTAssertNil(ServerCredentials.parseServer("example.com"))
        XCTAssertNil(ServerCredentials.parseServer("ftp://example.com"))
    }

    func testDecodesState() throws {
        let json = """
        {"settings":{"orientation":"portrait","flip":true,"checkMinutes":30,"rotateMinutes":1440,"order":"shuffle"},
         "frame":{"seenAt":1764000000000,"batteryMv":4012,"batteryPct":87,"onUsb":false,"rssi":-61,"firmware":"1.0","showing":null},
         "currentId":null,"nextId":"abc",
         "photos":[{"id":"abc","createdAt":1764000000000,"caption":"","source":"web","shownCount":0,"lastShownAt":null}]}
        """
        let state = try JSONDecoder().decode(LibraryState.self, from: Data(json.utf8))
        XCTAssertEqual(state.settings.orientation, .portrait)
        XCTAssertEqual(state.frame?.batteryPct, 87)
        XCTAssertEqual(state.photos.first?.shownCount, 0)
        XCTAssertEqual(state.nextId, "abc")
    }

    func testKeychainRoundTrip() throws {
        let store = KeychainStore(service: "com.matthuber.photoframe.tests")
        try store.set("secret", for: "t")
        XCTAssertEqual(store.string(for: "t"), "secret")
        try store.set("changed", for: "t")
        XCTAssertEqual(store.string(for: "t"), "changed")
        try store.set(nil, for: "t")
        XCTAssertNil(store.string(for: "t"))
    }

    func testMultipartLayout() {
        var form = MultipartForm()
        form.addFile(name: "frame", filename: "frame.bin", type: "application/octet-stream", data: Data([1, 2, 3]))
        let body = String(decoding: form.finish(), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"frame\"; filename=\"frame.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n"))
        XCTAssertTrue(body.hasSuffix("--\(form.boundary)--\r\n"))
    }
}
