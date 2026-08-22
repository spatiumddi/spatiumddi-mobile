//
//  EnrolmentPayload.swift
//  SpatiumDDI
//

import Foundation

/// What a scanned enrolment QR code turned out to contain.
///
/// Two shapes are accepted. A bare `sddi_` token is what you get if the web UI
/// simply encodes the token it just minted. The `spatiumddi://` URI is the
/// richer form: it can carry the server and its certificate fingerprint too, so
/// one scan configures the whole connection.
///
/// Nothing here is trusted on sight. A QR code is attacker-supplied input — a
/// sticker on a rack door is not an authorisation — so a payload only ever
/// pre-fills the connection for the operator to confirm.
nonisolated struct EnrolmentPayload: Equatable, Sendable {
    var address: ServerAddress?
    var token: String?
    /// SHA-256 of the leaf certificate, as raw bytes.
    var certificateFingerprint: Data?

    static let scheme = "spatiumddi"
    static let host = "enrol"

    enum ParseError: Error, Equatable, LocalizedError {
        case unrecognised
        case badServer(String)
        case badFingerprint

        var errorDescription: String? {
            switch self {
            case .unrecognised:
                return "That code isn't a SpatiumDDI enrolment code."
            case .badServer(let detail):
                return "The code names a server the app can't use: \(detail)"
            case .badFingerprint:
                return "The code's certificate fingerprint isn't a valid SHA-256 value."
            }
        }
    }

    /// Interprets a scanned string.
    static func parse(_ raw: String) throws(ParseError) -> EnrolmentPayload {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .unrecognised }

        // A bare API token: the minimal thing a control plane could encode.
        if trimmed.hasPrefix("sddi_"), !trimmed.contains("://") {
            return EnrolmentPayload(address: nil, token: trimmed, certificateFingerprint: nil)
        }

        guard
            let components = URLComponents(string: trimmed),
            components.scheme?.lowercased() == scheme
        else { throw .unrecognised }

        // Tolerate spatiumddi://enrol?… and spatiumddi:?… alike.
        if let uriHost = components.host?.lowercased(), uriHost != host {
            throw .unrecognised
        }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value.flatMap {
                $0.isEmpty ? nil : $0
            }
        }

        var address: ServerAddress?
        if let serverHost = value("host") {
            var spec = serverHost
            if let port = value("port") { spec += ":\(port)" }
            do {
                address = try ServerAddress.parse(spec)
            } catch {
                throw .badServer(error.localizedDescription)
            }
        }

        var fingerprint: Data?
        if let raw = value("fingerprint") ?? value("fp") {
            guard let parsed = fingerprintData(from: raw) else { throw .badFingerprint }
            fingerprint = parsed
        }

        let payload = EnrolmentPayload(
            address: address,
            token: value("token"),
            certificateFingerprint: fingerprint
        )
        // A code that names neither a server nor a token configures nothing.
        guard payload.address != nil || payload.token != nil else { throw .unrecognised }
        return payload
    }

    /// Accepts SHA-256 hex with or without the colons `openssl` prints.
    static func fingerprintData(from raw: String) -> Data? {
        let hex = raw.replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard hex.count == 64 else { return nil }

        var bytes = Data(capacity: 32)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
}
