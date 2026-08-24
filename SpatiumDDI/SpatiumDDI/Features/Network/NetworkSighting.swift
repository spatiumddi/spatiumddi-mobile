//
//  NetworkSighting.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// What the SNMP poller has seen of one MAC, across every device it polls.
///
/// This is the join that used to need three browser tabs. A technician standing
/// next to a machine that will not come up has a MAC, and until now the app
/// could tell them what DHCP thought about it and nothing about where it
/// physically is. The switch and the port are in the FDB table; the address the
/// router resolved is in ARP. Both are already on the control plane.
nonisolated struct NetworkSighting: Identifiable, Sendable {
    let deviceID: String
    let deviceName: String
    /// The port that learned this MAC, from FDB. The answer to "where is it
    /// plugged in".
    var port: String?
    var vlan: Int?
    /// The address the device has ARPed for this MAC.
    var ipAddress: String?
    var lastSeen: Date

    var id: String { deviceID }
}

/// Finding a MAC across the polled estate.
///
/// **Bounded on purpose.** There is no estate-wide FDB search in the API — the
/// tables are per device — so this asks each device in turn, and asking three
/// hundred switches from a phone on a train is not a lookup, it is a denial of
/// service against your own control plane. The cap is stated on screen when it
/// bites, because a truncated search that looks complete is worse than one that
/// says where it stopped.
@MainActor
@Observable
final class NetworkSightingModel {
    /// The most devices worth asking for one lookup.
    static let deviceLimit = 40

    private(set) var sightings: [NetworkSighting] = []
    private(set) var isSearching = false
    /// Set when there were more devices than the cap allows.
    private(set) var truncatedFrom: Int?
    private(set) var failure: FailureMessage?
    /// Whether a search has run at all, so "nothing found" and "not asked yet"
    /// stay distinguishable.
    private(set) var hasSearched = false

    private let session: ControlPlaneSession

    init(session: ControlPlaneSession) {
        self.session = session
    }

    func clear() {
        sightings = []
        truncatedFrom = nil
        failure = nil
        hasSearched = false
    }

