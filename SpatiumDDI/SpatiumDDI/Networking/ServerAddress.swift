//
//  ServerAddress.swift
//  SpatiumDDI
//

import Foundation

/// A SpatiumDDI control plane the operator has pointed the app at.
///
/// Deployments are rarely a tidy public hostname. This models what the field
/// actually looks like: private names, non-standard ports, bare IP literals
/// (v4 and v6), and HTTP-only lab installs an operator knowingly chooses.
nonisolated struct ServerAddress: Equatable, Hashable, Sendable, Codable {
    enum Scheme: String, Sendable, Codable {
        case https, http
        var defaultPort: Int { self == .https ? 443 : 80 }
    }

    let scheme: Scheme
    let host: String
    /// `nil` means "the scheme's default port".
    let port: Int?

    /// An HTTP install ships credentials in the clear. Legal, but the operator
    /// has to be told plainly rather than have it slip past them.
    var isInsecureTransport: Bool { scheme == .http }

    /// IPv6 literals must be bracketed inside a URL's authority component.
    private var hostForURL: String {
        host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
    }

    var origin: URL {
        var string = "\(scheme.rawValue)://\(hostForURL)"
        if let port, port != scheme.defaultPort { string += ":\(port)" }
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
    var pinKey: String { "\(scheme.rawValue)://\(hostForURL):\(port ?? scheme.defaultPort)" }

    /// Human-facing form, echoed back so the operator can confirm what was parsed.
    var displayName: String {
        var name = hostForURL
        if let port, port != scheme.defaultPort { name += ":\(port)" }
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
                "\(scheme):// isn't supported. Use https:// or http://."
            case .missingHost:
                "That address doesn't contain a host name."
            case .invalidPort(let port):
                "Port \(port) is out of range. Use 1–65535."
            }
        }
    }

    /// Parses whatever the operator typed. A bare host is assumed to be HTTPS —
    /// downgrading to HTTP is never inferred, only accepted when spelled out.
    static func parse(_ raw: String) throws(ParseError) -> ServerAddress {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }

        let qualified = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: qualified) else { throw .missingHost }

        let rawScheme = (components.scheme ?? "").lowercased()
        guard let scheme = Scheme(rawValue: rawScheme) else { throw .unsupportedScheme(rawScheme) }

        // `host` strips the brackets from an IPv6 literal; keep the bare form
        // and re-bracket on the way out so round-tripping stays stable.
        guard let host = components.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              !host.isEmpty else { throw .missingHost }

        if let port = components.port, !(1...65535).contains(port) { throw .invalidPort(port) }

        // A pasted deep link ("https://host/ui/dashboard") carries a path we
        // don't want; the origin is the only part that identifies the server.
        return ServerAddress(scheme: scheme, host: host, port: components.port)
    }
}
