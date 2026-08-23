//
//  ChangeRequestsView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// Change requests awaiting a decision.
///
/// Read-only here. Deciding one is a Phase 2 write, and the reason this screen
/// exists first is that an approver away from a desk usually needs to know
/// *what* is queued and how risky it is long before they can act — "is this
/// worth stopping for" is the question, and it has an answer without a write.
struct ChangeRequestsView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<[Components.Schemas.ChangeRequestResponse]> = .idle
    @State private var stateFilter: String? = "pending"

    /// The states the control plane uses, pending first because that is the
    /// only one anyone opens this screen for.
    private static let states = ["pending", "approved", "rejected", "expired"]

    var body: some View {
        List {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FilterChip(label: "All", selected: stateFilter == nil) { stateFilter = nil }
                        ForEach(Self.states, id: \.self) { value in
                            FilterChip(label: value.capitalized, selected: stateFilter == value) {
                                stateFilter = stateFilter == value ? nil : value
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(.init(top: 4, leading: 12, bottom: 4, trailing: 12))
            }

            Section {
                LoadStateView(
                    state: state,
                    emptyMessage: stateFilter == "pending"
                        ? "Nothing is waiting for a decision."
                        : "No change requests recorded.",
                    retry: load
                ) { requests in
                    ForEach(requests, id: \.id) { request in
                        NavigationLink {
                            ChangeRequestDetailView(request: request)
                        } label: {
                            ChangeRequestRow(request: request)
                        }
                    }
                }
            }
        }
        .navigationTitle("Change Requests")
        .refreshable { await fetch() }
        .task(id: stateFilter) { await fetch() }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            let response = try await session.client.listRequestsApiV1ChangeRequestsGet(
                query: .init(state: stateFilter, limit: 100)
            )
            switch response {
            case .ok(let ok):
                // Soonest to expire first: a pending request has a deadline,
                // and the one about to lapse is the one that needs attention.
                return try ok.body.json.sorted { $0.expiresAt < $1.expiresAt }
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

private struct ChangeRequestRow: View {
    let request: Components.Schemas.ChangeRequestResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(request.resourceDisplay.isEmpty ? request.resourceType : request.resourceDisplay)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Badge(text: request.state, tint: StateTint.forChangeRequest(request.state))
            }
            Text(request.previewText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                Text(request.operation)
                Text("by \(request.requestedByDisplay)")
                if request.state.lowercased() == "pending" {
                    // The deadline is the actionable part of a pending request.
                    Text("expires \(request.expiresAt.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(Expiry(request.expiresAt).tint)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
    }
}

/// One change request, in full.
struct ChangeRequestDetailView: View {
    let request: Components.Schemas.ChangeRequestResponse

    var body: some View {
        List {
            Section {
                LabeledContent("State") {
                    Badge(text: request.state, tint: StateTint.forChangeRequest(request.state))
                }
                LabeledContent("Operation", value: request.operation)
                LabeledContent("Resource", value: request.resourceType)
                if !request.resourceDisplay.isEmpty {
                    LabeledContent("Target", value: request.resourceDisplay)
                }
            }

            Section("What it would do") {
                Text(request.previewText)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            // The reason the platform decided this needed approving at all. It
            // is the single most useful sentence on the screen for someone
            // deciding whether to stop what they are doing.
            if !request.riskReason.isEmpty {
                Section("Why this needs approval") {
                    Label(request.riskReason, systemImage: "exclamationmark.shield")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }

            Section("Requested") {
                LabeledContent("By", value: request.requestedByDisplay)
                LabeledContent("At", value: request.createdAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Expires") {
                    Text(request.expiresAt.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(Expiry(request.expiresAt).tint)
                }
            }

            if request.decidedAt != nil || request.decidedByDisplay != nil {
                Section("Decision") {
                    if let by = request.decidedByDisplay { LabeledContent("By", value: by) }
                    if let at = request.decidedAt {
                        LabeledContent("At", value: at.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let note = request.decisionNote, !note.isEmpty {
                        LabeledContent("Note", value: note)
                    }
                }
            }

            if let error = request.error, !error.isEmpty {
                Section("Execution error") {
                    Text(error).font(.caption.monospaced()).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            if request.state.lowercased() == "pending" {
                Section {
                    Text(
                        "Approving and rejecting are Phase 2 — decide this in the web console for now."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Change Request")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Shared colouring for the state words this platform uses.
nonisolated enum StateTint {
    static func forChangeRequest(_ state: String) -> Color {
        switch state.lowercased() {
        case "pending": .orange
        case "approved", "executed", "applied": .green
        case "rejected", "failed": .red
        case "expired": .secondary
        default: .secondary
        }
    }
}
