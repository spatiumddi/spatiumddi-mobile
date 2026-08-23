//
//  SignInFlowUITests.swift
//  SpatiumDDIUITests
//

import XCTest

/// Covers the hand-off from "server is trusted" to "prove who you are".
///
/// Needs the stub from `scripts/dev-control-plane.sh`; skips without it.
final class SignInFlowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SPATIUM_STUB_RUNNING"] == "1",
            "Stub control plane not running."
        )
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Connect, approve the certificate, continue — and land on sign-in.
    func testTrustedServerLeadsToSignIn() throws {
        let app = XCUIApplication()
        app.launch()

        connectExpectingChallenge(app, "localhost:8443")
        app.buttons["Trust"].tap()

        let proceed = app.buttons["Continue"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 15), "No way forward from a reachable server")
        proceed.tap()

        XCTAssertTrue(
            app.navigationBars["Sign In"].waitForExistence(timeout: 10),
            "Continuing from a trusted server should ask for credentials"
        )
        // The server carried through, so the operator can see what they're signing in to.
        // LabeledContent folds its label and value into one element, so match on
        // either rather than expecting a standalone static text.
        let namesServer = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                    "localhost:8443", "localhost:8443"
                )
            )
            .firstMatch
        XCTAssertTrue(namesServer.waitForExistence(timeout: 5), "Sign-in should name the server")
        attach(app, "05-sign-in")

        // Return to the connect screen and drop the pin, so re-runs start clean.
        openConnectForm(app)
        enterAddress(app, "localhost:8443")
        forgetTrustedCertificate(app)
    }

    /// The token field masks by default; pasting a credential blind is exactly
    /// when an operator needs to check it.
    func testTokenCanBeRevealedAndHiddenAgain() throws {
        let app = XCUIApplication()
        app.launch()

        connectExpectingChallenge(app, "localhost:8443")
        app.buttons["Trust"].tap()

        let proceed = app.buttons["Continue"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 15))
        proceed.tap()
        XCTAssertTrue(app.navigationBars["Sign In"].waitForExistence(timeout: 10))

        // Masked to begin with: a secure field, and the control offers to show.
        let reveal = app.buttons["Show token"]
        XCTAssertTrue(reveal.waitForExistence(timeout: 5), "No reveal control on the token field")
        XCTAssertTrue(app.secureTextFields.firstMatch.exists, "Token should start masked")

        let secure = app.secureTextFields.firstMatch
        secure.tap()
        secure.typeText("sddi_visible_check")

        reveal.tap()
        // Revealed: now a plain field, carrying the text that was typed.
        let plain = app.textFields.firstMatch
        XCTAssertTrue(plain.waitForExistence(timeout: 5), "Revealing should show a plain field")
        XCTAssertEqual(plain.value as? String, "sddi_visible_check", "Revealing must not lose the token")

        app.buttons["Hide token"].tap()
        XCTAssertTrue(
            app.secureTextFields.firstMatch.waitForExistence(timeout: 5),
            "Hiding should mask the token again"
        )

        // Leave no pin behind.
        openConnectForm(app)
        enterAddress(app, "localhost:8443")
        forgetTrustedCertificate(app)
    }

}
