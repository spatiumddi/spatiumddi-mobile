//
//  LoadState.swift
//  SpatiumDDI
//

import SwiftUI

/// Where a fetch has got to.
///
/// Failure is a first-class state rather than an empty list. Non-negotiable #4:
/// a 403 must be shown honestly, never swallowed into a blank screen — and a
/// blank list is exactly what "swallowed" looks like to an operator.
enum LoadState<Value> {
    case idle
    case loading
    case loaded(Value)
    case failed(String)
}

/// Renders the four states of a fetch consistently.
struct LoadStateView<Value, Content: View>: View {
    let state: LoadState<Value>
    let emptyMessage: String
    let retry: () -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, alignment: .center).listRowSeparator(.hidden)

        case .loaded(let value):
            if let collection = value as? any Collection, collection.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "tray", description: Text(emptyMessage))
                    .listRowSeparator(.hidden)
            } else {
                content(value)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Button("Try Again", action: retry)
            }
            .listRowSeparator(.hidden)
        }
    }
}

/// A utilisation bar sized to the value it reports.
struct UtilisationBar: View {
    let percent: Double

    private var tint: Color {
        switch percent {
        case ..<70: .green
        case ..<90: .orange
        default: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ProgressView(value: min(max(percent, 0), 100), total: 100)
                .tint(tint)
            Text("\(percent, format: .number.precision(.fractionLength(1)))% used")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
