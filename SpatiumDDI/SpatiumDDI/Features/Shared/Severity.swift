//
//  Severity.swift
//  SpatiumDDI
//

import SwiftUI

/// Alert severity, as the control plane names it.
///
/// The server sends a bare string. Mapping it here rather than at each call site
/// keeps one answer to "what colour is a warning", and — more importantly —
/// keeps an unrecognised severity visible instead of defaulting it to something
/// calm. A severity this app has never heard of is not automatically minor.
nonisolated enum Severity: String, CaseIterable, Comparable, Sendable {
    case critical
    case warning
    case info

    init(apiValue: String) {
        self = Severity(rawValue: apiValue.lowercased()) ?? .warning
    }

    var label: String {
        switch self {
        case .critical: "Critical"
        case .warning: "Warning"
        case .info: "Info"
        }
    }

    var tint: Color {
        switch self {
        case .critical: .red
        case .warning: .orange
        case .info: .blue
        }
    }

    var symbol: String {
        switch self {
        case .critical: "exclamationmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    /// Most severe sorts first.
    private var order: Int {
        switch self {
        case .critical: 0
        case .warning: 1
        case .info: 2
        }
    }

    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.order < rhs.order }
}

/// A small filled capsule carrying a severity or status word.
struct Badge: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// A coloured dot for a health/status word, with the word beside it.
struct StatusLabel: View {
    let status: String

    /// Mapped from the vocabularies the control plane actually uses across DNS
    /// servers, DHCP servers and platform components. Anything unrecognised is
    /// deliberately grey rather than green — an unknown state is not a good one.
    private var tint: Color {
        switch status.lowercased() {
        case "ok", "active", "healthy", "running", "up", "ready", "approved":
            .green
        case "degraded", "warning", "pending", "syncing", "paused", "maintenance":
            .orange
        case "error", "failed", "unreachable", "down", "critical", "rejected":
            .red
        default:
            .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(status.capitalized).font(.caption)
        }
        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
    }
}
