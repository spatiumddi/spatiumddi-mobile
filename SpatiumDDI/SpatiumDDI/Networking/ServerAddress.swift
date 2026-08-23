//
//  ServerAddress.swift
//  SpatiumDDI
//

import Foundation

/// A SpatiumDDI control plane the operator has pointed the app at.
///
/// Deployments are rarely a tidy public hostname. This models what the field
/// actually looks like: private names, non-standard ports, and bare IP literals
/// (v4 and v6).
///
/// HTTPS only. A bearer token in cleartext is a credential handed to anyone on
/// the path, and an operator cannot tell from the app that it happened. Labs
/// that only speak HTTP are reached by terminating TLS in front of them — see
/// `scripts/dev-control-plane.sh proxy`.
nonisolated struct ServerAddress: Equatable, Hashable, Sendable, Codable {
    static let defaultPort = 443

    let host: String
    /// `nil` means 443.
    let port: Int?

    /// IPv6 literals must be bracketed inside a URL's authority component.
    private var hostForURL: String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    var origin: URL {
        var string = "https://\(hostForURL)"
        if let port, port != Self.defaultPort { string += ":\(port)" }
        // Every component is validated at parse time, so this cannot fail.
        return URL(string: string)!
    }

    /// Versioned REST surface. See CLAUDE.md — base URL is `https://<host>/api/v1`.
    var apiBaseURL: URL { origin.appending(path: "api/v1") }

    /// Component health, `demo_mode` and `maintenance_mode`. Root path, not
    /// under `/api/v1`, and unauthenticated.
    var healthURL: URL { origin.appending(path: "health/platform") }

    /// Identity a pinned certificate is remembered against. Port matters: two
    /// services on one host are not the same peer.
    var pinKey: String { "https://\(hostForURL):\(port ?? Self.defaultPort)" }

    /// Human-facing form, echoed back so the operator can confirm what was parsed.
    var displayName: String {
        var name = hostForURL
        if let port, port != Self.defaultPort { name += ":\(port)" }
        return name
    }
}

nonisolated extension ServerAddress {
    enum ParseError: Error, Equatable, LocalizedError {
        case empty
        case unsupportedScheme(String)
        case missingHost
        case invalidPort(Int)

        var errorDescription: String? {
            switch self {
            case .empty:
                "Enter the address of your SpatiumDDI server."
            case .unsupportedScheme(let scheme):
                "\(scheme):// isn't supported. SpatiumDDI connections must use https://."
            case .missingHost:
                "That address doesn't contain a host name."
            case .invalidPort(let port):
                "Port \(port) is out of range. Use 1–65535."
            }
        }
    }

    /// Parses whatever the operator typed. HTTPS is assumed, and anything else
    /// is refused rather than quietly downgraded.
    static func parse(_ raw: String) throws(ParseError) -> ServerAddress {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }

        let qualified = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: qualified) else { throw .missingHost }

        let scheme = (components.scheme ?? "").lowercased()
        guard scheme == "https" else { throw .unsupportedScheme(scheme) }

        // `host` strips the brackets from an IPv6 literal; keep the bare form
        // and re-bracket on the way out so round-tripping stays stable.
        guard
            let host = components.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
            !host.isEmpty
        else { throw .missingHost }

        if let port = components.port, !(1...65535).contains(port) { throw .invalidPort(port) }

        // A pasted deep link ("https://host/ui/dashboard") carries a path we
        // don't want; the origin is the only part that identifies the server.
        return ServerAddress(host: host, port: components.port)
    }
}
