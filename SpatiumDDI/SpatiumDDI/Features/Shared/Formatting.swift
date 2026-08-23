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
    var formattedCompact: String {
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
        guard let date else { return "Never" }
        return date.formatted(.relative(presentation: .named))
    }
}
