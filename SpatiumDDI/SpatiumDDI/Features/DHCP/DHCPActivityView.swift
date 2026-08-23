//
//  DHCPActivityView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// What the DHCP server actually recorded, filterable by MAC.
///
/// Distinct from the server's "recent events", which are audit rows about the
/// *server* — who restarted the agent. This is the daemon's own log.
///
/// **Not the full packet exchange, and it does not claim to be.** The agent
/// pins Kea's logger to INFO, and `DHCP4_PACKET_RECEIVED` / `_SEND` are DEBUG,
/// so DISCOVER and OFFER are not written down. What survives is the outcome —
/// allocation, decline, NAK, conflict — which is what a technician needs
/// anyway, but promising a DORA trace and delivering this would be worse than
/// saying so.
///
/// The endpoint is a POST because the filter travels as a body. It reads a log
/// and returns rows; it changes nothing. The rule this app holds to is about
/// not mutating a production network, not about HTTP verbs.
struct DHCPActivityView: View {
    let session: ControlPlaneSession
    /// Pre-filled when arriving from a client lookup.
    var initialMAC: String?

    @State private var servers: LoadState<[Components.Schemas.AppApiV1DhcpServersServerResponse]> = .idle
    @State private var selectedServer: String?
    @State private var macFilter = ""
    @State private var state: LoadState<[Components.Schemas.DHCPActivityLogRow]> = .idle
    @State private var truncated = false

    var body: some View {
        List {
            Section("Server") {
                LoadStateView(
                    state: servers,
                    emptyMessage:
                        "No Kea DHCP servers are registered. This log is Kea-only; Windows DHCP records its activity elsewhere.",
                    retry: { Task { await loadServers() } }
                ) { servers in
                    Picker("Server", selection: $selectedServer) {
                        ForEach(servers, id: \.id) { server in
                            Text(server.name).tag(Optional(server.id))
                        }
                    }
                }
            }

            Section {
                TextField("Filter by MAC (optional)", text: $macFilter)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit { Task { await fetch() } }
                Button {
                    Task { await fetch() }
                } label: {
                    HStack {
                        Label("Fetch Log", systemImage: "doc.text.magnifyingglass")
                        Spacer()
                        if case .loading = state { ProgressView() }
                    }
                }
                .disabled(selectedServer == nil)
            } footer: {
                Text(
                    "The server matches a MAC exactly, so enter all twelve digits — separators don't matter. Leave it empty to see everything. The log keeps 24 hours."
                )
            }

            Section {
                LoadStateView(
                    state: state,
                    emptyMessage: macFilter.isEmpty
                        ? "This server has logged nothing in the window."
                        : "Nothing logged for that MAC. It may not be reaching this server at all.",
                    retry: { Task { await fetch() } }
                ) { rows in
                    ForEach(rows, id: \.id) { ActivityRow(row: $0) }
                }
            } header: {
                Text("Activity")
            } footer: {
                // The server caps what it returns. Saying so matters: an
                // operator who thinks they are looking at the whole log will
                // conclude a packet never arrived.
                if truncated {
                    Text("The server truncated this log — narrow the filter to see further back.")
                }
            }
        }
        .navigationTitle("DHCP Log")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let initialMAC, macFilter.isEmpty { macFilter = initialMAC }
            if case .idle = servers { await loadServers() }
        }
    }

    private func loadServers() async {
        servers = .loading
        servers = await LoadState.fetching {
            switch try await session.client.listServersApiV1DhcpServersGet() {
            case .ok(let ok):
                // Kea only. The endpoint rejects any other driver with a 400,
                // so offering a Windows server in the picker would be offering
                // a guaranteed error — Windows DHCP logs live behind a
                // different endpoint entirely.
                let list = try ok.body.json.filter { $0.driver.lowercased() == "kea" }
                if selectedServer == nil { selectedServer = list.first?.id }
                return list
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
        // Arriving with a MAC means the operator already asked a question;
        // answer it rather than making them tap again.
        if initialMAC != nil, selectedServer != nil { await fetch() }
    }

    private func fetch() async {
        guard let serverId = selectedServer else { return }
        let typed = macFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .loading

        // The server lower-cases this and compares it straight against a
        // Postgres MACADDR column, so a value Postgres cannot cast comes back
        // as a 500. Refuse locally with something readable instead.
        var mac: String?
        if !typed.isEmpty {
            guard let canonical = ClientIdentifier.canonicalMAC(typed) else {
                state = .failed(
                    .app(
                        "\"\(typed)\" isn't a MAC address. Enter all twelve hex digits — separators are optional."
                    )
                )
                return
            }
            mac = canonical
        }

        state = await LoadState.fetching {
            let response = try await session.client.queryDhcpActivityApiV1LogsDhcpActivityPost(
                body: .json(.init(macAddress: mac, maxEvents: 300, serverId: serverId))
            )
            switch response {
            case .ok(let ok):
                let body = try ok.body.json
                truncated = body.truncated
                return body.events.sorted { $0.ts > $1.ts }
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

private struct ActivityRow: View {
    let row: Components.Schemas.DHCPActivityLogRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let code = row.code, !code.isEmpty {
                    Badge(text: code, tint: DHCPMessage.tint(for: code))
                }
                Spacer()
                Text(row.ts.formatted(date: .omitted, time: .standard))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                if let mac = row.macAddress, !mac.isEmpty {
                    Text(mac).font(.caption.monospaced())
                }
                if let ip = row.ipAddress, !ip.isEmpty {
                    Text(ip).font(.caption.monospaced())
                }
            }
            .foregroundStyle(.secondary)
            // The raw line is the thing an operator actually reads — every
            // other field here is the platform's parse of it, and the parse is
            // what would be wrong if anything is.
            Text(row.raw)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .padding(.vertical, 1)
    }
}

/// Colouring for the DHCP message codes that matter.
///
/// A NAK or a DECLINE is the line someone is scrolling to find, so those are
/// the ones that get a colour; the rest of a healthy exchange stays quiet.
nonisolated enum DHCPMessage {
    static func tint(for code: String) -> Color {
        let upper = code.uppercased()
        if upper.contains("NAK") || upper.contains("DECLINE") || upper.contains("ERROR")
            || upper.contains("FAIL")
        {
            return .red
        }
        if upper.contains("ACK") { return .green }
        if upper.contains("OFFER") || upper.contains("DISCOVER") || upper.contains("REQUEST") {
            return .blue
        }
        if upper.contains("WARN") || upper.contains("CONFLICT") || upper.contains("EXPIRE") {
            return .orange
        }
        return .secondary
    }
}
