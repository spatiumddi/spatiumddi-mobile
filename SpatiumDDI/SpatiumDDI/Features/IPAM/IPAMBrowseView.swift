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
                                if space.isDefault == true {
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
        do {
            state = .loaded(try await session.client.listSpacesApiV1IpamSpacesGet().ok.body.json)
        } catch {
            state = .failed(APIErrorMessage.describe(error))
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
                                Text("\(allocated.formatted()) of \(total.formatted()) addresses")
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
        do {
            let all = try await session.client.listBlocksApiV1IpamBlocksGet().ok.body.json
            state = .loaded(all.filter { $0.spaceId == space.id })
        } catch {
            state = .failed(APIErrorMessage.describe(error))
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
        do {
            let all = try await session.client.listSubnetsApiV1IpamSubnetsGet().ok.body.json
            state = .loaded(all.filter { $0.blockId == block.id })
        } catch {
            state = .failed(APIErrorMessage.describe(error))
        }
    }
}

/// Addresses within a subnet.
struct IPAMAddressesView: View {
    let session: ControlPlaneSession
    let subnet: Components.Schemas.SubnetResponse

    @State private var state: LoadState<[Components.Schemas.IPAddressResponse]> = .idle

    var body: some View {
        List {
            Section {
                LabeledContent("Network", value: subnet.network)
                if let gateway = subnet.gateway { LabeledContent("Gateway", value: gateway) }
                LabeledContent("Status", value: subnet.status)
                LabeledContent("Utilisation") {
                    Text("\(subnet.allocatedIps.formatted()) / \(subnet.totalIps.formatted())")
                }
            }

            Section("Addresses") {
                LoadStateView(
                    state: state, emptyMessage: "No addresses are recorded in this subnet.", retry: load
                ) { addresses in
                    ForEach(addresses, id: \.id) { address in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(address.address).font(.body.monospaced())
                                Spacer()
                                Text(address.status).font(.caption2).foregroundStyle(.secondary)
                            }
                            if let hostname = address.hostname ?? address.fqdn, !hostname.isEmpty {
                                Text(hostname).font(.caption).foregroundStyle(.secondary)
                            }
                            if let mac = address.macAddress, !mac.isEmpty {
                                Text(mac).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(subnet.name.isEmpty ? subnet.network : subnet.name)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        do {
            state = .loaded(
                try await session.client
                    .listAddressesApiV1IpamSubnetsSubnetIdAddressesGet(path: .init(subnetId: subnet.id))
                    .ok.body.json
            )
        } catch {
            state = .failed(APIErrorMessage.describe(error))
        }
    }
}
