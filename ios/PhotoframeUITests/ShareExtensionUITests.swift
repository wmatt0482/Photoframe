import XCTest

/// Photos -> Share -> Photoframe -> Send to frame, through the real system
/// share sheet, against the local dev server (same rules as
/// PhotoframeUITests: never production, at least one photo in the library).
final class ShareExtensionUITests: XCTestCase {
    private var server: String {
        ProcessInfo.processInfo.environment["PHOTOFRAME_TEST_SERVER"] ?? "http://127.0.0.1:8787"
    }
    private var password: String {
        ProcessInfo.processInfo.environment["PHOTOFRAME_TEST_PASSWORD"] ?? "dev-password"
    }
    private let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")

    override func setUp() {
        continueAfterFailure = false
    }

    /// Signed out in the app: the extension says so and offers nothing else.
    func testShareWhenSignedOut() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset"] // forgets the password
        app.launch()
        XCTAssertTrue(app.textFields["server"].waitForExistence(timeout: 10))
        app.terminate()

        let sheet = try openShareExtension()
        let status = sheet.staticTexts["share-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 20), "no status message")
        XCTAssertEqual(status.label, "Open Photoframe and sign in first.")
        XCTAssertFalse(sheet.buttons["share-send"].exists)
        attach(XCUIScreen.main, "share-signed-out")
        sheet.buttons["share-close"].tap()
        XCTAssertTrue(sheet.buttons["share-cancel"].waitForNonExistence(timeout: 10))
    }

    /// Signed in: the shared photo is cropped, dithered, sent, and shows up
    /// in the app's library.
    func testShareFromPhotosUploads() throws {
        XCTAssertFalse(server.contains("workers.dev"), "UI tests must not run against the production server")
        let app = launchSignedIn()
        let before = photoCells(app).count
        app.terminate()

        let sheet = try openShareExtension()
        let send = sheet.buttons["share-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 30), "extension did not show the crop")
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: send)
        waitForExpectations(timeout: 20)
        attach(XCUIScreen.main, "share-crop")
        send.tap()

        // "Sent" is shown for about a second before the extension closes, so
        // match on the label directly instead of reading it afterwards.
        let sent = sheet.staticTexts.matching(identifier: "share-status")
            .matching(NSPredicate(format: "label BEGINSWITH 'Sent'")).firstMatch
        if !sent.waitForExistence(timeout: 30) {
            let status = sheet.staticTexts["share-status"]
            XCTFail("not sent: \(status.exists ? status.label : "no status shown")")
        }
        attach(XCUIScreen.main, "share-sent")
        // The extension closes itself after a moment.
        XCTAssertTrue(sheet.buttons["share-cancel"].waitForNonExistence(timeout: 10), "extension did not dismiss")

        app.launch()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 15))
        let grew = NSPredicate { _, _ in self.photoCells(app).count == before + 1 }
        expectation(for: grew, evaluatedWith: nil)
        waitForExpectations(timeout: 20)
        attach(app, "library-after-share")
    }

    // MARK: - Helpers

    /// Opens the newest photo in Photos, taps Share and picks Photoframe.
    /// Returns the element tree the extension's UI appears in (Photos hosts it).
    private func openShareExtension() throws -> XCUIApplication {
        photos.terminate()
        photos.launch()
        dismissPhotosWelcome()

        // Photos reopens where it was left: either one photo already open
        // (it has a Share button) or the library grid. Any photo will do.
        let share = photos.buttons["PUOneUpBarButtonItemIdentifierShare"]
        let gridPhoto = photos.images.matching(NSPredicate(format: "identifier BEGINSWITH 'PXGGridLayout' OR label BEGINSWITH 'Photo,'")).firstMatch
        let deadline = Date().addingTimeInterval(15)
        while !share.exists && !gridPhoto.exists && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }
        if !share.exists {
            guard gridPhoto.exists else {
                print(photos.debugDescription)
                throw XCTSkip("no photo in the simulator's library")
            }
            gridPhoto.tap()
        }

        guard share.waitForExistence(timeout: 10) else {
            print(photos.debugDescription)
            XCTFail("no Share button in Photos")
            return photos
        }
        share.tap()

        // Photoframe in the share sheet's app row (or behind "More").
        let target = photos.buttons["Photoframe"].firstMatch
        let cellTarget = photos.cells["Photoframe"].firstMatch
        if !target.waitForExistence(timeout: 10) && !cellTarget.exists {
            print(photos.debugDescription)
            if photos.buttons["More"].exists { photos.buttons["More"].tap() }
        }
        attach(XCUIScreen.main, "share-sheet")
        if target.waitForExistence(timeout: 5) {
            target.tap()
        } else if cellTarget.exists {
            cellTarget.tap()
        } else {
            print(photos.debugDescription)
            XCTFail("Photoframe is not in the share sheet")
        }
        return photos
    }

    private func dismissPhotosWelcome() {
        for label in ["Continue", "Not Now", "OK"] {
            let button = photos.buttons[label]
            if button.waitForExistence(timeout: 2) { button.tap() }
        }
    }

    private func launchSignedIn() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["add-photo"].waitForExistence(timeout: 10) { return app }
        let serverField = app.textFields["server"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 5), "neither library nor sign-in")
        serverField.tap()
        let clear = serverField.buttons["Clear text"]
        if clear.waitForExistence(timeout: 3) { clear.tap() }
        serverField.typeText(server)
        let passwordField = app.secureTextFields["password"]
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["sign-in"].tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 15), "did not reach the library")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for button in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where button.waitForExistence(timeout: 3) {
            button.tap()
            break
        }
        return app
    }

    private func photoCells(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'photo-'")).allElementsBoundByIndex
    }

    private func attach(_ target: XCUIScreenshotProviding, _ name: String) {
        let attachment = XCTAttachment(screenshot: target.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
