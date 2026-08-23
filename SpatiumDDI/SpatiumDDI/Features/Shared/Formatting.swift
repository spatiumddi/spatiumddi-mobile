//
//  Formatting.swift
//  SpatiumDDI
//

import Foundation

extension Duration {
    /// A TTL or lease time the way a DNS/DHCP operator writes it: `5m`, `1h`, `1d`.
    ///
    /// `Duration.formatted` renders `3600 s` or `1:00:00`, neither of which is
    /// how a zone file or a Kea config spells a lease. Falling back to plain
    /// seconds for anything that is not a whole unit keeps the value exact —
    /// rounding a 90-second TTL to "2m" would misreport the record.
    nonisolated var formattedCompact: String {
        let total = components.seconds
        guard total > 0 else { return "\(total)s" }
        switch total {
        case let s where s % 86_400 == 0: return "\(s / 86_400)d"
        case let s where s % 3_600 == 0: return "\(s / 3_600)h"
        case let s where s % 60 == 0: return "\(s / 60)m"
        default: return "\(total)s"
        }
    }
}

extension Date {
    /// "3 minutes ago", or "never" for an absent timestamp.
    static func relativeOrNever(_ date: Date?) -> String {
        // "Never" is this app's word, not the server's, so it is resolved
        // through the catalogue — otherwise a translated build reads
        // "3 minutos atrás" beside an English "Never".
        guard let date else { return String(localized: "Never") }
        return date.formatted(.relative(presentation: .named))
    }
}

extension Int {
    /// Whether the control plane clamped a count it could not express.
    ///
    /// An IPv6 /64 holds 2^64 addresses, which does not fit in the signed 64-bit
    /// integer the API returns, so the server sends `Int64.max` instead.
    /// Rendering that as a literal address count states a number that is not the
    /// real one — and doing arithmetic on it overflows, which traps.
    var isClampedCount: Bool { self == Int.max }

    /// An address count, or "very large" where the real figure was clamped.
    var formattedAddressCount: String {
        isClampedCount ? String(localized: "very large") : formatted()
    }
}
