//
//  UITestSupport.swift
//  SpatiumDDIUITests
//

import XCTest

/// Trust decisions live in the Keychain, which outlives an app install and is
/// shared by every test on the device. A test that pins a certificate and walks
/// away leaves the next run connecting silently to an already-trusted server —
/// which looks exactly like the challenge screen being broken.
///
/// These helpers make each test start from a known state instead of inheriting
/// whatever the last one left behind.
extension XCTestCase {

    /// Types an address into the connect screen and submits it.
    func enterAddress(_ app: XCUIApplication, _ address: String) {
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20), "Address field never appeared")
        if (field.value as? String ?? "").isEmpty || field.value as? String == "ddi.internal.example" {
            field.tap()
            field.typeText(address)
        }
        app.buttons["Connect"].tap()
    }

    /// Connects and guarantees the certificate challenge is actually exercised.
    ///
    /// If a previous run already pinned this server, forgets it and reconnects
    /// so the test measures the challenge rather than skipping past it.
    func connectExpectingChallenge(_ app: XCUIApplication, _ address: String) {
        enterAddress(app, address)
        if app.staticTexts["Verify Certificate"].waitForExistence(timeout: 20) { return }

        let forget = app.buttons["Forget Trusted Certificate"]
        XCTAssertTrue(
            forget.waitForExistence(timeout: 15),
            "Neither challenged nor connected — the server is unreachable"
        )
        forget.tap()
        app.buttons["Connect"].tap()
        XCTAssertTrue(
            app.staticTexts["Verify Certificate"].waitForExistence(timeout: 20),
            "Certificate was forgotten but the next connection wasn't challenged"
        )
    }

    /// Drops any pin this test created, so the next run starts clean.
    func forgetTrustedCertificate(_ app: XCUIApplication) {
        let forget = app.buttons["Forget Trusted Certificate"]
        if forget.waitForExistence(timeout: 10) { forget.tap() }
    }
}