    /// Looks up one MAC. Anything that is not a MAC is not searched for: ARP
    /// and FDB are keyed on hardware addresses, and sending a hostname would
    /// quietly match nothing while looking like it had tried.
    func search(mac: String) async {
        clear()
        guard MACAddress.looksValid(mac) else { return }

        isSearching = true
        hasSearched = true
        defer { isSearching = false }

        let devices: [Components.Schemas.NetworkDeviceRead]
        do {
            let response = try await session.client.listDevicesApiV1NetworkDevicesGet(
                query: .init(active: true, page: 1, pageSize: 200)
            )
            switch response {
            case .ok(let ok):
                let page = try ok.body.json
                if page.items.count > Self.deviceLimit {
                    truncatedFrom = page.items.count
                }
                devices = Array(page.items.prefix(Self.deviceLimit))
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            // A control plane with the module switched off answers 404 here.
            // Reported rather than swallowed, so an empty section is never
            // mistaken for "this MAC is nowhere".
            failure = APIErrorMessage.describe(error)
            return
        }

        sightings = await Self.gather(mac: mac, across: devices, session: session)
    }

    /// Asks every device for this MAC, tolerating individual failures — one
    /// switch that has gone away must not hide the one that has the answer.
    private static func gather(
        mac: String,
        across devices: [Components.Schemas.NetworkDeviceRead],
        session: ControlPlaneSession
    ) async -> [NetworkSighting] {
        await withTaskGroup(of: NetworkSighting?.self) { tasks in
            for device in devices {
                tasks.addTask {
                    await sighting(mac: mac, on: device, session: session)
                }
            }
            var found: [NetworkSighting] = []
            for await sighting in tasks {
                if let sighting { found.append(sighting) }
            }
            // Most recently seen first: on an estate where a laptop has moved
            // between two switches, the stale entry is the one to ignore.
            return found.sorted { $0.lastSeen > $1.lastSeen }
        }
    }

    private static func sighting(
        mac: String,
        on device: Components.Schemas.NetworkDeviceRead,
        session: ControlPlaneSession
    ) async -> NetworkSighting? {
        // The server filters on `mac` for both tables, so the matching is its
        // job rather than a client-side scan of every row.
        async let fdbRows = fdb(mac: mac, on: device.id, session: session)
        async let arpRows = arp(mac: mac, on: device.id, session: session)
        let (fdb, arp) = await (fdbRows, arpRows)

        guard !fdb.isEmpty || !arp.isEmpty else { return nil }

        var sighting = NetworkSighting(
            deviceID: device.id,
            deviceName: device.name,
            lastSeen: .distantPast
        )
        if let entry = fdb.max(by: { $0.lastSeen < $1.lastSeen }) {
            sighting.port = entry.interfaceName ?? entry.interfaceId
            sighting.vlan = entry.vlanId
            sighting.lastSeen = max(sighting.lastSeen, entry.lastSeen)
        }
        if let entry = arp.max(by: { $0.lastSeen < $1.lastSeen }) {
            sighting.ipAddress = entry.ipAddress
            sighting.lastSeen = max(sighting.lastSeen, entry.lastSeen)
        }
        return sighting
    }

    private static func fdb(
        mac: String, on deviceID: String, session: ControlPlaneSession
    ) async -> [Components.Schemas.NetworkFdbRead] {
        let response = try? await session.client.listFdbApiV1NetworkDevicesDeviceIdFdbGet(
            path: .init(deviceId: deviceID), query: .init(mac: mac, page: 1, pageSize: 50)
        )
        guard case .ok(let ok) = response, let page = try? ok.body.json else { return [] }
        return page.items
    }

    private static func arp(
        mac: String, on deviceID: String, session: ControlPlaneSession
    ) async -> [Components.Schemas.NetworkArpRead] {
        let response = try? await session.client.listArpApiV1NetworkDevicesDeviceIdArpGet(
            path: .init(deviceId: deviceID), query: .init(mac: mac, page: 1, pageSize: 50)
        )
        guard case .ok(let ok) = response, let page = try? ok.body.json else { return [] }
        return page.items
    }
}

/// The "seen on the network" answer, on the Client Lookup screen.
struct NetworkSightingSection: View {
    let model: NetworkSightingModel

    @Environment(FeatureModules.self) private var features

    var body: some View {
        // Hidden entirely on a control plane without the poller, rather than
        // shown as a section that can only ever be empty.
        if features.isAvailable("network.device"), model.hasSearched {
            Section {
                if model.isSearching {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Asking the switches…").foregroundStyle(.secondary)
                    }
                } else if let failure = model.failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if model.sightings.isEmpty {
                    Text(
                        "No polled switch has this MAC in its forwarding table. Either it is not plugged into one, or the switch it is on has not been polled since."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(model.sightings) { sighting in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(verbatim: sighting.deviceName)
                                Spacer()
                                if let vlan = sighting.vlan {
                                    Badge(text: "VLAN \(String(vlan))", tint: .teal)
                                }
                            }
                            if let port = sighting.port {
                                // The port is the whole answer, so it is the
                                // line that looks like one.
                                Text(verbatim: port)
                                    .font(.body.monospaced().weight(.medium))
                            }
                            if let ip = sighting.ipAddress {
                                Text(verbatim: ip)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Text("seen \(sighting.lastSeen.formatted(.relative(presentation: .named)))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                Text("Seen on the network")
            } footer: {
                if let truncatedFrom = model.truncatedFrom {
                    // Never silently truncate. A capped search that reads as
                    // exhaustive is how somebody concludes a device is not on
                    // the network when nobody actually looked.
                    Text(
                        "Only the first \(NetworkSightingModel.deviceLimit) of \(truncatedFrom) polled devices were asked."
                    )
                } else {
                    Text("From the SNMP poller's ARP and forwarding tables — where this MAC actually is.")
                }
            }
        }
    }
}
