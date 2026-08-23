//
//  PresentationTests.swift
//  SpatiumDDITests
//

import Foundation
import OpenAPIRuntime
import Testing

@testable import SpatiumDDI

@Suite("Severity")
struct SeverityTests {
    @Test("Known severities map from the server's own vocabulary")
    func mapsKnown() {
        #expect(Severity(apiValue: "critical") == .critical)
        #expect(Severity(apiValue: "warning") == .warning)
        #expect(Severity(apiValue: "info") == .info)
        #expect(Severity(apiValue: "CRITICAL") == .critical)
    }

    // An unrecognised severity must not become the calmest option — a severity
    // this app has never heard of is not automatically minor.
    @Test("An unknown severity is not downgraded to info")
    func unknownIsNotMinimised() {
        #expect(Severity(apiValue: "catastrophic") == .warning)
        #expect(Severity(apiValue: "") == .warning)
    }

    @Test("Most severe sorts first")
    func ordersBySeverity() {
        #expect([Severity.info, .critical, .warning].sorted() == [.critical, .warning, .info])
    }
}

@Suite("Duration formatting")
struct DurationFormattingTests {
    @Test(
        "Whole units render the way a zone file writes them",
        arguments: [
            (86_400, "1d"), (172_800, "2d"), (3_600, "1h"), (7_200, "2h"),
            (300, "5m"), (60, "1m"),
        ]
    )
    func rendersWholeUnits(seconds: Int, expected: String) {
        #expect(Duration.seconds(seconds).formattedCompact == expected)
    }

    // Rounding a 90-second TTL to "2m" would misreport the record, so anything
    // that is not a whole unit stays in seconds.
    @Test("A value that isn't a whole unit stays exact")
    func keepsPartialExact() {
        #expect(Duration.seconds(90).formattedCompact == "90s")
        #expect(Duration.seconds(3_601).formattedCompact == "3601s")
        #expect(Duration.seconds(0).formattedCompact == "0s")
    }
}

@Suite("Platform health")
struct PlatformHealthTests {
    /// The document declares no schema for `/health/platform`, so the app reads
    /// an untyped container. These assert against the shape a real control plane
    /// actually returns.
    /// Decoded the way the generated client decodes it, so what these assert
    /// against is the same container the app is handed at runtime.
    private func container(_ json: String) throws -> OpenAPIValueContainer {
        try JSONDecoder().decode(OpenAPIValueContainer.self, from: Data(json.utf8))
    }

    @Test("A healthy rollup parses into status and components")
    func parsesHealthy() throws {
        let health = try #require(
            PlatformHealth(
                container: container(
                    """
                    {"status":"ok","demo_mode":false,"maintenance_mode":false,
                     "maintenance_message":null,"maintenance_started_at":null,
                     "components":[{"name":"api","status":"ok","detail":"responding"},
                                   {"name":"postgres","status":"ok","detail":"SELECT 1 in 1 ms"}]}
                    """
                )
            )
        )
        #expect(health.status == "ok")
        #expect(health.maintenanceMode == false)
        #expect(health.maintenanceMessage == nil)
        #expect(health.components.count == 2)
        #expect(health.components.first?.name == "api")
        #expect(health.components.first?.detail == "responding")
    }

    @Test("A change window parses as maintenance with its message")
    func parsesMaintenance() throws {
        let health = try #require(
            PlatformHealth(
                container: container(
                    """
                    {"status":"degraded","demo_mode":true,"maintenance_mode":true,
                     "maintenance_message":"Upgrading Postgres","components":[]}
                    """
                )
            )
        )
        #expect(health.maintenanceMode)
        #expect(health.demoMode)
        #expect(health.maintenanceMessage == "Upgrading Postgres")
        #expect(health.status == "degraded")
    }

    // An empty message is the server saying nothing, not saying "".
    @Test("An empty maintenance message is treated as absent")
    func emptyMessageIsNil() throws {
        let health = try #require(
            PlatformHealth(
                container: container(
                    #"{"status":"ok","maintenance_mode":true,"maintenance_message":"","components":[]}"#
                )
            )
        )
        #expect(health.maintenanceMessage == nil)
    }

    @Test("Missing fields fall back rather than failing the parse")
    func toleratesMissingFields() throws {
        let health = try #require(PlatformHealth(container: container(#"{}"#)))
        #expect(health.status == "unknown")
        #expect(health.maintenanceMode == false)
        #expect(health.components.isEmpty)
    }

    @Test("A non-object payload is not a health rollup")
    func rejectsNonObject() throws {
        #expect(PlatformHealth(container: try container("[]")) == nil)
    }
}
