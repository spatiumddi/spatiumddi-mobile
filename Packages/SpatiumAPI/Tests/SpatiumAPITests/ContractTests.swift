//
//  ContractTests.swift
//  SpatiumAPITests
//

import Foundation
import OpenAPIRuntime
import Testing

@testable import SpatiumAPI

/// Checks the generated client against a real control plane.
///
/// A client that compiles proves the document parsed, not that the server sends
/// what the document promised. These call a live server and decode the result,
/// which is the only way that gap shows up before it reaches a screen.
///
/// Opt-in, because it needs a reachable server:
///
///     SPATIUM_LAB_URL=http://host:8077 SPATIUM_LAB_TOKEN=… swift test
/// Where the live server is, if one was configured.
///
/// Declared outside the suite: a `@Suite` trait cannot reference a static on the
/// type it annotates without the macro expansion becoming circular.
enum LabEnvironment {
    static var current: (url: URL, token: String)? {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["SPATIUM_LAB_URL"], let url = URL(string: raw),
            let token = env["SPATIUM_LAB_TOKEN"], !token.isEmpty
        else { return nil }
        return (url, token)
    }

    static var isConfigured: Bool { current != nil }
}

/// Skipped wholesale when no server is configured, so an ordinary `swift test`
/// and a CI run without lab access both stay green.
@Suite(.enabled(if: LabEnvironment.isConfigured))
struct ContractTests {
    private func makeClient() throws -> Client {
        let environment = try #require(LabEnvironment.current)
        return SpatiumClientFactory.makeClient(
            serverURL: environment.url,
            session: .shared,
            token: environment.token
        )
    }

    @Test("The version handshake decodes")
    func version() async throws {
        let response = try await makeClient().getVersionApiV1VersionGet()
        let payload = try response.ok.body.json
        #expect(!payload.version.isEmpty)
    }

    @Test("Permissions decode — the call the app already makes to validate a token")
    func permissions() async throws {
        _ = try await makeClient().getMyPermissionsApiV1AuthMePermissionsGet().ok.body.json
    }

    @Test("IPAM spaces decode")
    func spaces() async throws {
        _ = try await makeClient().listSpacesApiV1IpamSpacesGet().ok.body.json
    }

    @Test("IPAM subnets decode, including their nullable fields")
    func subnets() async throws {
        _ = try await makeClient().listSubnetsApiV1IpamSubnetsGet().ok.body.json
    }

    @Test("DNS groups decode")
    func dnsGroups() async throws {
        _ = try await makeClient().listGroupsApiV1DnsGroupsGet().ok.body.json
    }

    @Test("Alert events decode")
    func alerts() async throws {
        _ = try await makeClient().listEventsApiV1AlertsEventsGet().ok.body.json
    }

    @Test("The network dashboard summary decodes")
    func networkSummary() async throws {
        _ = try await makeClient().networkSummaryApiV1DashboardsNetworkSummaryGet().ok.body.json
    }
}
