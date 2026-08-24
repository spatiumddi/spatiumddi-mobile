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
    enum Mode: CaseIterable, Identifiable {
        case address
        case prefix
        var id: Self { self }

        /// Separate from the case so the two words an operator actually reads
        /// reach the string catalogue. As a raw value they never would.
        var label: LocalizedStringResource {
            switch self {
            case .address: "This IP"
            case .prefix: "This prefix"
            }
        }
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
                // `LoadStateView` rather than a hand-rolled switch: it carries
                // the retry button and the `.idle` branch that recovers a
                // cancelled refresh. The peers section below already uses it.
                LoadStateView(
                    state: summary,
                    emptyMessage: "No collectors are reporting.",
                    retry: { Task { await fetchSummary() } }
                ) { summary in
                    HStack(spacing: 10) {
                        CountTile(
                            value: summary.peersEstablished, label: "Established", tint: .green)
                        CountTile(
                            value: summary.peersDown,
                            label: "Down",
                            tint: summary.peersDown > 0 ? .red : .secondary
                        )
                        // Counts routes, not peers, so it says so — three
                        // identically-shaped tiles under a "Peers" header
                        // otherwise read as three counts of the same thing.
                        CountTile(
                            value: summary.routesRpkiInvalid,
                            label: "Routes RPKI invalid",
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
                }
            } header: {
                Text("Peers")
            } footer: {
                Text("What the collectors are hearing right now.")
            }

            Section {
                Picker("Look up", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.label).tag($0) }
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
                    // The mode on screen, not either mode: a slow lookup left
                    // running in the other one would otherwise spin and
                    // disable a button above a result section that is idle.
                    isRunning: isRunning,
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
                        // Says which address this answers. The field is free
                        // to change under a result that stays on screen, and a
                        // covering prefix looks plausible for the wrong IP.
                        LabeledContent("For") {
                            Text(verbatim: result.ip).font(.caption.monospaced())
                        }
                        RouteDetail(route: route)
                        if let alternates = result.alternatePathsCount, alternates > 0 {
                            Text("^[\(alternates) alternate path](inflect: true) available.")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        // Not an error. No route for an address is a finding,
                        // and often the finding — it is why the thing is
                        // unreachable.
                        // `Text(verbatim:)` for the address: a literal with
                        // an interpolation binds to `LocalizedStringKey`,
                        // which Markdown-parses its arguments. Interpolating a
                        // `Text` leaves the server's value unparsed.
                        Label {
                            Text("No collector has a route covering \(Text(verbatim: result.ip)).")
                        } icon: {
                            Image(systemName: "questionmark.circle")
                        }
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

    /// Whether the mode on screen has a lookup in flight.
    private var isRunning: Bool { mode == .address ? forIP.isRunning : forPrefix.isRunning }

    private func start() {
        let target = trimmed
        // `.onSubmit` reaches here too, so the guard lives here rather than
        // only on the button — otherwise the keyboard fires the lookup the
        // button is refusing.
        guard !target.isEmpty, !isRunning else { return }
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
                    // reachability, the broken session is the one to see. A
                    // peer somebody switched off is not broken, so it sorts
                    // with the healthy ones rather than heading the list.
                    (isPeerDown($0) ? 0 : 1, $0.name) < (isPeerDown($1) ? 0 : 1, $1.name)
                }
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// A session that should be up and is not.
///
/// `session_state` alone is not the answer: a disabled peer is never brought
/// up, so it reports `idle` — which is expected, not a fault.
private nonisolated func isPeerDown(_ peer: Components.Schemas.PeerRead) -> Bool {
    peer.enabled && peer.sessionState.lowercased() != "established"
}

private struct RouteDetail: View {
    let route: Components.Schemas.RouteRead

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(verbatim: route.prefix).font(.body.monospaced())
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
    /// Red is for a session that should be up and is not. A disabled peer
    /// reports `idle` by design, and painting that red reads as a fault.
    private var isDown: Bool { isPeerDown(peer) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: peer.name)
                Spacer()
                if !peer.enabled { Badge(localised: "disabled", tint: .secondary) }
                Badge(
                    text: peer.sessionState,
                    tint: isEstablished ? .green : (isDown ? .red : .secondary))
            }
            // `Text(verbatim:)`, not a literal with an interpolation: that
            // binds to `LocalizedStringKey`, which Markdown-parses its
            // arguments — so a peer address could carry a tappable link.
            Text(verbatim: "\(peer.peerAddress) · AS\(peer.peerAsn)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("^[\(peer.prefixesAccepted) prefix](inflect: true) accepted")
                if peer.rpkiInvalidCount > 0 {
                    // "route" is the head noun, so it is what pluralises —
                    // inflecting "invalid" gives "3 RPKI invalids".
                    Text("^[\(peer.rpkiInvalidCount) RPKI-invalid route](inflect: true)")
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
