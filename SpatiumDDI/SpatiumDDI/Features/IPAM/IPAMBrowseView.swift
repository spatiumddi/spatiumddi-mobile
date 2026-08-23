//
//  IPAMBrowseView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// IPAM browse: space → block → subnet → address.
///
/// Read-only. Phase 1 is read-mostly, and nothing here mutates a production
/// network — every row is a navigation, not an action.
struct IPAMBrowseView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<[Components.Schemas.IPSpaceResponse]> = .idle

    var body: some View {
        List {
            LoadStateView(state: state, emptyMessage: "No IP spaces are defined on this server.", retry: load)
            { spaces in
                ForEach(spaces, id: \.id) { space in
                    NavigationLink {
                        IPAMBlocksView(session: session, space: space)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(space.name)
                                if space.isDefault {
                                    Text("DEFAULT")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(.tint.opacity(0.15), in: Capsule())
                                }
                            }
                            if !space.description.isEmpty {
                                Text(space.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("IP Spaces")
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            // Switched rather than `.ok`: the shorthand collapses every status
            // the document doesn't declare — 401, 403, 503 — into an opaque
            // runtime error, and non-negotiable #4 says those must be shown for
            // what they are.
            switch try await session.client.listSpacesApiV1IpamSpacesGet() {
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

/// Blocks within a space.
struct IPAMBlocksView: View {
    let session: ControlPlaneSession
    let space: Components.Schemas.IPSpaceResponse

    @State private var state: LoadState<[Components.Schemas.IPBlockResponse]> = .idle

    var body: some View {
        List {
            LoadStateView(state: state, emptyMessage: "This space has no blocks.", retry: load) { blocks in
                ForEach(blocks, id: \.id) { block in
                    NavigationLink {
                        IPAMSubnetsView(session: session, block: block)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(block.network).font(.body.monospaced())
                            if block.name != block.network, !block.name.isEmpty {
                                Text(block.name).font(.caption).foregroundStyle(.secondary)
                            }
                            UtilisationBar(percent: block.utilizationPercent)
                            if let allocated = block.allocatedIps, let total = block.totalIps {
                                // `formattedAddressCount` rather than raw: an
                                // IPv6 block's total comes back clamped to
                                // Int64.max, and printing that as an address
                                // count states a number that is not real.
                                Text(
                                    "\(allocated.formatted()) of \(total.formattedAddressCount) addresses"
                                )
                                .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(space.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            // Filtered by the server: `/ipam/blocks` takes a `space_id`, and an
            // estate's worth of blocks is not something to pull down and discard
            // on a phone. The client-side filter stays as a backstop in case the
            // server ever ignores the parameter.
            let response = try await session.client.listBlocksApiV1IpamBlocksGet(
                query: .init(spaceId: space.id)
            )
            switch response {
            case .ok(let ok):
                return try ok.body.json.filter { $0.spaceId == space.id }
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// Subnets within a block.
struct IPAMSubnetsView: View {
    let session: ControlPlaneSession
    let block: Components.Schemas.IPBlockResponse

    @State private var state: LoadState<[Components.Schemas.SubnetResponse]> = .idle

    var body: some View {
        List {
            LoadStateView(state: state, emptyMessage: "This block has no subnets.", retry: load) { subnets in
                ForEach(subnets, id: \.id) { subnet in
                    NavigationLink {
                        IPAMAddressesView(session: session, subnet: subnet)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(subnet.network).font(.body.monospaced())
                                Spacer()
                                if let vlan = subnet.vlanId {
                                    Text("VLAN \(vlan)").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            if !subnet.name.isEmpty {
                                Text(subnet.name).font(.caption).foregroundStyle(.secondary)
                            }
                            UtilisationBar(percent: subnet.utilizationPercent)
                        }
                    }
                }
            }
        }
        .navigationTitle(block.network)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            let response = try await session.client.listSubnetsApiV1IpamSubnetsGet(
                query: .init(blockId: block.id)
            )
            switch response {
            case .ok(let ok):
                return try ok.body.json.filter { $0.blockId == block.id }
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

/// Addresses within a subnet.
struct IPAMAddressesView: View {
    let session: ControlPlaneSession
    let subnet: Components.Schemas.SubnetResponse

    @State private var state: LoadState<[Components.Schemas.IPAddressResponse]> = .idle
    @State private var query = ""

    private var visible: [Components.Schemas.IPAddressResponse] {
        guard case .loaded(let addresses) = state else { return [] }
        guard !query.isEmpty else { return addresses }
        return addresses.filter {
            $0.address.localizedCaseInsensitiveContains(query)
                || ($0.hostname ?? "").localizedCaseInsensitiveContains(query)
                || ($0.fqdn ?? "").localizedCaseInsensitiveContains(query)
                || ($0.macAddress ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Network", value: subnet.network)
                if let gateway = subnet.gateway { LabeledContent("Gateway", value: gateway) }
                LabeledContent("Status", value: subnet.status)
                LabeledContent("Utilisation") {
                    Text(
                        "\(subnet.allocatedIps.formatted()) / \(subnet.totalIps.formattedAddressCount)"
                    )
                }
            }

            Section("Addresses") {
                LoadStateView(
                    state: state, emptyMessage: "No addresses are recorded in this subnet.", retry: load
                ) { _ in
                    if visible.isEmpty {
                        NoMatchesView(
                            query: query,
                            filterDescription: "No address matches that IP, hostname or MAC."
                        )
                    } else {
                        ForEach(visible, id: \.id) { address in
                            NavigationLink {
                                IPAMAddressDetailView(session: session, address: address, subnet: subnet)
                            } label: {
                                AddressRow(address: address)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(subnet.name.isEmpty ? subnet.network : subnet.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Filter by IP, hostname or MAC")
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            let response = try await session.client
                .listAddressesApiV1IpamSubnetsSubnetIdAddressesGet(path: .init(subnetId: subnet.id))
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

/// One row in the address list.
private struct AddressRow: View {
    let address: Components.Schemas.IPAddressResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(address.address).font(.body.monospaced())
                Spacer()
                Text(address.status).font(.caption2).foregroundStyle(.secondary)
            }
            // An unnamed address comes back as "" rather than null, so `??`
            // alone would hide an fqdn that is present.
            if let name = [address.hostname, address.fqdn]
                .compactMap({ $0 }).first(where: { !$0.isEmpty })
            {
                Text(name).font(.caption).foregroundStyle(.secondary)
            }
            if let mac = address.macAddress, !mac.isEmpty {
                Text(mac).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
        }
    }
}
