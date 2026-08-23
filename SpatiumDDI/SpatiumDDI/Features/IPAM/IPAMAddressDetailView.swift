//
//  IPAMAddressDetailView.swift
//  SpatiumDDI
//

import OpenAPIRuntime
import SpatiumAPI
import SwiftUI

/// Everything the control plane knows about one address.
///
/// The list row carries what fits on a row. This is the answer to the question
/// an operator actually opens the app for — "what *is* 10.40.12.68, who has had
/// it, and is anything still using it" — which needs the fields a row cannot
/// show: the discovery signal, the fingerprinted device, the DNS and DHCP
/// objects hanging off it.
///
/// Re-fetched by id rather than trusted from the list. The list may have been
/// sitting on screen for a while, and this is the screen someone makes a
/// decision on.
struct IPAMAddressDetailView: View {
    let session: ControlPlaneSession
    let address: Components.Schemas.IPAddressResponse
    let subnet: Components.Schemas.SubnetResponse
    /// The space, block and subnet this address was reached through.
    var trail: [String] = []
    /// Called when this address was edited or removed, so the list behind can
    /// refetch rather than keep showing what it had.
    var onChanged: () -> Void = {}

    @State private var state: LoadState<Components.Schemas.IPAddressResponse> = .idle
    @State private var isEditing = false
    @State private var deletion: DeleteAddressModel?
    @Environment(Permissions.self) private var permissions
    @Environment(\.dismiss) private var dismiss

    /// The freshly-fetched record where one arrived, else what the list had.
    private var current: Components.Schemas.IPAddressResponse {
        if case .loaded(let fetched) = state { return fetched }
        return address
    }

