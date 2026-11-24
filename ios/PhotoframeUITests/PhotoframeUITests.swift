import XCTest

/// Sign in -> pick a photo -> send -> it appears in the library.
///
/// Needs a local dev server (see README "Test without the hardware") and at
/// least one photo in the simulator's library (`xcrun simctl addmedia`).
/// Never point this at the production server: it uploads.
final class PhotoframeUITests: XCTestCase {
    private var server: String {
        ProcessInfo.processInfo.environment["PHOTOFRAME_TEST_SERVER"] ?? "http://127.0.0.1:8787"
    }
    private var password: String {
        ProcessInfo.processInfo.environment["PHOTOFRAME_TEST_PASSWORD"] ?? "dev-password"
    }

    override func setUp() {
        continueAfterFailure = false
    }

    /// Launches signed out and signs in to the local server.
    private func launchAndSignIn() -> XCUIApplication {
        XCTAssertFalse(server.contains("workers.dev"), "UI tests must not run against the production server")
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset"]
        app.launch()

        let serverField = app.textFields["server"]
        XCTAssertTrue(serverField.waitForExistence(timeout: 10))
        serverField.tap()
        let clear = serverField.buttons["Clear text"]
        if clear.waitForExistence(timeout: 3) { clear.tap() }
        XCTAssertTrue(["", "Server"].contains(serverField.value as? String ?? ""), "server field did not clear")
        serverField.typeText(server)
        let passwordField = app.secureTextFields["password"]
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["sign-in"].tap()

        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 15), "did not reach the library")
        dismissSavePassword(app)
        return app
    }

    func testSignInPickAndUpload() throws {
        let app = launchAndSignIn()
        let add = app.buttons["add-photo"]
        attach(app, "library-before")
        let before = photoCells(app).count

        // Pick the first photo in the system picker (it runs out of process).
        Thread.sleep(forTimeInterval: 1.5) // let the password sheet finish animating away
        add.tap()
        Thread.sleep(forTimeInterval: 2)
        let picked = pickFirstPhoto(app)
        XCTAssertTrue(picked, "could not pick a photo")

        // Editor: wait for the dithered preview, then send.
        let send = app.buttons["send"]
        XCTAssertTrue(send.waitForExistence(timeout: 20), "editor did not open")
        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: send)
        waitForExpectations(timeout: 20)
        attach(app, "editor")
        send.tap()

        // Back in the library with one more photo.
        XCTAssertTrue(add.waitForExistence(timeout: 30))
        let grew = NSPredicate { _, _ in self.photoCells(app).count == before + 1 }
        expectation(for: grew, evaluatedWith: nil)
        waitForExpectations(timeout: 30)
        attach(app, "library-after")
    }

    /// Show next, settings and delete on a photo uploaded by the test above.
    func testPhotoActionsAndSettings() throws {
        let app = launchAndSignIn()
        Thread.sleep(forTimeInterval: 1.5)
        let cells = photoCells(app)
        guard let first = cells.first else { throw XCTSkip("no photos on the local server") }
        let before = cells.count

        // Show next -> badge says "Up next".
        tap(first, until: app.buttons["show-next"], in: app)
        attach(app, "detail")
        app.buttons["show-next"].tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
        let upNext = NSPredicate { _, _ in 
            let label = self.photoCells(app).first?.label ?? ""
            // "On the frame" wins over "Up next" when the photo is already showing (as on the web page).
            return label.contains("Up next") || label.contains("On the frame")
        }
        expectation(for: upNext, evaluatedWith: nil)
        waitForExpectations(timeout: 10)

        // Settings: flip on, save; then flip back off and save.
        for _ in 0..<2 {
            app.buttons["settings"].tap()
            let flip = app.switches["Pictures appear upside down, flip them"]
            XCTAssertTrue(flip.waitForExistence(timeout: 10))
            attach(app, "settings")
            flip.switches.firstMatch.tap()
            app.buttons["save-settings"].tap()
            XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
            Thread.sleep(forTimeInterval: 1)
        }

        // Delete the newest photo.
        photoCells(app)[0].tap()
        XCTAssertTrue(app.buttons["delete"].waitForExistence(timeout: 10))
        app.buttons["delete"].tap()
        let confirm = app.sheets.buttons["Delete"].exists ? app.sheets.buttons["Delete"] : app.buttons.matching(identifier: "Delete").element(boundBy: 1)
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["add-photo"].waitForExistence(timeout: 10))
        let shrank = NSPredicate { _, _ in self.photoCells(app).count == before - 1 }
        expectation(for: shrank, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
    }

    /// Taps, and taps again if a late system sheet (the password prompt) ate the first tap.
    private func tap(_ element: XCUIElement, until result: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<3 {
            element.tap()
            if result.waitForExistence(timeout: 4) { return }
            if app.buttons["Not Now"].exists { app.buttons["Not Now"].tap() }
        }
        XCTFail("tapping \(element) did not show \(result)")
    }

    /// iOS offers to save the password after signing in; it covers the screen.
    private func dismissSavePassword(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            for button in [app.buttons["Not Now"], springboard.buttons["Not Now"]] where button.exists {
                button.tap()
                return
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private func photoCells(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'photo-'")).allElementsBoundByIndex
    }

    private func pickFirstPhoto(_ app: XCUIApplication) -> Bool {
        // The system picker's thumbnails (newest first on iOS 27). The picker
        // runs out of process but its grid shows up in the app's tree.
        let thumbnail = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        guard thumbnail.waitForExistence(timeout: 20) else {
            print(app.debugDescription)
            return false
        }
        attach(XCUIScreen.main, "picker")
        thumbnail.tap()
        return true
    }

    private func attach(_ target: XCUIScreenshotProviding, _ name: String) {
        let attachment = XCTAttachment(screenshot: target.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
