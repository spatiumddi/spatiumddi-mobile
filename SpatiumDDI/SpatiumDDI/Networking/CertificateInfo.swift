//
//  CertificateInfo.swift
//  SpatiumDDI
//

import CryptoKit
import Foundation
import Security

/// What the operator is shown when asked to vouch for a server certificate.
///
/// The SHA-256 fingerprint is the security-critical field: it's what they
/// compare against the value the control plane reports. Everything else is
/// context to help them notice when they're looking at the wrong box.
nonisolated struct CertificateInfo: Equatable, Hashable, Sendable {
    /// SHA-256 over the leaf certificate's DER encoding. This is what gets pinned.
    let fingerprint: Data
    /// Subject common name, when the certificate carries one.
    let subjectSummary: String?
    /// Number of certificates the server presented, leaf included.
    let chainLength: Int
    /// The host the app asked for, so a mismatch is visible at confirmation time.
    let requestedHost: String

    /// Colon-separated uppercase hex — the form `openssl x509 -fingerprint -sha256`
    /// prints, so it can be compared against the server side character for character.
    var fingerprintHex: String {
        fingerprint.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// The same digits in short runs, for a layout an operator can actually scan.
    var fingerprintGroups: [String] {
        stride(from: 0, to: fingerprint.count, by: 4).map { start in
            fingerprint[start..<min(start + 4, fingerprint.count)]
                .map { String(format: "%02X", $0) }.joined(separator: ":")
        }
    }

    init(fingerprint: Data, subjectSummary: String?, chainLength: Int, requestedHost: String) {
        self.fingerprint = fingerprint
        self.subjectSummary = subjectSummary
        self.chainLength = chainLength
        self.requestedHost = requestedHost
    }

    /// Reads the leaf out of an evaluated trust object.
    /// Returns `nil` only when the server presented no certificate at all.
    init?(trust: SecTrust, requestedHost: String) {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
            let leaf = chain.first
        else { return nil }

        let der = SecCertificateCopyData(leaf) as Data
        self.fingerprint = Data(SHA256.hash(data: der))
        self.subjectSummary = SecCertificateCopySubjectSummary(leaf) as String?
        self.chainLength = chain.count
        self.requestedHost = requestedHost
    }
}
