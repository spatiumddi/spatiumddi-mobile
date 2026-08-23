//
//  AlertsView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// The alert list.
///
/// Read-only. Acknowledging and resolving are #884 Phase 2, and this is Phase 1
/// — the list exists so an operator can tell whether something needs them, not
/// so they can clear it from the notification shade.
struct AlertsView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<[Components.Schemas.AlertEventResponse]> = .idle
    @State private var openOnly = true
    @State private var severityFilter: Severity?

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
                        ForEach(events, id: \.id) { AlertRow(event: $0) }
                    }
                }
            }
        }
        .navigationTitle("Alerts")
        .refreshable { await fetch() }
        .task(id: openOnly) { await fetch() }
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

    private var severity: Severity { Severity(apiValue: event.severity) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: severity.symbol).foregroundStyle(severity.tint)
                Text(event.subjectDisplay.isEmpty ? event.subjectType : event.subjectDisplay)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if event.resolvedAt != nil {
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
