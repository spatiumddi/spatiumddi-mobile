//
//  ClientLookupView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// "Why isn't this machine getting an address?"
///
/// The screen for a technician stood next to the machine in question. One field,
/// a MAC or an IP or a hostname, and the answer to the three questions that
/// follow: did it ever get a lease, what did it get, and has that lapsed.
///
/// Every other DHCP screen here starts from the server and works down. This one
/// starts from the client, because that is the thing the person in front of you
/// is holding.
struct ClientLookupView: View {
    let session: ControlPlaneSession

    /// A lease-history row with the server it came from, since the lookup fans
    /// out across every DHCP server and the row itself only carries an id.
    struct Result: Identifiable {
        let row: Components.Schemas.LeaseHistoryRow
        let serverName: String
        var id: String { row.id }
    }

    @State private var query = ""
    @State private var state: LoadState<[Result]> = .idle
    @State private var activeLeases: [Components.Schemas.LeaseResponse] = []
    @State private var searched = ""

    var body: some View {
        List {
            Section {
                TextField("Filter by IP, hostname or MAC", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { Task { await search() } }
                Button {
                    Task { await search() }
                } label: {
                    HStack {
                        Label("Look Up", systemImage: "magnifyingglass")
                        Spacer()
                        if case .loading = state { ProgressView() }
                    }
                }
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Client")
            } footer: {
                // Says what the match actually is, so nobody reads a blank
                // result as "this machine has never been on the network".
                Text(
                    "Searches every DHCP server's lease history. A MAC can be entered with or without colons."
                )
            }

            if !activeLeases.isEmpty {
                Section("Holding an address now") {
                    ForEach(activeLeases, id: \.id) { lease in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(lease.ipAddress).font(.body.monospaced())
                                Spacer()
                                Badge(text: lease.state, tint: .green)
                            }
                            Text(lease.macAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
                            if let hostname = lease.hostname, !hostname.isEmpty {
                                Text(hostname).font(.caption).foregroundStyle(.secondary)
                            }
                            if let expires = lease.expiresAt {
                                Text("expires \(expires.formatted(.relative(presentation: .named)))")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }

            if let canonical = ClientIdentifier.canonicalMAC(searched) {
                Section {
                    NavigationLink {
                        DHCPActivityView(session: session, initialMAC: canonical)
                    } label: {
                        Label("See this MAC in the server log", systemImage: "doc.text.magnifyingglass")
                    }
                } footer: {
                    // Deliberately not promised as "the DORA exchange". The
                    // agent pins Kea's logger to INFO, and DHCP4_PACKET_RECEIVED
                    // / _SEND are DEBUG — so what is actually recorded is the
                    // outcome (allocation, decline, NAK), not every packet.
                    Text(
                        "What the server recorded for this MAC — allocations, declines and NAKs. Kea servers only, and the log keeps 24 hours."
                    )
                }
            }

            if !searched.isEmpty {
                Section {
                    LoadStateView(
                        state: state,
                        emptyMessage:
                            "No lease has ever been recorded for \"\(searched)\" on any DHCP server. Either it has never asked, or it is asking a server this platform doesn't manage.",
                        retry: { Task { await search() } }
                    ) { results in
                        ForEach(results) { result in
                            LeaseHistoryRow(result: result)
                        }
                    }
                } header: {
                    Text("Lease history")
                } footer: {
                    if case .loaded(let results) = state, !results.isEmpty {
                        Text("Most recent first. ^[\(results.count) record](inflect: true).")
                    }
                }
            }
        }
        .navigationTitle("Client Lookup")
        .dismissableKeyboard()
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searched = trimmed
        state = .loading
        activeLeases = []

        state = await LoadState.fetching {
            // Which server holds the answer is not knowable in advance, so the
            // lookup asks all of them at once. A field technician is not going
            // to know which scope a machine belongs to — that is the question.
            let servers: [Components.Schemas.AppApiV1DhcpServersServerResponse]
            switch try await session.client.listServersApiV1DhcpServersGet() {
            case .ok(let ok): servers = try ok.body.json
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }

            let looksLikeMAC = ClientIdentifier.isMACLike(trimmed)
            let looksLikeIP = ClientIdentifier.isIPv4Like(trimmed)

            async let history = historyAcross(servers, term: trimmed, isMAC: looksLikeMAC, isIP: looksLikeIP)
            async let active = activeAcross(servers, term: trimmed)
            let (rows, leases) = await (history, active)
            activeLeases = leases
            // Most recent first. A row with no start date sorts last rather
            // than to the top — an unknown time is not a recent one.
            return rows.sorted {
                ($0.row.startedAt ?? .distantPast) > ($1.row.startedAt ?? .distantPast)
            }
        }
    }

    /// Fans the history query across every server, tolerating individual
    /// failures — one unreachable server must not hide another's answer.
    private func historyAcross(
        _ servers: [Components.Schemas.AppApiV1DhcpServersServerResponse],
        term: String,
        isMAC: Bool,
        isIP: Bool
    ) async -> [Result] {
        await withTaskGroup(of: [Result].self) { tasks in
            for server in servers {
                tasks.addTask { [session] in
                    // The server filters on exactly one of these, so the guess
                    // matters: sending a hostname as `mac` matches nothing.
                    let query = Operations.ListLeaseHistoryApiV1DhcpServersServerIdLeaseHistoryGet.Input
                        .Query(
                            mac: isMAC ? term : nil,
                            ip: isIP ? term : nil,
                            hostname: (isMAC || isIP) ? nil : term,
                            perPage: 100
                        )
                    let response = try? await session.client
                        .listLeaseHistoryApiV1DhcpServersServerIdLeaseHistoryGet(
                            path: .init(serverId: server.id), query: query
                        )
                    guard case .ok(let ok) = response, let page = try? ok.body.json else { return [] }
                    return page.items.map { Result(row: $0, serverName: server.name) }
                }
            }
            var collected: [Result] = []
            for await rows in tasks { collected += rows }
            return collected
        }
    }

    /// A history row says what happened; an active lease says what is true now.
    private func activeAcross(
        _ servers: [Components.Schemas.AppApiV1DhcpServersServerResponse],
        term: String
    ) async -> [Components.Schemas.LeaseResponse] {
        await withTaskGroup(of: [Components.Schemas.LeaseResponse].self) { tasks in
            for server in servers {
                tasks.addTask { [session] in
                    let response = try? await session.client
                        .listLeasesApiV1DhcpServersServerIdLeasesGet(
                            path: .init(serverId: server.id),
                            query: .init(search: term, page: 1, pageSize: 50)
                        )
                    guard case .ok(let ok) = response, let page = try? ok.body.json else { return [] }
                    return page.items
                }
            }
            var collected: [Components.Schemas.LeaseResponse] = []
            for await leases in tasks { collected += leases }
            return collected
        }
    }

}

/// How to read what the operator typed into the lookup field.
///
/// A free function rather than a member of the view: this is string parsing,
/// not view logic, and as a member it inherited the view's `@MainActor`
/// isolation — which made it untestable from a synchronous test and trapped at
/// runtime when one tried.
nonisolated enum ClientIdentifier {
    /// Twelve hex digits, however the operator chose to punctuate them.
    ///
    /// A technician reads a MAC off a label or a screen and types it the way it
    /// was written — colons, hyphens, dots, or nothing at all.
    static func isMACLike(_ text: String) -> Bool {
        let digits = text.filter(\.isHexDigit)
        let separators = text.filter { $0 == ":" || $0 == "-" || $0 == "." }
        return digits.count == 12 && digits.count + separators.count == text.count
    }

    /// A MAC in the one form the log endpoint will accept.
    ///
    /// `/logs/dhcp-activity` compares `mac_address` against a Postgres
    /// `MACADDR` column after lower-casing it — no canonicalisation of its own.
    /// Anything Postgres cannot cast raises a **500, not a 422**, so a
    /// technician typing the address off a label exactly as printed would get
    /// a server error rather than an answer. Normalising here is what makes
    /// the field forgiving.
    static func canonicalMAC(_ text: String) -> String? {
        let digits = text.filter(\.isHexDigit).lowercased()
        guard digits.count == 12 else { return nil }
        return stride(from: 0, to: 12, by: 2)
            .map { offset -> String in
                let start = digits.index(digits.startIndex, offsetBy: offset)
                let end = digits.index(start, offsetBy: 2)
                return String(digits[start..<end])
            }
            .joined(separator: ":")
    }

    /// A dotted-quad, loosely — enough to choose which filter to send.
    static func isIPv4Like(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}

private struct LeaseHistoryRow: View {
    let result: ClientLookupView.Result

    private var row: Components.Schemas.LeaseHistoryRow { result.row }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.ipAddress).font(.body.monospaced())
                Spacer()
                Badge(text: row.leaseState, tint: tint(for: row.leaseState))
            }
            Text(row.macAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
            if let hostname = row.hostname, !hostname.isEmpty {
                Text(hostname).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(result.serverName)
                if let started = row.startedAt {
                    Text("from \(started.formatted(date: .abbreviated, time: .shortened))")
                }
                Text("to \(row.expiredAt.formatted(date: .abbreviated, time: .shortened))")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }

    private func tint(for state: String) -> Color {
        switch state.lowercased() {
        case "active", "current": .green
        case "expired", "released": .secondary
        case "declined", "conflict": .red
        default: .secondary
        }
    }
}
