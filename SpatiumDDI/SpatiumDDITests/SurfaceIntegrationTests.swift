//
//  SurfaceIntegrationTests.swift
//  SpatiumDDITests
//

import Foundation
import SpatiumAPI
import Testing

@testable import SpatiumDDI

/// The Phase 1 surfaces beyond IPAM, against a live control plane.
///
/// These exist because a compile only proves the generated types exist — it
/// proves nothing about whether the server fills the fields the screens read.
/// The two bugs this style of test has already caught here were both of that
/// kind: dropped nullable fields, and timestamps the decoder rejected.
@Suite(.enabled(if: LiveServer.isConfigured))
@MainActor
struct SurfaceIntegrationTests {

    // MARK: - Platform

    @Test("The health rollup parses into the shape the overview renders")
    func healthParses() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let container = try await session.client.platformHealthHealthPlatformGet().ok.body.json
        let health = try #require(
            PlatformHealth(container: container),
            "The overview cannot render a rollup it can't parse"
        )
        #expect(!health.status.isEmpty)
        #expect(!health.components.isEmpty, "A real control plane reports its components")
        #expect(health.components.allSatisfy { !$0.name.isEmpty && !$0.status.isEmpty })

        try store.removePin(for: #require(LiveServer.address))
    }

    @Test("The version handshake returns something the gate can classify")
    func versionParses() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let version = try await session.client.getVersionApiV1VersionGet().ok.body.json
        #expect(!version.version.isEmpty)

        // Either it is CalVer or it is a development build; both are handled,
        // and neither may crash the gate.
        let parsed = ServerVersion(version.version)
        #expect(parsed.displayName == version.version || !parsed.isDevelopment)

        try store.removePin(for: #require(LiveServer.address))
    }

    @Test("Identity and permissions decode")
    func identityDecodes() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let me = try await session.client.getMeApiV1AuthMeGet().ok.body.json
        #expect(!me.username.isEmpty)

        let permissions = try await session.client
            .getMyPermissionsApiV1AuthMePermissionsGet().ok.body.json
        #expect(permissions.isSuperadmin || !permissions.grants.isEmpty)

        try store.removePin(for: #require(LiveServer.address))
    }

    // MARK: - DNS

    @Test("DNS groups, zones and records decode down the whole chain")
    func dnsChainDecodes() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let groups = try await session.client.listGroupsApiV1DnsGroupsGet().ok.body.json
        #expect(!groups.isEmpty, "The lab should have at least one DNS group")
        #expect(groups.allSatisfy { !$0.id.isEmpty && !$0.name.isEmpty })

        // Walk every group until one has zones: which group holds them is a
        // property of the lab's data, not of the client.
        var zonesFound: [Components.Schemas.ZoneResponse] = []
        var owningGroup: String?
        for group in groups {
            let zones = try await session.client
                .listZonesApiV1DnsGroupsGroupIdZonesGet(path: .init(groupId: group.id))
                .ok.body.json
            if !zones.isEmpty {
                zonesFound = zones
                owningGroup = group.id
                break
            }
        }

        let groupId = try #require(owningGroup, "No DNS group in the lab has zones")
        #expect(zonesFound.allSatisfy { !$0.name.isEmpty && !$0.zoneType.isEmpty })

        // A zone with no records still renders; one with records must decode.
        for zone in zonesFound {
            let page = try await session.client
                .listRecordsApiV1DnsGroupsGroupIdZonesZoneIdRecordsGet(
                    path: .init(groupId: groupId, zoneId: zone.id),
                    query: .init(page: 1, pageSize: 50)
                )
                .ok.body.json
            #expect(page.total >= page.items.count)
            #expect(page.items.allSatisfy { !$0.recordType.isEmpty })
            if !page.items.isEmpty { break }
        }

        try store.removePin(for: #require(LiveServer.address))
    }

    // MARK: - DHCP

    @Test("DHCP servers, stats, groups and scopes decode")
    func dhcpChainDecodes() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let servers = try await session.client.listServersApiV1DhcpServersGet().ok.body.json
        #expect(!servers.isEmpty, "The lab should have at least one DHCP server")
        #expect(servers.allSatisfy { !$0.name.isEmpty && !$0.status.isEmpty && !$0.driver.isEmpty })

        // Stats drive the traffic chart. `rateBuckets` carries timestamps, which
        // is exactly where a date-decoding mismatch would surface.
        let server = try #require(servers.first)
        let stats = try await session.client
            .getServerStatsApiV1DhcpServersServerIdStatsGet(path: .init(serverId: server.id))
            .ok.body.json
        #expect(stats.leasesActive >= 0)
        #expect(stats.bucketSeconds > 0)

        // Leases are paginated; an empty lab still has to return a valid page.
        let leases = try await session.client
            .listLeasesApiV1DhcpServersServerIdLeasesGet(
                path: .init(serverId: server.id),
                query: .init(page: 1, pageSize: 25)
            )
            .ok.body.json
        #expect(leases.total >= leases.items.count)
        #expect(leases.items.allSatisfy { !$0.ipAddress.isEmpty && !$0.macAddress.isEmpty })

        let groups = try await session.client.listGroupsApiV1DhcpServerGroupsGet().ok.body.json
        #expect(!groups.isEmpty)

        for group in groups {
            let scopes = try await session.client
                .listScopesForGroupApiV1DhcpServerGroupsGroupIdScopesGet(path: .init(groupId: group.id))
                .ok.body.json
            guard let scope = scopes.first else { continue }

            // The scope screen resolves the subnet behind the scope, and reads
            // pools and reservations. All three have to decode.
            #expect(!scope.subnetId.isEmpty)
            let pools = try await session.client
                .listPoolsApiV1DhcpScopesScopeIdPoolsGet(path: .init(scopeId: scope.id))
                .ok.body.json
            #expect(pools.allSatisfy { !$0.startIp.isEmpty && !$0.endIp.isEmpty })

            let statics = try await session.client
                .listStaticsApiV1DhcpScopesScopeIdStaticsGet(path: .init(scopeId: scope.id))
                .ok.body.json
            #expect(statics.allSatisfy { !$0.ipAddress.isEmpty && !$0.macAddress.isEmpty })
            break
        }

        try store.removePin(for: #require(LiveServer.address))
    }

    // MARK: - Alerts and search

    @Test("Alert events decode and classify into known severities")
    func alertsDecode() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let events = try await session.client
            .listEventsApiV1AlertsEventsGet(query: .init(openOnly: false, limit: 50))
            .ok.body.json
        #expect(events.allSatisfy { !$0.message.isEmpty && !$0.severity.isEmpty })

        // `firedAt` is a date, and the lab has already produced microsecond
        // timestamps that a stricter decoder rejected.
        #expect(events.allSatisfy { $0.firedAt.timeIntervalSince1970 > 0 })

        // Unresolved-only must actually filter, or the overview's count is wrong.
        let open = try await session.client
            .listEventsApiV1AlertsEventsGet(query: .init(openOnly: true, limit: 50))
            .ok.body.json
        #expect(open.allSatisfy { $0.resolvedAt == nil })
        #expect(open.count <= events.count)

        try store.removePin(for: #require(LiveServer.address))
    }

    @Test("Global search returns typed, labelled results")
    func searchDecodes() async throws {
        let (session, store) = try await LiveServer.pinnedSession()
        defer { session.invalidate() }

        let types = try await session.client.searchableTypesApiV1SearchTypesGet().ok.body.json
        #expect(!types.isEmpty)
        #expect(types.allSatisfy { !$0._type.isEmpty && !$0.label.isEmpty && !$0.group.isEmpty })

        // "e" matches broadly enough to return something on any populated lab
        // without depending on a particular object existing.
        let response = try await session.client
            .globalSearchApiV1SearchGet(query: .init(q: "e", limit: 25))
            .ok.body.json
        #expect(response.total >= response.results.count)
        #expect(response.results.allSatisfy { !$0._type.isEmpty && !$0.display.isEmpty })

        // Every result type must be one the type list named, or the search
        // screen has no label to group it under.
        let known = Set(types.map(\._type))
        #expect(response.results.allSatisfy { known.contains($0._type) })

        try store.removePin(for: #require(LiveServer.address))
    }
}
