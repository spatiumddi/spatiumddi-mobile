//
//  StaleAddressTests.swift
//  SpatiumDDITests
//

import Foundation
import Testing

@testable import SpatiumDDI

/// The one hand-written model in the app, against a real response.
///
/// It is hand-written because `/api/v1/ipam/reports/stale-ips` is typed as a
/// bare `object` in the pinned document — there is no schema to generate from.
/// That removes the compile-time check the rest of the client has, so the
/// fixture below is a verbatim capture from a live control plane and these
/// tests are what stands in for it.
@Suite("Stale address report")
struct StaleAddressTests {
    /// Captured from `GET /api/v1/ipam/reports/stale-ips?stale_days=1
    /// &include_never_seen=true&limit=3` against a 2026.08.22-1 control plane.
    private static let live = """
        {
          "generated_at": "2026-08-24T00:22:55.198Z",
          "stale_days": 1,
          "include_never_seen": true,
          "total": 43,
          "limit": 3,
          "offset": 0,
          "entries": [
            {
              "id": "27af12d7-f49f-4243-8f0f-d964426cace4",
              "address": "10.1.0.2",
              "status": "allocated",
              "hostname": "db-replica-125",
              "mac_address": "8c:7d:72:47:34:2c",
              "last_seen_at": null,
              "last_seen_method": null,
              "days_stale": null,
              "subnet_id": "d59f9832-dec8-48f9-a4e2-1aa47aa3a49d",
              "subnet_network": "10.1.0.0/24",
              "subnet_name": "Office-LAN"
            }
          ]
        }
        """

    private func decode(_ json: String) throws -> StaleAddressReport {
        try JSONDecoder().decode(StaleAddressReport.self, from: Data(json.utf8))
    }

    @Test("A real response decodes")
    func realResponse() throws {
        let report = try decode(Self.live)
        #expect(report.total == 43)
        #expect(report.staleDays == 1)
        #expect(report.entries.count == 1)

        let entry = try #require(report.entries.first)
        #expect(entry.id == "27af12d7-f49f-4243-8f0f-d964426cace4")
        #expect(entry.address == "10.1.0.2")
        #expect(entry.hostname == "db-replica-125")
        #expect(entry.macAddress == "8c:7d:72:47:34:2c")
        #expect(entry.subnetName == "Office-LAN")
        #expect(entry.subnetNetwork == "10.1.0.0/24")
    }

    /// The distinction the screen turns on. A null `days_stale` means nothing
    /// has *ever* seen the address, which the row renders as "never seen" — and
    /// which decoding as zero would render as "0 days stale", the exact
    /// opposite of what it means.
    @Test("A never-seen address decodes to nil days, not zero")
    func neverSeen() throws {
        let entry = try #require(try decode(Self.live).entries.first)
        #expect(entry.daysStale == nil)
    }

    /// The report carries fields this app has no use for. New ones must not
    /// break it, since the server can add them without a version bump.
    @Test("Unknown fields are ignored")
    func toleratesUnknownFields() throws {
        let json = """
            {
              "total": 1,
              "stale_days": 90,
              "something_new": {"nested": true},
              "entries": [
                {"id": "a", "address": "10.0.0.1", "invented_later": 5}
              ]
            }
            """
        let report = try decode(json)
        #expect(report.entries.count == 1)
        #expect(report.entries.first?.address == "10.0.0.1")
    }

    /// Everything except the identity is optional, because a row the server
    /// trimmed is still a row worth listing.
    @Test("A minimal row decodes")
    func minimalRow() throws {
        let json = """
            {"total": 1, "stale_days": 90, "entries": [{"id": "a", "address": "10.0.0.1"}]}
            """
        let entry = try #require(try decode(json).entries.first)
        #expect(entry.status == nil)
        #expect(entry.hostname == nil)
        #expect(entry.subnetName == nil)
    }

    /// A row with no id or no address is not a row. It must fail loudly rather
    /// than decode into something the deprecate action would then send — a
    /// blank address would be confirmed as an empty line in the deprecate
    /// alert while its id was posted anyway.
    @Test(
        "A row missing its identity is a decode failure, not a blank row",
        arguments: [
            #"{"address": "10.0.0.1"}"#,
            #"{"id": "a"}"#,
        ])
    func missingIdentityThrows(_ row: String) {
        #expect(throws: (any Error).self) {
            try decode(#"{"total": 1, "stale_days": 90, "entries": [\#(row)]}"#)
        }
    }

    /// The envelope is untyped too, so a renamed `total` or `stale_days` must
    /// cost the header, not the report. Requiring them turned a screen full of
    /// usable findings into an error banner.
    @Test("A renamed envelope key costs the header, not the rows")
    func toleratesRenamedEnvelopeKeys() throws {
        let json = """
            {"staleDays": 90, "rowCount": 1, "entries": [{"id": "a", "address": "10.0.0.1"}]}
            """
        let report = try decode(json)
        #expect(report.total == nil)
        #expect(report.staleDays == nil)
        #expect(report.entries.count == 1)
    }

    /// The path the app actually takes.
    ///
    /// Every other test here decodes a raw string, which the app never does —
    /// it hands `init(encoded:)` the generated client's untyped payload, and
    /// re-encoding that container is where a number can come back as a
    /// `Double` and fail an `Int`, or a null can be dropped rather than kept.
    /// `UntypedJSON` stands in for the container: same Codable round trip,
    /// same loss of the original bytes.
    @Test("The re-encode round trip preserves what the rows turn on")
    func roundTripThroughAnUntypedPayload() throws {
        let payload = try JSONDecoder().decode(UntypedJSON.self, from: Data(Self.live.utf8))
        let report = try StaleAddressReport(encoded: payload)
        #expect(report.total == 43)
        #expect(report.staleDays == 1)
        #expect(report.entries.count == 1)

        let entry = try #require(report.entries.first)
        #expect(entry.address == "10.1.0.2")
        #expect(entry.macAddress == "8c:7d:72:47:34:2c")
        // The distinction the screen turns on, carried across the one layer
        // that could quietly turn it into zero.
        #expect(entry.daysStale == nil)
    }
}

/// A JSON value with no schema, re-encodable — the shape the generated client
/// hands back for an endpoint the document types as a bare `object`.
private enum UntypedJSON: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([UntypedJSON])
    case object([String: UntypedJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([UntypedJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: UntypedJSON].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}
