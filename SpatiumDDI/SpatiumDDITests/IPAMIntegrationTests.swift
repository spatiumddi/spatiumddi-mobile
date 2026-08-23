//
//  IPAMIntegrationTests.swift
//  SpatiumDDITests
//

import Foundation
import SpatiumAPI
import Testing

@testable import SpatiumDDI

/// Where a live control plane is, if one was configured for this run.
///
/// Declared outside the suite: a `@Suite` trait cannot reference a static on the
/// type it annotates without the macro expansion becoming circular.
enum LiveServer {
    /// The app is HTTPS-only, so an HTTP lab is reached through
    /// `./scripts/dev-control-plane.sh proxy <upstream>`.
    static var address: ServerAddress? {
        guard let raw = ProcessInfo.processInfo.environment["SPATIUM_LIVE_HOST"],
            let parsed = try? ServerAddress.parse(raw)
        else { return nil }
        return parsed
    }

    static var token: String? {
        ProcessInfo.processInfo.environment["SPATIUM_LIVE_TOKEN"].flatMap {
            $0.isEmpty ? nil : $0
        }
    }

    static var isConfigured: Bool { address != nil && token != nil }
}

/// Exercises the app's own path to a real control plane: the trust delegate, the
/// session it owns, and the generated client decoding live responses.
///
/// The package's ContractTests cover the client in isolation. This covers the
/// wiring around it — that the pinned session is the one the client actually
/// uses, and that IPAM browse has data to render.
@Suite(.enabled(if: LiveServer.isConfigured))
@MainActor
struct IPAMIntegrationTests {
    /// Approves the server's certificate if the system won't validate it.
    ///
    /// A publicly-valid chain needs no approval, so this is a no-op there — the
    /// same code path an operator meets with a properly certificated server.
    private func pinnedSession() async throws -> (ControlPlaneSession, TrustStore) {
        let address = try #require(LiveServer.address)
        let token = try #require(LiveServer.token)
        let store = TrustStore(keychain: KeychainStore(service: "io.spatiumddi.tests.\(UUID().uuidString)"))

        if case .trustRequired(let presented) = await ControlPlaneProbe(trustStore: store).probe(address) {
            try store.pin(presented.fingerprint, for: address)
        }
        return (ControlPlaneSession(address: address, token: token, trustStore: store), store)
    }

    @Test("The pinned session reaches the API and decodes IP spaces")
    func spacesDecode() async throws {
        let (session, store) = try await pinnedSession()
        defer { session.invalidate() }

        let spaces = try await session.client.listSpacesApiV1IpamSpacesGet().ok.body.json
        #expect(!spaces.isEmpty, "The lab should have at least one IP space")
        #expect(spaces.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty })

        try store.removePin(for: #require(LiveServer.address))
    }

    @Test("Blocks and subnets decode, and subnets belong to a block")
    func hierarchyDecodes() async throws {
        let (session, store) = try await pinnedSession()
        defer { session.invalidate() }

        let blocks = try await session.client.listBlocksApiV1IpamBlocksGet().ok.body.json
        let subnets = try await session.client.listSubnetsApiV1IpamSubnetsGet().ok.body.json
        #expect(!blocks.isEmpty)
        #expect(!subnets.isEmpty)

        // Utilisation drives the browse UI, so it must be a real percentage.
        #expect(blocks.allSatisfy { (0...100).contains($0.utilizationPercent) })
        #expect(subnets.allSatisfy { (0...100).contains($0.utilizationPercent) })

        let blockIds = Set(blocks.map(\.id))
        let parented = subnets.compactMap(\.blockId).filter { blockIds.contains($0) }
        #expect(!parented.isEmpty, "Browse needs at least one subnet reachable from a block")

        try store.removePin(for: #require(LiveServer.address))
    }

    @Test("Addresses decode for a subnet that has them")
    func addressesDecode() async throws {
        let (session, store) = try await pinnedSession()
        defer { session.invalidate() }

        let subnets = try await session.client.listSubnetsApiV1IpamSubnetsGet().ok.body.json
        let subnet = try #require(subnets.first { $0.allocatedIps > 0 }, "No populated subnet in the lab")

        let addresses = try await session.client
            .listAddressesApiV1IpamSubnetsSubnetIdAddressesGet(path: .init(subnetId: subnet.id))
            .ok.body.json
        #expect(!addresses.isEmpty)
        #expect(addresses.allSatisfy { !$0.address.isEmpty && !$0.status.isEmpty })

        try store.removePin(for: #require(LiveServer.address))
    }

}
