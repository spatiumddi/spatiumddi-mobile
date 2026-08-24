//
//  StaleAddressesView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// One row of the stale-address report.
///
/// **Hand-written, and the only such model in the app** — which is worth
/// explaining, because non-negotiable #1 forbids exactly this. That rule exists
/// so a model cannot drift silently from a schema the server published. Here
/// the server published none: `/api/v1/ipam/reports/stale-ips` is typed as a
/// bare `object` in the document, so the generator produces an untyped
/// container and there is nothing to generate against.
///
/// So the payload is re-encoded and decoded through this, and every field is
/// optional apart from the two the row cannot exist without. A field the server
/// renames goes missing rather than failing the whole screen — which for a
/// report is the right failure, since a report that will not render at all
/// tells the operator nothing about their estate.
nonisolated struct StaleAddress: Decodable, Identifiable, Sendable {
    let id: String
    let address: String
    var status: String?
    var hostname: String?
    var macAddress: String?
    /// Days since anything last saw it. **Null means never seen at all**, which
    /// is a different and worse answer than "seen a long time ago".
    var daysStale: Int?
    var lastSeenMethod: String?
    var subnetNetwork: String?
    var subnetName: String?

    enum CodingKeys: String, CodingKey {
        case id, address, status, hostname
        case macAddress = "mac_address"
        case daysStale = "days_stale"
        case lastSeenMethod = "last_seen_method"
        case subnetNetwork = "subnet_network"
        case subnetName = "subnet_name"
    }
}

/// The report as a whole.
nonisolated struct StaleAddressReport: Decodable, Sendable {
    var total: Int
    var staleDays: Int
    var entries: [StaleAddress]

    enum CodingKeys: String, CodingKey {
        case total
        case staleDays = "stale_days"
        case entries
    }

    /// Reads the report out of the untyped payload the generated client hands
    /// back.
    ///
    /// Round-tripped through JSON rather than picked apart by hand: the
    /// container behind that payload holds `Any` values, and unwrapping them
    /// field by field is where a typo becomes a silently-empty screen instead
    /// of a decode error somebody notices.
    ///
    /// Takes `some Encodable` rather than naming the generated payload type,
    /// which keeps this free of both a 90-character type name and an import of
    /// the OpenAPI runtime the app target does not otherwise need.
    init(encoded payload: some Encodable) throws {
        let data = try JSONEncoder().encode(payload)
        self = try JSONDecoder().decode(StaleAddressReport.self, from: data)
    }

    init(total: Int, staleDays: Int, entries: [StaleAddress]) {
        self.total = total
        self.staleDays = staleDays
        self.entries = entries
    }
}

/// What has rotted, and one action to mark it.
///
/// The hygiene screen. An estate accumulates addresses that nothing has
/// answered for in months — a decommissioned host, a VM that moved — and each
/// one is a row somebody will hesitate over before reusing. Marking them
/// deprecated is not a delete: the row stays, with its history, and stops
/// counting as live.
struct StaleAddressesView: View {
    let session: ControlPlaneSession

    @Environment(Permissions.self) private var permissions

    /// The spans worth offering. Ninety days is the server's own default.
    private static let windows = [30, 60, 90, 180, 365]

    @State private var staleDays = 90
    @State private var includeNeverSeen = false
    @State private var state: LoadState<StaleAddressReport> = .idle
    @State private var selection: Set<String> = []
    @State private var isConfirming = false
    @State private var isDeprecating = false
    @State private var outcome: FailureMessage?

    private var mayDeprecate: Bool { permissions.canWrite("ip_address") }

