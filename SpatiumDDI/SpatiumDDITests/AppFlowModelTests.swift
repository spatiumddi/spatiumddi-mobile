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
}
