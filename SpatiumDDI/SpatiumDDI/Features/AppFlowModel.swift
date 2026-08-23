//
//  AppFlowModel.swift
//  SpatiumDDI
//

import Foundation
import Observation

/// The app's top-level state: which server, and how far through the door we are.
@Observable
final class AppFlowModel {
    enum Stage: Equatable {
        case chooseServer
        case signIn(ServerAddress)
        /// A token exists for this server and needs unsealing.
        case locked(ServerAddress, message: String?)
        case signedIn(ServerAddress)
    }

    private(set) var stage: Stage = .chooseServer

    /// Held for the lifetime of the foreground session only. Never written
    /// anywhere but the Keychain, never logged — see `Redaction`.
    private(set) var token: String?

    private let tokens: TokenStore
    private let defaults: UserDefaults
    private static let lastServerKey = "lastServerAddress"

    init(tokens: TokenStore = TokenStore(), defaults: UserDefaults = .standard) {
        self.tokens = tokens
        self.defaults = defaults
        restore()
    }

    /// The chosen server is configuration, not response data — non-negotiable #3
    /// governs what the *control plane returns*, and this is the operator's own
    /// setting. It is not a credential, so it does not belong in the Keychain.
    private func restore() {
        guard
            let data = defaults.data(forKey: Self.lastServerKey),
            let address = try? JSONDecoder().decode(ServerAddress.self, from: data)
        else { return }

        stage = tokens.hasToken(for: address) ? .locked(address, message: nil) : .chooseServer
    }

    private func remember(_ address: ServerAddress) {
        guard let data = try? JSONEncoder().encode(address) else { return }
        defaults.set(data, forKey: Self.lastServerKey)
    }

    var biometryDescription: String { TokenStore.biometryDescription() }

    /// A token an enrolment code supplied alongside the server address.
    ///
    /// Held only until sign-in reads it. It is not a stored credential — it has
    /// not been validated or accepted yet, and it never reaches the Keychain
    /// until the operator signs in with it.
    private(set) var pendingToken: String?

    func connected(to address: ServerAddress, pendingToken: String? = nil) {
        remember(address)
        self.pendingToken = pendingToken
        stage = tokens.hasToken(for: address) ? .locked(address, message: nil) : .signIn(address)
    }

    func signedIn(with token: String, to address: ServerAddress) {
        self.token = token
        pendingToken = nil
        stage = .signedIn(address)
    }

    func unlock() async {
        guard case .locked(let address, _) = stage else { return }
        do {
            let stored = try await tokens.token(
                for: address,
                reason: "Unlock your SpatiumDDI token for \(address.displayName)"
            )
            token = stored
            stage = .signedIn(address)
        } catch TokenStore.StoreError.cancelled {
            stage = .locked(address, message: nil)
        } catch TokenStore.StoreError.notFound, TokenStore.StoreError.enrollmentChanged {
            // The item is gone or was invalidated; signing in again is the fix.
            try? tokens.delete(for: address)
            stage = .signIn(address)
        } catch {
            stage = .locked(address, message: error.localizedDescription)
        }
    }

    /// Drops the in-memory token so returning to the app requires biometry again.
    ///
    /// This app changes production DNS and DHCP from a phone that gets left on
    /// desks. Re-unlocking costs one glance.
    func lockForBackground() {
        guard case .signedIn(let address) = stage else { return }
        token = nil
        stage = .locked(address, message: nil)
    }

    /// The server rejected the stored credential.
    ///
    /// Discards it rather than keeping it: a token the server has revoked will
    /// fail identically on every future unlock, and leaving it in place means
    /// the operator authenticates their way into a dead session forever.
    func sessionRejected() {
        guard case .signedIn(let address) = stage else { return }
        token = nil
        try? tokens.delete(for: address)
        stage = .signIn(address)
    }

    func signOut() {
        let address = currentAddress
        token = nil
        pendingToken = nil
        if let address { try? tokens.delete(for: address) }
        stage = address.map { .signIn($0) } ?? .chooseServer
    }

    func changeServer() {
        token = nil
        pendingToken = nil
        stage = .chooseServer
    }

    var currentAddress: ServerAddress? {
        switch stage {
        case .chooseServer: nil
        case .signIn(let address), .locked(let address, _), .signedIn(let address): address
        }
    }
}
