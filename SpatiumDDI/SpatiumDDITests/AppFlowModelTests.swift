//
//  AppFlowModelTests.swift
//  SpatiumDDITests
//

import Foundation
import Testing

@testable import SpatiumDDI

@MainActor
struct AppFlowModelTests {
    private func isolatedFlow() -> (AppFlowModel, ServerAddress) {
        let suite = "io.spatiumddi.tests.\(UUID().uuidString)"
        let flow = AppFlowModel(
            tokens: TokenStore(service: suite),
            defaults: UserDefaults(suiteName: suite)!
        )
        return (flow, ServerAddress(host: "ddi.internal.example", port: 8443))
    }

    @Test("A fresh install starts by asking for a server")
    func startsAtChooseServer() {
        let (flow, _) = isolatedFlow()
        #expect(flow.stage == .chooseServer)
        #expect(flow.token == nil)
    }

    @Test("Connecting with no stored token goes to sign-in")
    func connectingAsksToSignIn() {
        let (flow, address) = isolatedFlow()
        flow.connected(to: address)
        #expect(flow.stage == .signIn(address))
    }

    @Test("A rejected credential ends the session rather than stranding the operator")
    func rejectionReturnsToSignIn() {
        let (flow, address) = isolatedFlow()
        flow.connected(to: address)
        flow.signedIn(with: "sddi_example", to: address)
        #expect(flow.stage == .signedIn(address))
        #expect(flow.token != nil)

        flow.sessionRejected()

        // Back to sign-in, and the dead credential is not held on to: it would
        // fail identically on every future unlock.
        #expect(flow.stage == .signIn(address))
        #expect(flow.token == nil)
    }

    @Test("A rejection outside a signed-in session changes nothing")
    func rejectionIgnoredWhenNotSignedIn() {
        let (flow, address) = isolatedFlow()
        flow.connected(to: address)
        flow.sessionRejected()
        #expect(flow.stage == .signIn(address))
    }

    @Test("Backgrounding locks a signed-in session and drops the in-memory token")
    func backgroundingLocks() {
        let (flow, address) = isolatedFlow()
        flow.connected(to: address)
        flow.signedIn(with: "sddi_example", to: address)

        flow.lockForBackground()

        #expect(flow.stage == .locked(address, message: nil))
        #expect(flow.token == nil, "A backgrounded app must not hold the credential")
    }

    @Test("Changing server clears the session")
    func changingServerClears() {
        let (flow, address) = isolatedFlow()
        flow.connected(to: address)
        flow.signedIn(with: "sddi_example", to: address)
        flow.changeServer()
        #expect(flow.stage == .chooseServer)
        #expect(flow.token == nil)
    }

    /// Scanning a code that carries both server and token should land the
    /// operator inside, not on a pre-filled form. They chose which code to
    /// scan and pressed the button; a second confirmation of the same decision
    /// is ceremony.
    @Test("A scanned, already-enrolled token goes straight to signed in")
    func enrolledSkipsSignIn() {
        let (flow, address) = isolatedFlow()

        flow.enrolled(with: "sddi_abc", to: address)

        #expect(flow.stage == .signedIn(address))
        #expect(flow.token == "sddi_abc")
        #expect(flow.pendingToken == nil)
    }

    /// The fallback matters as much as the happy path: a code whose token the
    /// server rejects must land on sign-in with the token in place, so it can
    /// be corrected rather than re-scanned.
    @Test("A token that failed to enrol is carried to sign-in for correction")
    func failedEnrolmentPrefills() {
        let (flow, address) = isolatedFlow()

        flow.connected(to: address, pendingToken: "sddi_bad")

        #expect(flow.stage == .signIn(address))
        #expect(flow.pendingToken == "sddi_bad")
        #expect(flow.token == nil, "a rejected token is not a session")
    }

    @Test("Changing server drops a carried token")
    func changingServerDropsPendingToken() {
        let (flow, address) = isolatedFlow()
        flow.connected(to: address, pendingToken: "sddi_abc")

        flow.changeServer()

        #expect(flow.pendingToken == nil, "a token scanned for one server must not follow to another")
        #expect(flow.stage == .chooseServer)
    }
}
