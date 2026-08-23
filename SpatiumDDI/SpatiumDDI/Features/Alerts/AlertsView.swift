//
//  AlertsView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// The alert list, and the one write it needs.
///
/// Resolving is here because the alternative is worse than an inconvenience:
/// an operator who has just confirmed the pool is fine again cannot say so
/// until they find a laptop, so the alert stays red, and everyone else who
/// looks at the dashboard between now and then re-triages something that is
/// already dealt with.
///
/// Deliberately swipe-then-confirm rather than a full-swipe: a full swipe is a
/// single gesture, and non-negotiable #6 does not carve out an exception for
/// writes that happen to be reversible.
struct AlertsView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<[Components.Schemas.AlertEventResponse]> = .idle
    @State private var openOnly = true
    @State private var severityFilter: Severity?
    /// The alert waiting on a confirmation, if any.
    @State private var pending: Components.Schemas.AlertEventResponse?
    @State private var resolvingID: String?
    @State private var failure: FailureMessage?

    private var events: [Components.Schemas.AlertEventResponse] {
        guard case .loaded(let events) = state else { return [] }
        guard let severityFilter else { return events }
        return events.filter { Severity(apiValue: $0.severity) == severityFilter }
    }

    /// How many of each severity are in the loaded set, for the filter chips.
    private var counts: [Severity: Int] {
        guard case .loaded(let events) = state else { return [:] }
        return events.reduce(into: [:]) { counts, event in
            counts[Severity(apiValue: event.severity), default: 0] += 1
        }
    }

    var body: some View {
        List {
            Section {
                Toggle("Unresolved only", isOn: $openOnly)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        FilterChip(label: "All", selected: severityFilter == nil) { severityFilter = nil }
                        ForEach(Severity.allCases, id: \.self) { severity in
                            let count = counts[severity] ?? 0
                            FilterChip(
                                label: "\(String(localized: severity.label)) \(count)",
                                selected: severityFilter == severity
                            ) {
                                severityFilter = severityFilter == severity ? nil : severity
                            }
                            .disabled(count == 0 && severityFilter != severity)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listRowInsets(.init(top: 4, leading: 12, bottom: 4, trailing: 12))
            }

            Section {
                // "Nothing is firing" and "nothing matches the severity you
                // picked" are different answers, and only the first one is good
                // news. LoadStateView owns the former; the chip filter can only
                // produce the latter.
                LoadStateView(
                    state: state,
                    emptyMessage: openOnly
                        ? "No unresolved alerts on this control plane."
                        : "No alerts recorded.",
                    retry: load
                ) { _ in
                    if events.isEmpty {
                        NoMatchesView(
                            query: "",
                            // The label is used as written rather than
                            // lower-cased: `lowercased()` is locale-unsafe, and
                            // German capitalises nouns mid-sentence anyway.
                            filterDescription: severityFilter.map {
                                "No \($0.label) alerts in this list."
                            } ?? "No alert matches this filter."
                        )
                    } else {
                        ForEach(events, id: \.id) { event in
                            AlertRow(event: event, isResolving: resolvingID == event.id)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    if event.resolvedAt == nil {
                                        Button {
                                            failure = nil
                                            pending = event
                                        } label: {
                                            Label("Resolve", systemImage: "checkmark.circle")
                                        }
                                        .tint(.green)
                                    }
                                }
                        }
                    }
                }
            }

            if let failure {
                Section("Not resolved") {
                    Label(failure, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Alerts")
        .refreshable { await fetch() }
        .task(id: openOnly) { await fetch() }
        .alert(
            "Resolve this alert?",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { event in
            Button("Cancel", role: .cancel) { pending = nil }
            Button("Resolve") { Task { await resolve(event) } }
        } message: { event in
            // The alert's own words, so the operator confirms the thing in
            // front of them rather than "are you sure".
            Text(verbatim: resolutionSummary(for: event))
        }
    }

    /// What is being resolved, named the way the row names it.
    private func resolutionSummary(for event: Components.Schemas.AlertEventResponse) -> String {
        let subject = event.subjectDisplay.isEmpty ? event.subjectType : event.subjectDisplay
        let closing = String(
            localized:
                "It stops counting as unresolved. It fires again if the condition comes back."
        )
        return subject.isEmpty
            ? "\(event.message)\n\n\(closing)"
            : "\(subject)\n\(event.message)\n\n\(closing)"
    }

    private func resolve(_ event: Components.Schemas.AlertEventResponse) async {
        pending = nil
        resolvingID = event.id
        failure = nil
        defer { resolvingID = nil }

        do {
            let response = try await session.client.resolveEventApiV1AlertsEventsEventIdResolvePost(
                path: .init(eventId: event.id)
            )
            switch response {
            case .ok(let ok):
                let resolved = try ok.body.json
                guard case .loaded(let rows) = state else { return }
                // With "unresolved only" on, a resolved alert leaves the list;
                // with it off it stays and grows a badge.
                state = .loaded(
                    RowUpdate.apply(resolved, to: rows, id: \.id) { row in
                        !openOnly || row.resolvedAt == nil
                    }
                )
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        } catch {
            // Nothing about resolving is soft-conflictable, so this never
            // offers to re-send.
            if case .failed(let message) = await WriteFailure.classify(error, forced: true) {
                failure = message
            }
        }
    }

    private func load() { Task { await fetch() } }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            let response = try await session.client.listEventsApiV1AlertsEventsGet(
                query: .init(openOnly: openOnly, limit: 200)
            )
            switch response {
            case .ok(let ok):
                // Most severe first, then most recent — the order an operator
                // triages in, which is not the order the server returns.
                return try ok.body.json.sorted {
                    let left = Severity(apiValue: $0.severity)
                    let right = Severity(apiValue: $1.severity)
                    if left != right { return left < right }
                    return $0.firedAt > $1.firedAt
                }
            case .unprocessableContent:
                throw APIStatusError(status: 422)
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

private struct AlertRow: View {
    let event: Components.Schemas.AlertEventResponse
    var isResolving = false

    private var severity: Severity { Severity(apiValue: event.severity) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: severity.symbol).foregroundStyle(severity.tint)
                Text(event.subjectDisplay.isEmpty ? event.subjectType : event.subjectDisplay)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isResolving {
                    ProgressView()
                } else if event.resolvedAt != nil {
                    Badge(localised: "resolved", tint: .green)
                }
            }
            Text(event.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Text(event.firedAt.formatted(.relative(presentation: .named)))
                if !event.subjectType.isEmpty { Text(event.subjectType) }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        // The row is one thought; without this VoiceOver reads four fragments
        // and the severity — the part that decides whether to keep listening —
        // arrives as an unlabelled image.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(severity.label). \(event.subjectDisplay). \(event.message). "
                + event.firedAt.formatted(.relative(presentation: .named))
        )
    }
}
