//
//  TrustStore.swift
//  SpatiumDDI
//

import Foundation

/// Certificates the operator has explicitly vouched for, keyed by server origin.
///
/// Deliberately stateless — every lookup reads the Keychain. Trust decisions are
/// consulted once per connection, so the cost is irrelevant next to the risk of
/// serving a stale in-memory copy of a pin the operator has since revoked.
nonisolated struct TrustStore: Sendable {
    private let keychain: KeychainStore

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
    }

    private func account(for address: ServerAddress) -> String { "trust-pin.\(address.pinKey)" }

    /// The fingerprint the operator approved for this server, if any.
    ///
    /// A Keychain failure is reported as "no pin". Failing closed re-prompts the
    /// operator, which is the safe direction — the unsafe direction would be
    /// treating an unreadable store as prior approval.
    func pinnedFingerprint(for address: ServerAddress) -> Data? {
        (try? keychain.data(forAccount: account(for: address))) ?? nil
    }

    func pin(_ fingerprint: Data, for address: ServerAddress) throws {
        try keychain.set(fingerprint, forAccount: account(for: address))
    }

    func removePin(for address: ServerAddress) throws {
        try keychain.removeItem(forAccount: account(for: address))
    }
}
