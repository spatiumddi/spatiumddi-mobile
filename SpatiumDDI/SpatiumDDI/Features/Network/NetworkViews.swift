//
//  NetworkViews.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// VRFs — name, route distinguisher, and the import/export targets that decide
/// what actually reaches them.
struct VRFsView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<[Components.Schemas.VRFResponse]> = .idle

    var body: some View {
        List {
            LoadStateView(state: state, emptyMessage: "No VRFs are defined.", retry: load) { vrfs in
                ForEach(vrfs, id: \.id) { vrf in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(vrf.name)
                            Spacer()
                            if let rd = vrf.routeDistinguisher, !rd.isEmpty {
                                Text(rd).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        if !vrf.description.isEmpty {
                            Text(vrf.description).font(.caption).foregroundStyle(.secondary)
                        }
                        if !vrf.importTargets.isEmpty || !vrf.exportTargets.isEmpty {
                            Text(
                                "import \(vrf.importTargets.joined(separator: " ")) · export \(vrf.exportTargets.joined(separator: " "))"
                            )
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                        }
                        HStack(spacing: 8) {
                            if let spaces = vrf.spaceCount { Text("\(spaces) spaces") }
                            if let blocks = vrf.blockCount { Text("\(blocks) blocks") }
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        // The server flags RD/RT values whose ASN portion
                        // disagrees with the VRF's own ASN. Worth surfacing —
                        // it is the kind of thing that works until it doesn't.
                        if let warnings = vrf.warnings, !warnings.isEmpty {
                            ForEach(warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("VRFs")
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            switch try await session.client.listVrfsApiV1VrfsGet(query: .init(limit: 200)) {
            case .ok(let ok):
                return try ok.body.json.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// Routers, then the VLANs each one carries.
struct VLANRoutersView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<[Components.Schemas.AppApiV1VlansRouterRouterResponse]> = .idle

    var body: some View {
        List {
            LoadStateView(state: state, emptyMessage: "No routers are registered.", retry: load) { routers in
                ForEach(routers, id: \.id) { router in
                    NavigationLink {
                        VLANsView(session: session, router: router)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(router.name)
                            if let ip = router.managementIp, !ip.isEmpty {
                                Text(ip).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                if let vendor = router.vendor, !vendor.isEmpty { Text(vendor) }
                                if let model = router.model, !model.isEmpty { Text(model) }
                                if !router.location.isEmpty { Text(router.location) }
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .navigationTitle("VLANs")
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            switch try await session.client.listRoutersApiV1VlansRoutersGet() {
            case .ok(let ok):
                return try ok.body.json.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// VLANs on one router.
struct VLANsView: View {
    let session: ControlPlaneSession
    let router: Components.Schemas.AppApiV1VlansRouterRouterResponse

    @State private var state: LoadState<[Components.Schemas.VLANResponse]> = .idle

    var body: some View {
        List {
            LoadStateView(state: state, emptyMessage: "This router has no VLANs.", retry: load) { vlans in
                ForEach(vlans, id: \.id) { vlan in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("VLAN \(vlan.vlanId)").font(.body.monospaced())
                            Spacer()
                            if !vlan.name.isEmpty {
                                Text(vlan.name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !vlan.description.isEmpty {
                            Text(vlan.description).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .navigationTitle(router.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            let response = try await session.client
                .listVlansApiV1VlansRoutersRouterIdVlansGet(path: .init(routerId: router.id))
            switch response {
            case .ok(let ok):
                return try ok.body.json.sorted { $0.vlanId < $1.vlanId }
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// WAN circuits, with the term dates that decide when a contract lapses.
struct CircuitsView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<[Components.Schemas.CircuitRead]> = .idle

    var body: some View {
        List {
            LoadStateView(state: state, emptyMessage: "No circuits are recorded.", retry: load) { circuits in
                ForEach(circuits, id: \.id) { circuit in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(circuit.name).lineLimit(1)
                            Spacer(minLength: 4)
                            StatusLabel(status: circuit.status)
                        }
                        if let ckt = circuit.cktId, !ckt.isEmpty {
                            Text(ckt).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            Badge(text: circuit.transportClass, tint: .teal)
                            Text(bandwidth(circuit)).font(.caption2).foregroundStyle(.secondary)
                        }
                        if let end = circuit.termEndDate, !end.isEmpty {
                            Text("term ends \(end)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Circuits")
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    /// Symmetric circuits are the common case; showing "100 / 100" for one is
    /// noise, so they collapse to a single figure.
    private func bandwidth(_ circuit: Components.Schemas.CircuitRead) -> String {
        circuit.bandwidthMbpsDown == circuit.bandwidthMbpsUp
            ? "\(circuit.bandwidthMbpsDown) Mbps"
            : "\(circuit.bandwidthMbpsDown) down / \(circuit.bandwidthMbpsUp) up Mbps"
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            switch try await session.client.listCircuitsApiV1CircuitsGet(query: .init(limit: 200)) {
            case .ok(let ok):
                return try ok.body.json.items.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// Tracked ASNs, with the RDAP holder and its drift state.
struct ASNsView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<[Components.Schemas.ASNRead]> = .idle

    var body: some View {
        List {
            LoadStateView(state: state, emptyMessage: "No ASNs are tracked.", retry: load) { asns in
                ForEach(asns, id: \.id) { asn in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("AS\(asn.number)").font(.body.monospaced())
                            Spacer()
                            Badge(text: asn.kind, tint: .indigo)
                        }
                        if !asn.name.isEmpty {
                            Text(asn.name).font(.caption).foregroundStyle(.secondary)
                        }
                        if let holder = asn.holderOrg, !holder.isEmpty, holder != asn.name {
                            Text(holder).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        HStack(spacing: 6) {
                            Text(asn.registry.uppercased()).font(.caption2).foregroundStyle(.tertiary)
                            // Drift means the RDAP holder no longer matches what
                            // was recorded — an ASN changing hands under you.
                            if asn.whoisState.lowercased() == "drift" {
                                Badge(text: "holder drift", tint: .red)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("ASNs")
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            switch try await session.client.listAsnsApiV1AsnsGet(query: .init(limit: 200)) {
            case .ok(let ok):
                return try ok.body.json.items.sorted { $0.number < $1.number }
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}
