//
//  AdminViews.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// Never-before-seen MACs on the network.
///
/// Arpwatch, essentially. The value on a phone is that "something new appeared
/// on the plant floor segment" is a question you want answered while you are
/// standing near the plant floor.
struct NewDevicesView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<[Components.Schemas.SightingOut]> = .idle
    @State private var total = 0
    @State private var includeRandomised = false

    var body: some View {
        List {
            Section {
                // Randomised MACs are excluded by default upstream too: a modern
                // phone walking past generates a new one every time, and they
                // would bury the sightings that mean something.
                Toggle("Include randomised MACs", isOn: $includeRandomised)
            } footer: {
                Text("Phones rotate their MAC by design, so those sightings are usually noise.")
            }

            Section {
                LoadStateView(
                    state: state,
                    emptyMessage: "No new devices have been seen.",
                    retry: { Task { await fetch() } }
                ) { sightings in
                    ForEach(sightings, id: \.id) { sighting in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(sighting.ipAddress).font(.body.monospaced())
                                Spacer()
                                Badge(
                                    text: sighting.classification,
                                    tint: sighting.classification.lowercased() == "unknown"
                                        ? .orange : .secondary
                                )
                            }
                            Text(sighting.macAddress).font(.caption.monospaced()).foregroundStyle(.secondary)
                            HStack(spacing: 8) {
                                if let vendor = sighting.ouiVendor, !vendor.isEmpty { Text(vendor) }
                                if let subnet = sighting.subnetName, !subnet.isEmpty { Text(subnet) }
                                Text(
                                    "first seen \(sighting.firstSeen.formatted(.relative(presentation: .named)))"
                                )
                            }
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            if sighting.isRandomized {
                                Badge(text: "randomised MAC")
                            }
                        }
                    }
                }
            } header: {
                if case .loaded(let rows) = state, total > rows.count {
                    Text("Sightings — showing \(rows.count) of \(total)")
                } else {
                    Text("Sightings")
                }
            }
        }
        .navigationTitle("New Devices")
        .refreshable { await fetch() }
        .task(id: includeRandomised) { await fetch() }
    }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            let response = try await session.client.listSightingsApiV1NewDevicesSightingsGet(
                query: .init(includeRandomized: includeRandomised, page: 1, pageSize: 200)
            )
            switch response {
            case .ok(let ok):
                let page = try ok.body.json
                total = page.total
                return page.items.sorted { $0.firstSeen > $1.firstSeen }
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// Who can sign in, who is signed in, and what tokens exist.
///
/// One screen with a picker rather than three sidebar entries, for the same
/// reason ownership is: these are looked up together when answering one
/// question — "who has access, and should they still".
struct AccessView: View {
    let session: ControlPlaneSession

    enum Kind: String, CaseIterable, Identifiable {
        case users = "Users"
        case sessions = "Sessions"
        case tokens = "Tokens"
        var id: Self { self }
    }

    @State private var kind: Kind = .users
    @State private var users: LoadState<[Components.Schemas.AppApiV1UsersRouterUserResponse]> = .idle
    @State private var sessions: LoadState<[Components.Schemas.SessionRow]> = .idle
    @State private var tokens: LoadState<[Components.Schemas.ApiTokenResponse]> = .idle

    var body: some View {
        List {
            Section {
                Picker("Kind", selection: $kind) {
                    ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowInsets(.init(top: 6, leading: 12, bottom: 6, trailing: 12))
            }

            switch kind {
            case .users:
                LoadStateView(state: users, emptyMessage: "No users.", retry: { load(.users) }) { rows in
                    ForEach(rows, id: \.id) { user in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(user.displayName.isEmpty ? user.username : user.displayName)
                                Spacer()
                                if user.isSuperadmin { Badge(text: "superadmin", tint: .orange) }
                                if !user.isActive { Badge(text: "disabled", tint: .secondary) }
                                if user.locked == true { Badge(text: "locked", tint: .red) }
                            }
                            Text("\(user.username) · \(user.authSource)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("last login \(Date.relativeOrNever(user.lastLoginAt))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }

            case .sessions:
                LoadStateView(
                    state: sessions, emptyMessage: "No active sessions.", retry: { load(.sessions) }
                ) { rows in
                    ForEach(rows, id: \.id) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(row.displayName.isEmpty ? row.username : row.displayName)
                                Spacer()
                                if row.isCurrent { Badge(text: "this device", tint: .green) }
                                if row.revoked { Badge(text: "revoked", tint: .red) }
                            }
                            if let ip = row.sourceIp, !ip.isEmpty {
                                Text(ip).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                            if let agent = row.userAgent, !agent.isEmpty {
                                Text(agent).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Text(
                                "seen \(Date.relativeOrNever(row.lastSeenAt)) · expires \(row.expiresAt.formatted(.relative(presentation: .named)))"
                            )
                            .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }

            case .tokens:
                LoadStateView(state: tokens, emptyMessage: "No API tokens.", retry: { load(.tokens) }) {
                    rows in
                    ForEach(rows, id: \.id) { token in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(token.name)
                                Spacer()
                                if !token.isActive { Badge(text: "inactive", tint: .secondary) }
                                ExpiryBadge(date: token.expiresAt)
                            }
                            // The prefix only. The secret is shown once, at
                            // mint time, and this app has no business
                            // displaying one even if the API offered it.
                            Text("\(token.prefix)… · \(token.scope)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text("last used \(Date.relativeOrNever(token.lastUsedAt))")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Access")
        .refreshable { await fetch(kind) }
        .task(id: kind) { await fetch(kind) }
    }

    private func load(_ kind: Kind) { Task { await fetch(kind) } }

    private func fetch(_ kind: Kind) async {
        switch kind {
        case .users:
            if case .loaded = users { return }
            users = .loading
            users = await LoadState.fetching {
                switch try await session.client.listUsersApiV1UsersGet() {
                case .ok(let ok):
                    return try ok.body.json.sorted {
                        $0.username.localizedStandardCompare($1.username) == .orderedAscending
                    }
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }

        case .sessions:
            if case .loaded = sessions { return }
            sessions = .loading
            sessions = await LoadState.fetching {
                switch try await session.client.listAllSessionsApiV1SessionsGet() {
                case .ok(let ok):
                    return try ok.body.json.sorted {
                        ($0.lastSeenAt ?? $0.createdAt) > ($1.lastSeenAt ?? $1.createdAt)
                    }
                case .unprocessableContent: throw APIStatusError(status: 422)
                case .undocumented(let statusCode, let payload):
                    throw await APIStatusError(status: statusCode, payload: payload)
                }
            }

        case .tokens:
            if case .loaded = tokens { return }
            tokens = .loading
            tokens = await LoadState.fetching {
                switch try await session.client.listTokensApiV1ApiTokensGet() {
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
}

/// The audit log — what was done, by whom, and whether it worked.
struct AuditLogView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<[Components.Schemas.AuditLogResponse]> = .idle
    @State private var total = 0

    var body: some View {
        List {
            LoadStateView(
                state: state, emptyMessage: "Nothing has been recorded.", retry: { Task { await fetch() } }
            ) { entries in
                ForEach(entries, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.action).font(.subheadline.weight(.medium))
                            Spacer()
                            // A failed action in an audit log is the row worth
                            // finding, so it is coloured rather than uniform.
                            Badge(
                                text: entry.result,
                                tint: entry.result.lowercased() == "success" ? .green : .red
                            )
                        }
                        Text(entry.resourceDisplay.isEmpty ? entry.resourceType : entry.resourceDisplay)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: 8) {
                            Text(entry.userDisplayName)
                            if let ip = entry.sourceIp, !ip.isEmpty { Text(ip) }
                            Text(entry.timestamp.formatted(.relative(presentation: .named)))
                        }
                        .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .navigationTitle("Audit Log")
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            switch try await session.client.listAuditLogApiV1AuditGet(query: .init(limit: 200)) {
            case .ok(let ok):
                let page = try ok.body.json
                total = page.total
                return page.items
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// Soft-deleted rows, still restorable.
struct TrashView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<[Components.Schemas.TrashEntry]> = .idle

    var body: some View {
        List {
            LoadStateView(
                state: state, emptyMessage: "Trash is empty.", retry: { Task { await fetch() } }
            ) { entries in
                ForEach(entries, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.nameOrCidr).font(.body.monospaced()).lineLimit(1)
                            Spacer(minLength: 4)
                            Badge(text: entry._type, tint: .indigo)
                        }
                        HStack(spacing: 8) {
                            if let by = entry.deletedByUsername, !by.isEmpty { Text("by \(by)") }
                            Text(entry.deletedAt.formatted(.relative(presentation: .named)))
                            // A cascade delete took other rows with it, and
                            // restoring brings them all back — worth knowing
                            // before anyone reaches for the web console.
                            if entry.batchSize > 1 { Text("\(entry.batchSize) rows in this deletion") }
                        }
                        .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .navigationTitle("Trash")
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            switch try await session.client.listTrashApiV1AdminTrashGet(query: .init(limit: 200)) {
            case .ok(let ok):
                let page = try ok.body.json
                return page.items.sorted { $0.deletedAt > $1.deletedAt }
            case .unprocessableContent: throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}
