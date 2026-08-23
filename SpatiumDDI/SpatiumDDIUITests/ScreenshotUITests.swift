//
//  ScreenshotUITests.swift
//  SpatiumDDIUITests
//

import XCTest

/// Drives the whole app against a real control plane and captures each screen.
///
/// Two jobs. It is the only test that proves the tabs render live data end to
/// end — a decode test says the JSON parses, not that the screen built from it
/// draws. And it is how store screenshots get made, so the images shipped to
/// App Store Connect come from the app actually running rather than a mockup.
///
/// Opt-in, because it needs a populated control plane and a token:
///
///   SPATIUM_LIVE_HOST=ddi.example.com \
///   SPATIUM_LIVE_TOKEN=sddi_… \
///   SPATIUM_SHOT_DIR=/tmp/shots \
///     xcodebuild test -only-testing:SpatiumDDIUITests/ScreenshotUITests …
///
/// The simulator must have a biometric enrolment, or the token store refuses to
/// save — which is non-negotiable #2 working as intended, not a bug.
final class ScreenshotUITests: XCTestCase {
    private var host = ""
    private var token = ""
    private var shotDirectory: URL?

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        host = environment["SPATIUM_LIVE_HOST"] ?? ""
        // Prefer a path over the value: xcodebuild dumps the launch
        // environment to its log, so a token passed directly is written to
        // disk in plaintext. See LiveServer.token.
        if let path = environment["SPATIUM_LIVE_TOKEN_FILE"], !path.isEmpty,
            let contents = try? String(contentsOfFile: path, encoding: .utf8)
        {
            token = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            token = environment["SPATIUM_LIVE_TOKEN"] ?? ""
        }
        try XCTSkipIf(host.isEmpty || token.isEmpty, "No live control plane configured.")
        if let directory = environment["SPATIUM_SHOT_DIR"], !directory.isEmpty {
            shotDirectory = URL(fileURLWithPath: directory)
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: directory), withIntermediateDirectories: true
            )
        }
    }

    /// Attaches to the result bundle, and writes a PNG when a directory is set.
    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let shotDirectory else { return }
        try? screenshot.pngRepresentation.write(to: shotDirectory.appendingPathComponent("\(name).png"))
    }

    /// Waits for a tab and opens it, whether it is on the bar or behind "More".
    ///
    /// Six tabs plus search overflow on a phone, and which ones stay visible
    /// depends on the device — so a test that assumes a tab is on the bar
    /// passes on one simulator and fails on another.
    private func openTab(_ app: XCUIApplication, _ name: String) -> Bool {
        let direct = app.tabBars.buttons[name]
        if direct.waitForExistence(timeout: 5) {
            direct.tap()
            return true
        }
        let more = app.tabBars.buttons["More"]
        if more.waitForExistence(timeout: 3) {
            more.tap()
            let row = app.cells.staticTexts[name]
            if row.waitForExistence(timeout: 5) {
                row.tap()
                return true
            }
        }
        return false
    }

    func testCaptureEverySurface() throws {
        let app = XCUIApplication()
        app.launch()

        startAtConnectScreen(app)
        capture(app, "01-connect")

        enterAddress(app, host)

        // A Tailscale or public host presents a chain the system already
        // trusts, so no challenge appears. A private CA does — approve it, the
        // way an operator would.
        if app.staticTexts["Verify Certificate"].waitForExistence(timeout: 25) {
            capture(app, "02-verify-certificate")
            app.buttons["Trust"].tap()
        }

        let proceed = app.buttons["Continue"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 25), "Server never became reachable")
        proceed.tap()

        XCTAssertTrue(
            app.navigationBars["Sign In"].waitForExistence(timeout: 15),
            "A trusted server should lead to sign-in"
        )
        capture(app, "03-sign-in")

        // The field is secure by default; the reveal toggle turns it into a
        // plain one, and typing into a SecureField is unreliable under XCUITest.
        let reveal = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Reveal'")).firstMatch
        if reveal.exists { reveal.tap() }
        let field =
            app.textFields.firstMatch.exists ? app.textFields.firstMatch : app.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "No token field")
        field.tap()
        field.typeText(token)

        app.buttons["Sign In"].tap()

        // Biometry may be asked for on the way in. The simulator answers it via
        // `notifyutil`, which the harness script sends; if nothing appears, the
        // token stored without a prompt and the flow continues.
        let overview = app.navigationBars["Overview"]
        XCTAssertTrue(
            overview.waitForExistence(timeout: 40),
            "Signing in should land on the overview"
        )

        // Let the six concurrent rollup calls settle before capturing, or the
        // screenshot is a page of spinners.
        Thread.sleep(forTimeInterval: 6)
        capture(app, "04-overview")

        for (tab, name) in [
            ("Alerts", "05-alerts"),
            ("IPAM", "06-ipam"),
            ("DNS", "07-dns"),
            ("DHCP", "08-dhcp"),
            ("Server", "09-server"),
        ] {
            if openTab(app, tab) {
                Thread.sleep(forTimeInterval: 3)
                capture(app, name)
            } else {
                XCTFail("Could not open the \(tab) tab")
            }
        }

        // Drill one level into DNS and DHCP: the list screens above prove the
        // tab loads, not that a detail screen built from a second call renders.
        if openTab(app, "DNS") {
            let firstGroup = app.cells.element(boundBy: 0)
            if firstGroup.waitForExistence(timeout: 10) {
                firstGroup.tap()
                Thread.sleep(forTimeInterval: 3)
                capture(app, "10-dns-zones")

                let firstZone = app.cells.element(boundBy: 0)
                if firstZone.waitForExistence(timeout: 10) {
                    firstZone.tap()
                    Thread.sleep(forTimeInterval: 3)
                    capture(app, "11-dns-records")
                }
            }
        }

        if openTab(app, "DHCP") {
            let firstServer = app.cells.element(boundBy: 0)
            if firstServer.waitForExistence(timeout: 10) {
                firstServer.tap()
                Thread.sleep(forTimeInterval: 4)
                capture(app, "12-dhcp-server")
            }
        }

        // Leave the device as it was found: the token is in the Keychain, which
        // outlives the app, and the next run must start from the connect screen.
        startAtConnectScreen(app)
    }
}
