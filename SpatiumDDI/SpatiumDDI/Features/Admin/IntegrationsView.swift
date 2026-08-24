//
//  IntegrationsView.swift
//  SpatiumDDI
//

import SpatiumAPI
import SwiftUI

/// "Did the UniFi sync break?" — a from-the-couch question.
///
/// Deliberately the tiles and not the forms behind them. Configuring an
/// integration means credentials, endpoints and sync policy, which is a laptop
/// job; noticing that one stopped working at 3am is not, and until now it
/// needed the same laptop.
struct IntegrationsView: View {
    let session: ControlPlaneSession

    @State private var state: LoadState<Components.Schemas.IntegrationsDashboardSummary> = .idle

    var body: some View {
        List {
            switch state {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)

            case .failed(let message):
                VStack(alignment: .leading, spacing: 12) {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Button("Try Again") { Task { await fetch() } }
                }

            case .loaded(let summary):
                let enabled = summary.panels.filter(\.enabled)

                if enabled.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No integrations",
                            systemImage: "puzzlepiece.extension",
                            description: Text(
                                "This control plane has no integrations switched on, so there is nothing syncing to break."
                            )
                        )
                        .listRowSeparator(.hidden)
                    }
                } else {
                    ForEach(enabled, id: \.kind) { panel in
                        Section {
                            HStack(spacing: 10) {
                                IntegrationTile(
                                    value: panel.healthyCount, label: "Healthy", tint: .green)
                                IntegrationTile(
                                    value: panel.warningCount,
                                    label: "Warning",
                                    tint: panel.warningCount > 0 ? .orange : .secondary
                                )
                                IntegrationTile(
                                    value: panel.errorCount,
                                    label: "Error",
                                    tint: panel.errorCount > 0 ? .red : .secondary
                                )
                            }
                            .listRowInsets(.init(top: 8, leading: 12, bottom: 8, trailing: 12))

                            ForEach(panel.targets, id: \.id) { target in
                                IntegrationTargetRow(target: target)
                            }
                        } header: {
                            // The platform's own label for the integration,
                            // shown as sent.
                            Text(verbatim: panel.label)
                        } footer: {
                            if panel.staleCount > 0 {
                                // Stale is the quiet failure: nothing errored,
                                // the sync simply stopped happening, and only
                                // the clock says so.
                                Text(
                                    "^[\(panel.staleCount) target](inflect: true) hasn't synced within its interval."
                                )
                            }
                        }
                    }
                }

                if !summary.recentErrors.isEmpty {
                    Section("Recent errors") {
                        ForEach(summary.recentErrors, id: \.id) { error in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(verbatim: error.integration).font(.subheadline)
                                    Spacer()
                                    Text(error.timestamp.formatted(.relative(presentation: .named)))
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Text(verbatim: error.targetDisplay)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let detail = error.errorDetail, !detail.isEmpty {
                                    // The integration's own error text. Never
                                    // parsed as Markdown: a sync error can
                                    // carry a URL, and rendering it as a
                                    // tappable link inside this app is exactly
                                    // the hazard `FailureMessage` exists for.
                                    Text(verbatim: detail)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.red)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Integrations")
        .refreshable { await fetch() }
        .task { if case .idle = state { await fetch() } }
    }

    private func fetch() async {
        state = .loading
        state = await LoadState.fetching {
            switch try await session.client.integrationsSummaryApiV1DashboardsIntegrationsSummaryGet() {
            case .ok(let ok): return try ok.body.json
            case .undocumented(let statusCode, let payload):
                throw await APIStatusError(status: statusCode, payload: payload)
            }
        }
    }
}

private struct IntegrationTile: View {
    let value: Int
    let label: LocalizedStringResource
    let tint: Color

    var body: some View {
        VStack(spacing: 2) {
            Text(value.formatted())
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

private struct IntegrationTargetRow: View {
    let target: Components.Schemas.IntegrationTargetRow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(verbatim: target.display).lineLimit(1)
                Spacer()
                if target.isStale { Badge(localised: "stale", tint: .orange) }
            }
            Text("synced \(Date.relativeOrNever(target.lastSyncedAt))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if let error = target.lastSyncError, !error.isEmpty {
                Text(verbatim: error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            } else if let warning = target.lastSyncWarning, !warning.isEmpty {
                Text(verbatim: warning)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }
        }
    }
}
