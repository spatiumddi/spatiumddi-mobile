//
//  Expiry.swift
//  SpatiumDDI
//

import Foundation
import SwiftUI

/// How close a deadline is, in the terms an operator reacts to.
///
/// Domains and TLS certificates both page someone at an awkward hour for the
/// same reason, and both deserve the same vocabulary — an amber that means
/// "book time this week" and a red that means "today". The thresholds are the
/// conventional ones: 30 days is a renewal window, 7 is a scramble.
nonisolated enum Expiry: Sendable {
    case expired
    case critical(days: Int)
    case soon(days: Int)
    case fine(days: Int)
    case unknown

    init(_ date: Date?, now: Date = .now) {
        guard let date else {
            self = .unknown
            return
        }
        let days = Calendar.current.dateComponents([.day], from: now, to: date).day ?? 0
        switch days {
        case ..<0: self = .expired
        case 0..<8: self = .critical(days: days)
        case 8..<31: self = .soon(days: days)
        default: self = .fine(days: days)
        }
    }

    var tint: Color {
        switch self {
        case .expired, .critical: .red
        case .soon: .orange
        case .fine: .green
        case .unknown: .secondary
        }
    }

    var label: String {
        switch self {
        case .expired: "Expired"
        case .critical(let days): days == 0 ? "Expires today" : "\(days)d left"
        case .soon(let days): "\(days)d left"
        case .fine(let days): "\(days)d left"
        case .unknown: "No expiry recorded"
        }
    }

    /// Whether this deserves to be surfaced rather than merely listed.
    var isPressing: Bool {
        switch self {
        case .expired, .critical, .soon: true
        case .fine, .unknown: false
        }
    }
}

/// A deadline, coloured by how close it is.
struct ExpiryBadge: View {
    let date: Date?

    var body: some View {
        let expiry = Expiry(date)
        Badge(text: expiry.label, tint: expiry.tint)
            .accessibilityLabel(
                date.map { "\(expiry.label), \($0.formatted(date: .abbreviated, time: .omitted))" }
                    ?? expiry.label
            )
    }
}
