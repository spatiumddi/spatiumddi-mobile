//
//  NetworkDevicesView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// "Where is this MAC?" — the best question a phone can answer at a rack.
///
/// The `network.device` module polls switches and routers over SNMP, so the
/// platform already knows which port learned a MAC, which IP the router has
/// ARPed, and what LLDP says is plugged into what. Until now none of it reached
/// the app, so an operator with a flapping host walked back to a desk to find
/// out which switch port to look at.
///
/// **Read-only, with one exception.** Poll Now re-reads the device and changes
/// nothing about it, and "poll it again while I watch the port LED" is exactly
/// the on-site loop. Device CRUD, SNMP credentials and CSV import are absent on
/// purpose: configuring the poller is desk work, consuming what it learned is
/// not.
struct NetworkDevicesView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<[Components.Schemas.NetworkDeviceRead]> = .idle
    @State private var total = 0
    @State private var query = ""

    private var visible: [Components.Schemas.NetworkDeviceRead] {
        guard case .loaded(let devices) = state else { return [] }
        guard !query.isEmpty else { return devices }
        return devices.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.ipAddress.localizedCaseInsensitiveContains(query)
                || $0.hostname.localizedCaseInsensitiveContains(query)
                || ($0.vendor ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                LoadStateView(
                    state: state,
                    emptyMessage: "No network devices are registered for polling.",
                    retry: { Task { await fetch() } }
                ) { _ in
                    if visible.isEmpty {
                        NoMatchesView(
                            query: query,
                            filterDescription: "No device matches that name, address or vendor."
                        )
                    } else {
                        ForEach(visible, id: \.id) { device in
                            NavigationLink {
                                NetworkDeviceDetailView(session: session, device: device)
                            } label: {
                                NetworkDeviceRow(device: device)
                            }
                        }
                    }
                }
            } header: {
                if case .loaded(let rows) = state, total > rows.count {
                    Text("Devices — showing \(rows.count) of \(total)")
                } else {
                    Text("Devices")
                }
            } footer: {
                Text("What the SNMP poller has learned. Adding or configuring a device is desk work.")
            }
        }
        .navigationTitle("Devices")
        .searchable(text: $query, prompt: "Filter by name, address or vendor")
        .dismissableKeyboard()
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            let response = try await session.client.listDevicesApiV1NetworkDevicesGet(
                query: .init(page: 1, pageSize: 200)
            )
            switch response {
            case .ok(let ok):
                let page = try ok.body.json
                total = page.total
                return page.items.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

private struct NetworkDeviceRow: View {
    let device: Components.Schemas.NetworkDeviceRead

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(device.name)
                Spacer()
                if !device.isActive { Badge(localised: "not polled", tint: .secondary) }
                PollStatusBadge(status: device.lastPollStatus)
            }
            Text("\(device.ipAddress) · \(device.deviceType)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if let vendor = device.vendor, !vendor.isEmpty {
                Text(verbatim: vendor).font(.caption2).foregroundStyle(.tertiary)
            }
            Text("polled \(Date.relativeOrNever(device.lastPollAt))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

/// How the last poll went, in one word.
///
/// `pending` is its own colour rather than folded into failure: a device that
/// has never been polled and one whose poll broke need different responses, and
/// a seeded estate is full of the first.
struct PollStatusBadge: View {
    let status: String

    var body: some View {
        Badge(text: status, tint: tint)
    }

    private var tint: Color {
        switch status.lowercased() {
        case "ok", "success": .green
        case "pending", "never": .secondary
        case "partial": .orange
        default: .red
        }
    }
}

// MARK: - One device

/// One device: what it is, and the four tables the poller filled in.
struct NetworkDeviceDetailView: View {
    let session: ControlPlaneSession
    let device: Components.Schemas.NetworkDeviceRead

    /// Which table is on screen.
    ///
    /// A picker rather than four screens: these are four views of the same
    /// poll, and an operator hunting a MAC moves between ARP and FDB
    /// constantly — a push and a back tap each way would be most of the work.
    enum Table: String, CaseIterable, Identifiable {
        case arp = "ARP"
        case fdb = "FDB"
        case neighbours = "LLDP"
        case interfaces = "Ports"
        var id: Self { self }
    }

    @Environment(Permissions.self) private var permissions

    @State private var table: Table = .arp
    @State private var filter = ""
    @State private var arp: LoadState<[Components.Schemas.NetworkArpRead]> = .idle
    @State private var fdb: LoadState<[Components.Schemas.NetworkFdbRead]> = .idle
    @State private var neighbours: LoadState<[Components.Schemas.NetworkNeighbourRead]> = .idle
    @State private var interfaces: LoadState<[Components.Schemas.NetworkInterfaceRead]> = .idle
    @State private var pollNotice: FailureMessage?
    @State private var isPolling = false

    private var mayPoll: Bool { permissions.canWrite("manage_network_devices") }

    var body: some View {
        List {
            Section("Device") {
                LabeledContent("Address") {
                    Text(verbatim: device.ipAddress).font(.body.monospaced())
                }
                if !device.hostname.isEmpty { LabeledContent("Host name", value: device.hostname) }
                LabeledContent("Type", value: device.deviceType)
                if let vendor = device.vendor, !vendor.isEmpty {
                    LabeledContent("Vendor", value: vendor)
                }
                if let sysName = device.sysName, !sysName.isEmpty {
                    LabeledContent("System name", value: sysName)
                }
                if let uptime = device.sysUptimeSeconds {
                    LabeledContent("Uptime", value: Duration.seconds(uptime).formattedCompact)
                }
                LabeledContent("SNMP", value: "\(device.snmpVersion) · port \(String(device.snmpPort))")
                LabeledContent("Last poll") {
                    HStack(spacing: 6) {
                        Text(Date.relativeOrNever(device.lastPollAt))
                        PollStatusBadge(status: device.lastPollStatus)
                    }
                }
                if let error = device.lastPollError, !error.isEmpty {
                    // The poller's own words. A wrong community string or an
                    // unreachable host both land here, and both are the
                    // explanation for why every table below is empty.
                    Label {
                        Text(verbatim: error).font(.caption)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(.orange)
                }
            }

            if mayPoll {
                Section {
                    Button {
                        Task { await pollNow() }
                    } label: {
                        HStack {
                            Label("Poll Now", systemImage: "arrow.clockwise")
                            Spacer()
                            if isPolling { ProgressView() }
                        }
                    }
                    .disabled(isPolling)

                    if let pollNotice {
                        Label(pollNotice, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    // Says plainly that this is queued, not done. A poller that
                    // takes thirty seconds and a screen that looks finished
                    // instantly is how somebody concludes the feature is broken.
                    Text(
                        "Queues a poll and returns immediately — the tables below refresh once it has run, not when this returns."
                    )
                }
            }

            Section {
                Picker("Table", selection: $table) {
                    ForEach(Table.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(.init(top: 6, leading: 12, bottom: 6, trailing: 12))
            }

            Section {
                switch table {
                case .arp:
                    LoadStateView(
                        state: arp,
                        emptyMessage: "This device has no ARP entries — it may never have been polled.",
                        retry: { Task { await fetch(.arp) } }
                    ) { rows in
                        let matches = rows.filter {
                            matchesFilter($0.ipAddress, $0.macAddress, $0.interfaceName)
                        }
                        rowsOrNoMatch(matches.isEmpty && !rows.isEmpty) {
                            ForEach(matches, id: \.id) { entry in
                                ARPRow(entry: entry)
                            }
                        }
                    }
                case .fdb:
                    LoadStateView(
                        state: fdb,
                        emptyMessage: "This device has no forwarding entries.",
                        retry: { Task { await fetch(.fdb) } }
                    ) { rows in
                        let matches = rows.filter { matchesFilter($0.macAddress, $0.interfaceName) }
                        rowsOrNoMatch(matches.isEmpty && !rows.isEmpty) {
                            ForEach(matches, id: \.id) { entry in
                                FDBRow(entry: entry)
                            }
                        }
                    }
                case .neighbours:
                    LoadStateView(
                        state: neighbours,
                        emptyMessage: "No LLDP neighbours have been seen.",
                        retry: { Task { await fetch(.neighbours) } }
                    ) { rows in
                        let matches = rows.filter {
                            matchesFilter($0.remoteSysName, $0.remotePortId, $0.interfaceName)
                        }
                        rowsOrNoMatch(matches.isEmpty && !rows.isEmpty) {
                            ForEach(matches, id: \.id) { entry in
                                NeighbourRow(entry: entry)
                            }
                        }
                    }
                case .interfaces:
                    LoadStateView(
                        state: interfaces,
                        emptyMessage: "No interfaces have been read from this device.",
                        retry: { Task { await fetch(.interfaces) } }
                    ) { rows in
                        let matches = rows.filter { matchesFilter($0.name, $0.alias, $0.description) }
                        rowsOrNoMatch(matches.isEmpty && !rows.isEmpty) {
                            ForEach(matches, id: \.id) { entry in
                                InterfaceRow(entry: entry)
                            }
                        }
                    }
                }
            } header: {
                Text(table.rawValue)
            } footer: {
                Text(footer)
            }
        }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filter, prompt: "Filter by MAC, IP or port")
        .dismissableKeyboard()
        .refreshable { await fetch(table) }
        .task(id: table) { await fetch(table) }
    }

    /// Either the rows, or the "your filter hid everything" state — which is
    /// not the same answer as the table being empty.
    @ViewBuilder
    private func rowsOrNoMatch(_ filteredEverythingOut: Bool, @ViewBuilder rows: () -> some View)
        -> some View
    {
        if filteredEverythingOut {
            NoMatchesView(query: filter, filterDescription: "Nothing in this table matches.")
        } else {
            rows()
        }
    }

    private func matchesFilter(_ fields: String?...) -> Bool {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return fields.contains { ($0 ?? "").localizedCaseInsensitiveContains(needle) }
    }

    private var footer: LocalizedStringResource {
        switch table {
        case .arp: "Which IP the device has resolved to which MAC — a layer-3 answer."
        case .fdb: "Which port learned which MAC — the answer to \"where is this device plugged in\"."
        case .neighbours: "What LLDP says is on the other end of each port."
        case .interfaces: "The device's ports, as SNMP reports them."
        }
    }

    private func pollNow() async {
        isPolling = true
        pollNotice = nil
        defer { isPolling = false }
        do {
            let response = try await session.client
                .pollDeviceNowApiV1NetworkDevicesDeviceIdPollNowPost(path: .init(deviceId: device.id))
            switch response {
            case .accepted(let accepted):
                let result = try accepted.body.json
                pollNotice = .app(
                    "Poll queued \(result.queuedAt.formatted(.relative(presentation: .named))). Pull to refresh once it has run."
                )
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                pollNotice = message
            }
        }
    }

    private func fetch(_ table: Table) async {
        switch table {
        case .arp:
            arp = .loading
            arp = await LoadState.fetching {
                let response = try await session.client.listArpApiV1NetworkDevicesDeviceIdArpGet(
                    path: .init(deviceId: device.id), query: .init(page: 1, pageSize: 500)
                )
                switch response {
                case .ok(let ok): return try ok.body.json.items
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }

        case .fdb:
            fdb = .loading
            fdb = await LoadState.fetching {
                let response = try await session.client.listFdbApiV1NetworkDevicesDeviceIdFdbGet(
                    path: .init(deviceId: device.id), query: .init(page: 1, pageSize: 500)
                )
                switch response {
                case .ok(let ok): return try ok.body.json.items
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }

        case .neighbours:
            neighbours = .loading
            neighbours = await LoadState.fetching {
                let response = try await session.client
                    .listNeighboursApiV1NetworkDevicesDeviceIdNeighboursGet(
                        path: .init(deviceId: device.id), query: .init(page: 1, pageSize: 200)
                    )
                switch response {
                case .ok(let ok): return try ok.body.json.items
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }

        case .interfaces:
            interfaces = .loading
            interfaces = await LoadState.fetching {
                let response = try await session.client
                    .listInterfacesApiV1NetworkDevicesDeviceIdInterfacesGet(
                        path: .init(deviceId: device.id), query: .init(page: 1, pageSize: 500)
                    )
                switch response {
                case .ok(let ok):
                    return try ok.body.json.items.sorted { $0.ifIndex < $1.ifIndex }
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }
        }
    }
}

// MARK: - Rows

private struct ARPRow: View {
    let entry: Components.Schemas.NetworkArpRead

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.ipAddress).font(.body.monospaced())
                Spacer()
                Badge(text: entry.state, tint: entry.state.lowercased() == "reachable" ? .green : .secondary)
            }
            Text(entry.macAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if let name = entry.interfaceName, !name.isEmpty { Text(verbatim: name) }
                if let vrf = entry.vrfName, !vrf.isEmpty { Text(verbatim: vrf) }
                Text("seen \(entry.lastSeen.formatted(.relative(presentation: .named)))")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

private struct FDBRow: View {
    let entry: Components.Schemas.NetworkFdbRead

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.macAddress).font(.body.monospaced())
                Spacer()
                if let vlan = entry.vlanId { Badge(text: "VLAN \(String(vlan))", tint: .teal) }
            }
            // The port is the answer this table exists to give, so it is the
            // line that reads as the answer rather than as metadata.
            Text(verbatim: entry.interfaceName ?? entry.interfaceId)
                .font(.caption.weight(.medium))
            HStack(spacing: 8) {
                Text(verbatim: entry.fdbType)
                Text("seen \(entry.lastSeen.formatted(.relative(presentation: .named)))")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

private struct NeighbourRow: View {
    let entry: Components.Schemas.NetworkNeighbourRead

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(verbatim: entry.remoteSysName ?? entry.remoteChassisId).lineLimit(1)
                Spacer()
                if let local = entry.interfaceName, !local.isEmpty {
                    Text(verbatim: local).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Text(verbatim: entry.remotePortDesc ?? entry.remotePortId)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if let desc = entry.remoteSysDesc, !desc.isEmpty {
                Text(verbatim: desc).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
    }
}

private struct InterfaceRow: View {
    let entry: Components.Schemas.NetworkInterfaceRead

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(entry.name).font(.body.monospaced())
                Spacer()
                if let oper = entry.operStatus {
                    Badge(text: oper, tint: oper.lowercased() == "up" ? .green : .secondary)
                }
            }
            if let alias = entry.alias, !alias.isEmpty {
                Text(verbatim: alias).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(verbatim: "if \(entry.ifIndex)")
                if let speed = entry.speedBps, speed > 0 { Text(verbatim: LinkSpeed.describe(speed)) }
                if let mac = entry.macAddress, !mac.isEmpty { Text(verbatim: mac) }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

/// A port speed in the units a network engineer says out loud.
///
/// SNMP reports bits per second, so a gigabit port is `1000000000` — a number
/// nobody reads at a glance. Decimal multiples, not binary: a "1G" port is
/// 10⁹ bits, and using 2³⁰ here would render it as 0.93G.
nonisolated enum LinkSpeed {
    static func describe(_ bitsPerSecond: Int) -> String {
        switch bitsPerSecond {
        case 1_000_000_000...:
            "\((Double(bitsPerSecond) / 1_000_000_000).formatted(.number.precision(.fractionLength(0...1))))G"
        case 1_000_000...:
            "\((Double(bitsPerSecond) / 1_000_000).formatted(.number.precision(.fractionLength(0...1))))M"
        case 1_000...:
            "\((Double(bitsPerSecond) / 1_000).formatted(.number.precision(.fractionLength(0...1))))k"
        default:
            "\(bitsPerSecond) bps"
        }
    }
}
