//
//  Redaction.swift
//  SpatiumDDI
//

import Foundation

/// Keeps credentials out of anything that gets written down.
///
/// Non-negotiable #2 says the token never reaches a log line. Relying on every
/// future call site to remember that is how it eventually leaks, so the only
/// description of a request the app can produce is a redacted one.
nonisolated enum Redaction {
    /// Headers whose values are never printed, whatever their casing.
    static let sensitiveHeaders: Set<String> = [
        "authorization", "cookie", "set-cookie", "proxy-authorization",
    ]

    /// Renders a secret as its shape, not its content.
    ///
    /// A `sddi_` prefix is kept because it identifies the credential *type*,
    /// which is useful when diagnosing "wrong kind of token" — the entropy
    /// after it is not.
    static func redact(_ secret: String) -> String {
        guard !secret.isEmpty else { return "<empty>" }
        if secret.hasPrefix("sddi_") {
            return "sddi_<redacted:\(secret.count - 5)>"
        }
        return "<redacted:\(secret.count)>"
    }

    static func redactHeaderValue(_ value: String, forName name: String) -> String {
        sensitiveHeaders.contains(name.lowercased()) ? "<redacted>" : value
    }

    /// The only sanctioned way to describe a request in a log.
    static func describe(_ request: URLRequest) -> String {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "<no url>"
        let headers = (request.allHTTPHeaderFields ?? [:])
            .sorted { $0.key.lowercased() < $1.key.lowercased() }
            .map { "\($0.key): \(redactHeaderValue($0.value, forName: $0.key))" }
            .joined(separator: ", ")
        return headers.isEmpty ? "\(method) \(url)" : "\(method) \(url) [\(headers)]"
    }
}
