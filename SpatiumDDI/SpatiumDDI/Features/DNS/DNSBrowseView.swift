//
//  DNSBrowseView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// DNS browse: group → zone → record.
///
/// Reading, plus one write: adding a record to a zone. A mistyped record is a
/// production outage with a TTL attached, so creation goes through its own
/// sheet, states the record in zone-file form before sending, and stops there —
/// editing and deleting live records stay desktop work.
struct DNSBrowseView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<[Components.Schemas.ServerGroupResponse]> = .idle

    var body: some View {
        List {
            LoadStateView(
                state: state,
                emptyMessage: "No DNS server groups are defined on this server.",
                retry: load
            ) { groups in
                ForEach(groups, id: \.id) { group in
                    NavigationLink {
                        DNSZonesView(session: session, group: group)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.name)
                            if !group.description.isEmpty {
                                Text(group.description).font(.caption).foregroundStyle(.secondary)
                            }
                            HStack(spacing: 6) {
                                Badge(text: group.groupType, tint: .indigo)
                                if group.isRecursive { Badge(localised: "recursive") }
                                if group.isPublicFacing == true { Badge(localised: "public", tint: .orange) }
                                if group.catalogZonesEnabled { Badge(localised: "catalog") }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("DNS")
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            switch try await session.client.listGroupsApiV1DnsGroupsGet() {
            case .ok(let ok):
                // Server order is insertion order; a name sort is what makes a
                // group findable on a small screen.
                return try ok.body.json.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// Zones within a DNS group.
struct DNSZonesView: View {
    let session: ControlPlaneSession
    let group: Components.Schemas.ServerGroupResponse

    @State private var state: LoadState<[Components.Schemas.ZoneResponse]> = .idle
    @State private var query = ""

    private var visible: [Components.Schemas.ZoneResponse] {
        guard case .loaded(let zones) = state else { return [] }
        guard !query.isEmpty else { return zones }
        return zones.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            // Routed through LoadStateView rather than checking `.loaded` by
            // hand: it already distinguishes a group with no zones from a
            // filter that matched none, and doing it manually is what made an
            // empty group render as a failed search.
            LoadStateView(state: state, emptyMessage: "This group has no zones.", retry: load) { _ in
                if visible.isEmpty {
                    NoMatchesView(query: query, filterDescription: "No zone matches this filter.")
                } else {
                    ForEach(visible, id: \.id) { zone in
                        NavigationLink {
                            DNSZoneDetailView(session: session, group: group, zone: zone)
                        } label: {
                            ZoneRow(zone: zone)
                        }
                    }
                }
            }
        }
        .navigationTitle(group.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Filter zones")
        .dismissableKeyboard()
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            let response = try await session.client.listZonesApiV1DnsGroupsGroupIdZonesGet(
                path: .init(groupId: group.id)
            )
            switch response {
            case .ok(let ok):
                return try ok.body.json.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

private struct ZoneRow: View {
    let zone: Components.Schemas.ZoneResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(zone.name).font(.body.monospaced())
            HStack(spacing: 6) {
                Badge(text: zone.zoneType, tint: .indigo)
                if zone.dnssecEnabled { Badge(localised: "DNSSEC", tint: .green) }
                if zone.viewId != nil { Badge(localised: "view", tint: .purple) }
                if zone.isAutoGenerated { Badge(localised: "auto") }
                Spacer()
                // The serial is how an operator tells whether what they are
                // looking at is what the servers last loaded.
                Text("serial \(zone.lastSerial)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// One zone: its SOA facts, then its records.
struct DNSZoneDetailView: View {
    let session: ControlPlaneSession
    let group: Components.Schemas.ServerGroupResponse
    let zone: Components.Schemas.ZoneResponse

    @State private var state: LoadState<[Components.Schemas.RecordResponse]> = .idle
    @State private var total = 0
    @State private var query = ""
    @State private var typeFilter: String?
    @State private var isCreating = false
    @Environment(Permissions.self) private var permissions

    /// Record types present in what has been loaded, most common first.
    private var presentTypes: [String] {
        guard case .loaded(let records) = state else { return [] }
        return Dictionary(grouping: records, by: \.recordType)
            .sorted { left, right in
                // Commonest first, ties broken by name so the chip order is
                // stable across refreshes — a dictionary's own order is not.
                left.value.count == right.value.count
                    ? left.key < right.key
                    : left.value.count > right.value.count
            }
            .map(\.key)
    }

    private var visible: [Components.Schemas.RecordResponse] {
        guard case .loaded(let records) = state else { return [] }
        return records.filter { record in
            (typeFilter == nil || record.recordType == typeFilter)
                && (query.isEmpty
                    || record.name.localizedCaseInsensitiveContains(query)
                    || record.value.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        List {
            Section("Zone") {
                LabeledContent("Type", value: zone.zoneType)
                LabeledContent("Primary NS", value: zone.primaryNs)
                LabeledContent("Admin", value: zone.adminEmail)
                LabeledContent("Serial", value: String(zone.lastSerial))
                LabeledContent("Default TTL", value: Duration.seconds(zone.ttl).formattedCompact)
                LabeledContent("DNSSEC", value: zone.dnssecEnabled ? "Signed" : "Not signed")
                if zone.forwardOnly, !zone.forwarders.isEmpty {
                    LabeledContent("Forwarders", value: zone.forwarders.joined(separator: ", "))
                }
                if !zone.masters.isEmpty {
                    LabeledContent("Masters", value: zone.masters.joined(separator: ", "))
                }
                if let pushed = zone.lastPushedAt {
                    LabeledContent("Last pushed", value: pushed.formatted(.relative(presentation: .named)))
                }
            }

            if !presentTypes.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            FilterChip(label: "All", selected: typeFilter == nil) { typeFilter = nil }
                            ForEach(presentTypes, id: \.self) { type in
                                FilterChip(label: type, selected: typeFilter == type) {
                                    typeFilter = typeFilter == type ? nil : type
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowInsets(.init(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
            }

            Section {
                LoadStateView(state: state, emptyMessage: "This zone has no records.", retry: load) { _ in
                    if visible.isEmpty {
                        NoMatchesView(query: query, filterDescription: "No record matches this filter.")
                    } else {
                        ForEach(visible, id: \.id) { RecordRow(record: $0) }
                    }
                }
            } header: {
                if case .loaded(let records) = state, total > records.count {
                    // Says outright that this is not the whole zone. A silently
                    // truncated record list is the kind of thing an operator
                    // makes a decision on.
                    Text("Records — showing \(records.count) of \(total)")
                } else {
                    Text("Records")
                }
            }
        }
        .navigationTitle(zone.name)
        .navigationBarTitleDisplayMode(.inline)
        // Which group, not just which zone: with split horizon the same name
        // exists in two of them and publishes to different resolvers.
        .breadcrumbs([group.name])
        .searchable(text: $query, prompt: "Filter records")
        .dismissableKeyboard()
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
        .toolbar {
            // A courtesy only — non-negotiable #4. A synthesised zone is
            // excluded here as well as in the sheet, because the reconciler
            // owns it and no grant makes a manual record survive the next sync.
            if zone.tailscaleTenantId == nil,
                permissions.canWrite("dns_record", "dns_zone", "dns_group", id: zone.id)
            {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isCreating = true
                    } label: {
                        Label("New Record", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $isCreating) {
            CreateRecordView(
                session: session,
                group: group,
                zone: zone,
                onCreated: { _ in Task { await fetch() } },
                onDismiss: { isCreating = false }
            )
        }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            // One large page rather than incremental paging: a zone that does
            // not fit in 500 records is not a zone anyone browses by scrolling,
            // and the header says plainly when the list is partial.
            let response = try await session.client
                .listRecordsApiV1DnsGroupsGroupIdZonesZoneIdRecordsGet(
                    path: .init(groupId: group.id, zoneId: zone.id),
                    query: .init(page: 1, pageSize: 500)
                )
            switch response {
            case .ok(let ok):
                let page = try ok.body.json
                total = page.total
                // Numeric-aware, like every other list here: plain `<` puts
                // `web10` before `web2`, which is wrong in a zone full of
                // numbered hosts.
                return page.items.sorted { left, right in
                    let byName = left.name.localizedStandardCompare(right.name)
                    return byName == .orderedSame
                        ? left.recordType < right.recordType
                        : byName == .orderedAscending
                }
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

private struct RecordRow: View {
    let record: Components.Schemas.RecordResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                // Apex records come back named "@" or "", neither of which reads
                // as the zone itself on a small row.
                Text(record.name.isEmpty ? "@" : record.name)
                    .font(.body.monospaced())
                    .lineLimit(1)
                Spacer(minLength: 4)
                Badge(text: record.recordType, tint: .indigo)
            }
            Text(record.value)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                if let ttl = record.ttl {
                    Text(Duration.seconds(ttl).formattedCompact)
                }
                if let priority = record.priority { Text("pri \(priority)") }
                if let weight = record.weight { Text("wt \(weight)") }
                if let port = record.port { Text("port \(port)") }
                if record.autoGenerated { Text("auto-generated") }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

/// A tappable filter pill.
struct FilterChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}
