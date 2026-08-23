//
//  SearchView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// Global search across IPAM, DNS, DHCP and admin objects.
///
/// The server ranks in SQL before each type's limit and filters every hit
/// through the caller's own read grants, so this view neither re-ranks nor
/// re-filters — doing either locally would only be able to make the result
/// worse, and re-filtering would imply the client is a permission boundary.
struct SearchView: View {
    let session: ControlPlaneSession

    @State private var query = ""
    @State private var state: LoadState<Components.Schemas.SearchResponse> = .idle
    @State private var typeLabels: [String: String] = [:]
    @State private var typeGroups: [String: String] = [:]
    @State private var groupFilter: String?

    /// Result-type groups present in the current results, in server order.
    private var presentGroups: [String] {
        guard case .loaded(let response) = state else { return [] }
        var seen: [String] = []
        for result in response.results {
            let group = groupOf(result._type)
            if !seen.contains(group) { seen.append(group) }
        }
        return seen
    }

    private var visible: [Components.Schemas.SearchResult] {
        guard case .loaded(let response) = state else { return [] }
        guard let groupFilter else { return response.results }
        return response.results.filter { groupOf($0._type) == groupFilter }
    }

    var body: some View {
        List {
            if query.isEmpty {
                ContentUnavailableView(
                    "Search",
                    systemImage: "magnifyingglass",
                    description: Text(
                        "Find an address, subnet, zone, record, scope or reservation by name, IP or MAC."
                    )
                )
            } else {
                if presentGroups.count > 1 {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                FilterChip(label: "All", selected: groupFilter == nil) { groupFilter = nil }
                                ForEach(presentGroups, id: \.self) { group in
                                    FilterChip(label: group.uppercased(), selected: groupFilter == group) {
                                        groupFilter = groupFilter == group ? nil : group
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .listRowInsets(.init(top: 4, leading: 12, bottom: 4, trailing: 12))
                    }
                }

                switch state {
                case .idle, .loading:
                    ProgressView().frame(maxWidth: .infinity)

                case .loaded(let response):
                    if visible.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        // Grouped by type so 40 mixed hits read as a handful of
                        // labelled sections rather than one undifferentiated list.
                        ForEach(sections(of: visible), id: \.type) { section in
                            Section(typeLabels[section.type] ?? section.type) {
                                ForEach(section.results, id: \.id) { SearchResultRow(result: $0) }
                            }
                        }
                        if response.total > response.results.count {
                            Section {
                                Text(
                                    "Showing \(response.results.count) of \(response.total) matches. Narrow the search to see more."
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }

                case .failed(let message):
                    VStack(alignment: .leading, spacing: 12) {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Button("Try Again") { Task { await search() } }
                    }
                }
            }
        }
        .navigationTitle("Search")
        .searchable(
            text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "IP, name, MAC, zone"
        )
        .dismissableKeyboard()
        .task { await fetchTypes() }
        .task(id: query) {
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                state = .idle
                return
            }
            // Debounce: a search fires per keystroke otherwise, and this query
            // hits trigram indexes across twenty tables on the server.
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            await search()
        }
    }

    private func groupOf(_ type: String) -> String {
        typeGroups[type] ?? "other"
    }

    private struct TypeSection {
        let type: String
        let results: [Components.Schemas.SearchResult]
    }

    private func sections(of results: [Components.Schemas.SearchResult]) -> [TypeSection] {
        var order: [String] = []
        var byType: [String: [Components.Schemas.SearchResult]] = [:]
        for result in results {
            if byType[result._type] == nil { order.append(result._type) }
            byType[result._type, default: []].append(result)
        }
        return order.map { TypeSection(type: $0, results: byType[$0] ?? []) }
    }

    private func fetchTypes() async {
        // Labels are presentation sugar; a failure here leaves raw type names,
        // which are still readable, so it does not become an error state.
        guard typeLabels.isEmpty else { return }
        let response = try? await session.client.searchableTypesApiV1SearchTypesGet()
        guard case .ok(let ok) = response, let types = try? ok.body.json else { return }
        typeLabels = Dictionary(uniqueKeysWithValues: types.map { ($0._type, $0.label) })
        typeGroups = Dictionary(uniqueKeysWithValues: types.map { ($0._type, $0.group) })
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        state = .loading
        state = await LoadState.fetching {
            let response = try await session.client.globalSearchApiV1SearchGet(
                query: .init(q: trimmed, limit: 50)
            )
            switch response {
            case .ok(let ok):
                return try ok.body.json
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

private struct SearchResultRow: View {
    let result: Components.Schemas.SearchResult

    /// The one line of context that says *where* this hit lives.
    private var context: String? {
        let candidates = [
            result.context,
            result.dnsZoneName.map { "in \($0)" },
            result.subnetNetwork.map { "in \($0)" },
            result.spaceName.map { "in \($0)" },
            result.description,
        ]
        return candidates.compactMap { $0 }.first { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(result.display).font(.body.monospaced()).lineLimit(1)
                Spacer(minLength: 4)
                if let status = result.status, !status.isEmpty {
                    Badge(text: status, tint: .indigo)
                }
            }
            if let value = result.dnsRecordValue, !value.isEmpty {
                Text(value).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            }
            if let hostname = result.hostname, !hostname.isEmpty {
                Text(hostname).font(.caption).foregroundStyle(.secondary)
            }
            if let mac = result.macAddress, !mac.isEmpty {
                Text(mac).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            if let context {
                Text(context).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
