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
        app.buttons["Change Server"].tap()
        enterAddress(app, "localhost:8443")
        forgetTrustedCertificate(app)
    }
}
