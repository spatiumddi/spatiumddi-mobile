//
//  LookingGlassView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// "How does this get routed?" — asked about one address, not browsed.
///
/// The web console has the whole BGP route table. That is not what belongs on a
/// phone: an operator away from a desk has one prefix in mind, usually because
/// something is unreachable, and wants the route for it. So this is a lookup
/// with a peer-health summary attached, and `/looking-glass/routes` — the full
/// table — is deliberately not in the generated client at all.
struct LookingGlassView: View {
    let session: ControlPlaneSession

    /// What the operator is asking about.
    enum Mode: String, CaseIterable, Identifiable {
        case address = "This IP"
        case prefix = "This prefix"
        var id: Self { self }
    }

    @State private var mode: Mode = .address
    @State private var query = ""
    @State private var summary: LoadState<Components.Schemas.LookingGlassDashboardSummary> = .idle
    @State private var forIP: ToolRun<Components.Schemas.RouteForIpResponse> = .init()
    @State private var forPrefix: ToolRun<[Components.Schemas.RouteRead]> = .init()
    @State private var peers: LoadState<[Components.Schemas.PeerRead]> = .idle

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            Section {
                switch summary {
                case .idle, .loading:
                    ProgressView().frame(maxWidth: .infinity)
                case .loaded(let summary):
                    HStack(spacing: 10) {
                        PeerTile(
                            value: summary.peersEstablished, label: "Established", tint: .green)
                        PeerTile(
                            value: summary.peersDown,
                            label: "Down",
                            tint: summary.peersDown > 0 ? .red : .secondary
                        )
                        PeerTile(
                            value: summary.routesRpkiInvalid,
                            label: "RPKI invalid",
                            tint: summary.routesRpkiInvalid > 0 ? .orange : .secondary
                        )
                    }
                    .listRowInsets(.init(top: 8, leading: 12, bottom: 8, trailing: 12))

                    if summary.routesFlapping > 0 {
                        // Flapping is the symptom that explains intermittent
                        // reachability, which is the complaint that gets
                        // somebody paged at an awkward hour.
                        Label(
                            "^[\(summary.routesFlapping) route](inflect: true) flapping.",
                            systemImage: "waveform.path.ecg"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Peers")
            } footer: {
                Text("What the collectors are hearing right now.")
            }

            Section {
                Picker("Look up", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(.init(top: 6, leading: 12, bottom: 6, trailing: 12))

                TextField(mode == .address ? "10.1.0.50" : "10.1.0.0/24", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.numbersAndPunctuation)
                    .font(.body.monospaced())
                    .submitLabel(.search)
                    .onSubmit { start() }

                ToolRunButton(
                    title: "Look Up",
                    isRunning: forIP.isRunning || forPrefix.isRunning,
                    isEnabled: !trimmed.isEmpty,
                    action: start
                )
            } header: {
                Text("Route")
            } footer: {
                // Says which question each mode asks. They are not the same:
                // one is "what carries this address", the other is "is this
                // exact prefix being announced", and mixing them up wastes a
                // troubleshooting step.
                if mode == .address {
                    Text("The most specific route that would carry this address.")
                } else {
                    Text("Every announcement of this exact prefix, from every peer.")
                }
            }

            switch mode {
            case .address:
                ToolResultSection(run: forIP, idleMessage: "Enter an address to see what routes it.") {
                    result in
                    if result.found, let route = result.route {
                        RouteDetail(route: route)
                        if let alternates = result.alternatePathsCount, alternates > 0 {
                            Text("^[\(alternates) alternate path](inflect: true) exists.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        // Not an error. No route for an address is a finding,
                        // and often the finding — it is why the thing is
                        // unreachable.
                        Label(
                            "No collector has a route covering \(result.ip).",
                            systemImage: "questionmark.circle"
                        )
                        .foregroundStyle(.orange)
                    }
                }

            case .prefix:
                ToolResultSection(run: forPrefix, idleMessage: "Enter a prefix to see who announces it.") {
                    routes in
                    if routes.isEmpty {
                        Label("Nothing announces that prefix.", systemImage: "questionmark.circle")
                            .foregroundStyle(.orange)
                    } else {
                        ForEach(routes, id: \.id) { RouteDetail(route: $0) }
                    }
                }
            }

            Section("Configured peers") {
                LoadStateView(
                    state: peers,
                    emptyMessage: "No BGP peers are configured.",
                    retry: { Task { await fetchPeers() } }
                ) { rows in
                    ForEach(rows, id: \.id) { PeerRow(peer: $0) }
                }
            }
        }
        .navigationTitle("Looking Glass")
        .dismissableKeyboard()
        .refreshable { await refresh() }
        .task { if case .idle = summary { await refresh() } }
    }

    private func start() {
        let target = trimmed
        guard !target.isEmpty else { return }
        dismissKeyboard()
        switch mode {
        case .address:
            Task {
                await forIP.run {
                    let response = try await session.client
                        .getRouteForIpApiV1LookingGlassRoutesForIpGet(query: .init(ip: target))
                    switch response {
                    case .ok(let ok): return try ok.body.json
                    case .unprocessableContent: throw APIStatusError(status: 422)
                    case .undocumented(let statusCode, let payload):
                        throw await APIStatusError(status: statusCode, payload: payload)
                    }
                }
            }
        case .prefix:
            Task {
                await forPrefix.run {
                    let response = try await session.client
                        .getRouteApiV1LookingGlassRoutesByPrefixGet(query: .init(prefix: target))
                    switch response {
                    case .ok(let ok): return try ok.body.json
                    case .unprocessableContent: throw APIStatusError(status: 422)
                    case .undocumented(let statusCode, let payload):
                        throw await APIStatusError(status: statusCode, payload: payload)
                    }
                }
            }
        }
    }

    private func refresh() async {
        async let a: Void = fetchSummary()
        async let b: Void = fetchPeers()
        _ = await (a, b)
    }

    private func fetchSummary() async {
        summary = .loading
        summary = await LoadState.fetching {
            switch try await session.client.dashboardSummaryApiV1LookingGlassDashboardSummaryGet() {
            case .ok(let ok): return try ok.body.json
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }

    private func fetchPeers() async {
        peers = .loading
        peers = await LoadState.fetching {
            switch try await session.client.listPeersApiV1LookingGlassPeersGet() {
            case .ok(let ok):
                return try ok.body.json.sorted {
                    // Anything not established first: on a screen about
                    // reachability, the broken session is the one to see.
                    ($0.sessionState.lowercased() == "established" ? 1 : 0, $0.name)
                        < ($1.sessionState.lowercased() == "established" ? 1 : 0, $1.name)
                }
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

private struct PeerTile: View {
    let value: Int
    let label: LocalizedStringResource
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value.formatted())
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct RouteDetail: View {
    let route: Components.Schemas.RouteRead

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(route.prefix).font(.body.monospaced())
                Spacer()
                if route.isBest { Badge(localised: "best", tint: .green) }
                RPKIBadge(status: route.rpkiStatus)
            }
            LabeledContent("Next hop") {
                Text(verbatim: route.nextHop).font(.caption.monospaced())
            }
            if !route.asPath.isEmpty {
                LabeledContent("AS path") {
                    Text(verbatim: route.asPath.map(String.init).joined(separator: " "))
                        .font(.caption.monospaced())
                        .lineLimit(2)
                }
            }
            if let origin = route.originAsn {
                LabeledContent("Origin", value: "AS\(String(origin))")
            }
            if !route.communities.isEmpty {
                LabeledContent("Communities") {
                    Text(verbatim: route.communities.joined(separator: " "))
                        .font(.caption.monospaced())
                        .lineLimit(2)
                }
            }
            HStack(spacing: 8) {
                Text("seen \(route.lastSeenAt.formatted(.relative(presentation: .named)))")
                if route.flapCount > 0 {
                    Text("^[\(route.flapCount) flap](inflect: true)")
                }
                if let withdrawn = route.withdrawnAt {
                    Text("withdrawn \(withdrawn.formatted(.relative(presentation: .named)))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

/// RPKI validity, which is a three-state answer rather than a boolean.
///
/// `not-found` is not a failure — most of the routing table has no ROA — so it
/// is not coloured as one. Only `invalid` means somebody is announcing a prefix
/// the holder said they would not.
private struct RPKIBadge: View {
    let status: String

    var body: some View {
        Badge(text: status, tint: tint)
    }

    private var tint: Color {
        switch status.lowercased() {
        case "valid": .green
        case "invalid": .red
        default: .secondary
        }
    }
}

private struct PeerRow: View {
    let peer: Components.Schemas.PeerRead

    private var isEstablished: Bool { peer.sessionState.lowercased() == "established" }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(peer.name)
                Spacer()
                if !peer.enabled { Badge(localised: "disabled", tint: .secondary) }
                Badge(text: peer.sessionState, tint: isEstablished ? .green : .red)
            }
            Text("\(peer.peerAddress) · AS\(String(peer.peerAsn))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("^[\(peer.prefixesAccepted) prefix](inflect: true) accepted")
                if peer.rpkiInvalidCount > 0 {
                    Text("^[\(peer.rpkiInvalidCount) RPKI invalid](inflect: true)")
                }
                if let down = peer.downSince {
                    Text("down since \(down.formatted(.relative(presentation: .named)))")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}