    var body: some View {
        List {
            Section {
                LabeledContent("Address") {
                    Text(current.address).font(.body.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Status") { StatusLabel(status: current.status) }
                if let role = current.role, !role.isEmpty {
                    LabeledContent("Role", value: role)
                }
                LabeledContent("Subnet", value: subnet.network)
                if !current.description.isEmpty {
                    LabeledContent("Description", value: current.description)
                }
            }

            Section("Identity") {
                if let hostname = current.hostname, !hostname.isEmpty {
                    LabeledContent("Hostname", value: hostname)
                }
                if let fqdn = current.fqdn, !fqdn.isEmpty {
                    LabeledContent("FQDN") {
                        Text(fqdn).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
                if let mac = current.macAddress, !mac.isEmpty {
                    LabeledContent("MAC") {
                        Text(mac).font(.callout.monospaced()).textSelection(.enabled)
                    }
                }
                if let vendor = current.vendor, !vendor.isEmpty {
                    LabeledContent("Vendor", value: vendor)
                }
                if noIdentityRecorded {
                    Text("No hostname, FQDN or MAC is recorded for this address.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Only rendered when the platform actually profiled the device;
            // an empty "Device" section would imply the estate knows less than
            // it does, or more.
            if hasDeviceProfile {
                Section("Device") {
                    if let deviceClass = current.deviceClass, !deviceClass.isEmpty {
                        LabeledContent("Class", value: deviceClass)
                    }
                    if let type = current.deviceType, !type.isEmpty {
                        LabeledContent("Type", value: type)
                    }
                    if let manufacturer = current.deviceManufacturer, !manufacturer.isEmpty {
                        LabeledContent("Manufacturer", value: manufacturer)
                    }
                    if current.isVoipPhone == true {
                        LabeledContent("VoIP phone", value: "Yes")
                    }
                    if let profiled = current.lastProfiledAt {
                        LabeledContent("Profiled", value: profiled.formatted(.relative(presentation: .named)))
                    }
                }
            }

            Section("Activity") {
                // The distinction that decides whether an address is safe to
                // reclaim: "never seen" is not the same as "seen a year ago",
                // and neither is the same as "responding right now".
                LabeledContent("Last seen", value: Date.relativeOrNever(current.lastSeenAt))
                if let method = current.lastSeenMethod, !method.isEmpty {
                    LabeledContent("Seen by", value: method)
                }
                if let reserved = current.reservedUntil {
                    LabeledContent(
                        "Reserved until", value: reserved.formatted(date: .abbreviated, time: .shortened))
                }
                if current.autoFromLease == true {
                    LabeledContent("Source", value: "Created from a DHCP lease")
                }
                LabeledContent(
                    "Created", value: current.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent(
                    "Modified", value: current.modifiedAt.formatted(date: .abbreviated, time: .shortened))
            }

            if hasLinkedObjects {
                Section {
                    if current.dnsRecordId != nil {
                        Label("Has a linked DNS record", systemImage: "globe")
                    }
                    if current.dhcpLeaseId != nil {
                        Label("Has an active DHCP lease", systemImage: "arrow.left.arrow.right")
                    }
                    if current.staticAssignmentId != nil {
                        Label("Has a DHCP reservation", systemImage: "pin.fill")
                    }
                    if let aliases = current.aliasCount, aliases > 0 {
                        Label(
                            "^[\(aliases) DNS alias](inflect: true)",
                            systemImage: "arrow.triangle.branch")
                    }
                    if let nat = current.natMappingCount, nat > 0 {
                        Label("^[\(nat) NAT mapping](inflect: true)", systemImage: "arrow.left.and.right")
                    }
                } header: {
                    Text("Linked")
                } footer: {
                    // Says what this screen is not, rather than letting an
                    // operator assume a decision here is complete.
                    Text(
                        "Renumbering or freeing this address affects these too. Follow them up in the web console."
                    )
                }
            }

            if !current.tags.additionalProperties.value.isEmpty {
                Section("Tags") {
                    ForEach(tagPairs, id: \.key) { pair in
                        LabeledContent(pair.key, value: pair.value)
                    }
                }
            }

            if case .failed(let message) = state {
                Section {
                    // Shown, not swallowed — but the list's copy is still on
                    // screen above, so the operator can see both that there is
                    // data and that it could not be confirmed.
                    Label(
                        "Couldn't refresh this address: \(message) What's shown came from the list.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(current.address)
        .breadcrumbs(trail)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
        .toolbar {
            // A courtesy gate — non-negotiable #4. The server enforces this
            // independently and both sheets report a 403 honestly.
            if permissions.canWrite("subnet", "ip_address", id: subnet.id) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Edit", systemImage: "pencil") { isEditing = true }
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            deletion = DeleteAddressModel(session: session, address: current)
                        }
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $isEditing) {
            EditAddressView(
                session: session,
                address: current,
                subnet: subnet,
                onSaved: { saved in
                    // Shown immediately rather than waiting for a refetch: the
                    // server's response is the authority on what was written,
                    // including the FQDN it recomputed.
                    state = .loaded(saved)
                    onChanged()
                },
                onDismiss: { isEditing = false }
            )
        }
        .sheet(item: $deletion) { model in
            DeleteConfirmationSheet(
                subject: model.subject,
                title: "Delete this address?",
                consequence: model.consequence,
                caution: model.caution,
                failure: model.failure,
                isDeleting: model.isDeleting,
                onDelete: {
                    Task {
                        guard await model.delete() else { return }
                        deletion = nil
                        onChanged()
                        // The row this screen is about no longer exists as it
                        // was; staying here would report a state the server no
                        // longer holds.
                        dismiss()
                    }
                },
                onCancel: { deletion = nil }
            )
        }
    }

    private var noIdentityRecorded: Bool {
        (current.hostname ?? "").isEmpty && (current.fqdn ?? "").isEmpty
            && (current.macAddress ?? "").isEmpty
    }

    private var hasDeviceProfile: Bool {
        !(current.deviceClass ?? "").isEmpty || !(current.deviceType ?? "").isEmpty
            || !(current.deviceManufacturer ?? "").isEmpty || current.lastProfiledAt != nil
    }

    private var hasLinkedObjects: Bool {
        current.dnsRecordId != nil || current.dhcpLeaseId != nil
            || current.staticAssignmentId != nil
            || (current.aliasCount ?? 0) > 0 || (current.natMappingCount ?? 0) > 0
    }

    private var tagPairs: [(key: String, value: String)] {
        current.tags.additionalProperties.value
            .compactMap { key, value in
                guard let text = value as? String else { return nil }
                return (key: key, value: text)
            }
            .sorted { $0.key < $1.key }
    }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            let response = try await session.client
                .getAddressApiV1IpamAddressesAddressIdGet(path: .init(addressId: address.id))
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