    var body: some View {
        List {
            Section {
                Picker("Stale for", selection: $staleDays) {
                    ForEach(Self.windows, id: \.self) { days in
                        Text("^[\(days) day](inflect: true)").tag(days)
                    }
                }
                Toggle("Include never-seen addresses", isOn: $includeNeverSeen)
            } header: {
                Text("What counts as stale")
            } footer: {
                // The two are genuinely different findings and the distinction
                // decides what to do about them: an address nothing has ever
                // answered for may simply predate discovery being switched on.
                Text(
                    "An address nothing has answered for in that long. \"Never seen\" means discovery has no record of it at all, which is not the same as it having gone quiet."
                )
            }

            Section {
                LoadStateView(
                    state: state,
                    emptyMessage: "Nothing has gone stale in this window.",
                    retry: { Task { await fetch() } }
                ) { report in
                    if report.entries.isEmpty {
                        Text("Nothing has gone stale in this window.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(report.entries) { entry in
                            StaleAddressRow(
                                entry: entry,
                                isSelected: selection.contains(entry.id),
                                isSelectable: mayDeprecate
                            ) {
                                if selection.contains(entry.id) {
                                    selection.remove(entry.id)
                                } else {
                                    selection.insert(entry.id)
                                }
                            }
                        }
                    }
                }
            } header: {
                if case .loaded(let report) = state, report.total > report.entries.count {
                    Text("Stale — showing \(report.entries.count) of \(report.total)")
                } else {
                    Text("Stale")
                }
            } footer: {
                if mayDeprecate, case .loaded(let report) = state, !report.entries.isEmpty {
                    Text("Tap a row to select it. Deprecating keeps the row and its history.")
                }
            }

            if let outcome {
                Section("Result") {
                    Label(outcome, systemImage: "info.circle.fill")
                }
            }
        }
        .navigationTitle("Stale Addresses")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await fetch() }
        .task(id: [staleDays, includeNeverSeen ? 1 : 0]) { await fetch() }
        .toolbar {
            if mayDeprecate, !selection.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    if isDeprecating {
                        ProgressView()
                    } else {
                        Button("Deprecate \(selection.count)") { isConfirming = true }
                    }
                }
            }
        }
        .alert("Deprecate ^[\(selection.count) address](inflect: true)?", isPresented: $isConfirming) {
            Button("Cancel", role: .cancel) {}
            Button("Deprecate") { Task { await deprecate() } }
        } message: {
            Text(verbatim: confirmationText)
        }
    }

    /// Names the addresses rather than only counting them.
    ///
    /// A count alone is not checkable — the operator cannot tell a mis-tap from
    /// the selection they meant. Listing the first few and saying how many more
    /// there are makes it possible to notice.
    private var confirmationText: String {
        let selected = selectedEntries
        var lines = selected.prefix(5).map(\.address)
        if selected.count > lines.count {
            lines.append(String(localized: "…and ^[\(selected.count - lines.count) more](inflect: true)"))
        }
        lines.append(
            String(
                localized:
                    "Each becomes `deprecated`. The row and its history stay, and it stops counting as allocated."
            )
        )
        return lines.joined(separator: "\n")
    }

    private var selectedEntries: [StaleAddress] {
        guard case .loaded(let report) = state else { return [] }
        return report.entries.filter { selection.contains($0.id) }
    }

    private func deprecate() async {
        let ids = Array(selection)
        guard !ids.isEmpty else { return }
        isDeprecating = true
        outcome = nil
        defer { isDeprecating = false }

        do {
            let response = try await session.client
                .deprecateStaleIpsApiV1IpamReportsStaleIpsDeprecatePost(
                    // Explicit ids only. `all_matching` exists and is
                    // deliberately not sent: "deprecate everything that matches
                    // a filter I cannot see the whole of" is a blast radius
                    // that deserves a desk and a bigger screen.
                    body: .json(.init(allMatching: false, ipIds: ids))
                )
            switch response {
            case .ok(let ok):
                let result = try ok.body.json
                selection = []
                var text = String(
                    localized: "^[\(result.deprecatedCount) address](inflect: true) deprecated.")
                if let skipped = result.skipped, !skipped.isEmpty {
                    // The server refuses some rows — one mirroring a live lease,
                    // for instance. Saying how many were skipped stops the
                    // count reading as a failure of the whole action.
                    text += " "
                    text += String(localized: "^[\(skipped.count) was](inflect: true) skipped.")
                }
                outcome = .app("\(text)")
                await fetch()
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                outcome = message
            }
        }
    }

    private func fetch() async {
        state = .loading
        selection = []
        state = await LoadState.fetching {
            let response = try await session.client.getStaleIpReportApiV1IpamReportsStaleIpsGet(
                query: .init(
                    staleDays: staleDays,
                    includeNeverSeen: includeNeverSeen,
                    limit: 200
                )
            )
            switch response {
            case .ok(let ok):
                return try StaleAddressReport(encoded: try ok.body.json)
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

private struct StaleAddressRow: View {
    let entry: StaleAddress
    let isSelected: Bool
    let isSelectable: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                if isSelectable {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(entry.address).font(.body.monospaced())
                        Spacer()
                        if let status = entry.status {
                            Badge(text: status, tint: .secondary)
                        }
                    }
                    if let hostname = entry.hostname, !hostname.isEmpty {
                        Text(verbatim: hostname).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        // Null days is the "never seen" case, and it needs its
                        // own words: "0 days stale" would be the exact opposite
                        // of what it means.
                        if let days = entry.daysStale {
                            Text("^[\(days) day](inflect: true) stale")
                        } else {
                            Text("never seen")
                        }
                        if let network = entry.subnetName ?? entry.subnetNetwork {
                            Text(verbatim: network)
                        }
                        if let mac = entry.macAddress, !mac.isEmpty {
                            Text(verbatim: mac)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable)
    }
}
