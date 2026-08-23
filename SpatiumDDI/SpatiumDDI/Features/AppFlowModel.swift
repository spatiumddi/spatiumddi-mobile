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
        /// The list of configured control planes.
        case servers
        /// The connect form — pointing the app at a server it doesn't know yet.
        case addServer
        case signIn(StoredServer)
        /// A token exists for this server and needs unsealing.
        case locked(StoredServer, message: String?)
        case signedIn(StoredServer)
    }

    private(set) var stage: Stage = .addServer

    /// Every configured control plane.
    private(set) var servers: [StoredServer] = []

    /// Held for the lifetime of the foreground session only. Never written
    /// anywhere but the Keychain, never logged — see `Redaction`.
    private(set) var token: String?

    private let tokens: TokenStore
    private let trust: TrustStore
    private let registry: ServerRegistry

    init(
        tokens: TokenStore = TokenStore(),
        trust: TrustStore = TrustStore(),
        registry: ServerRegistry = ServerRegistry()
    ) {
        self.tokens = tokens
        self.trust = trust
        self.registry = registry
        restore()
    }

    /// The chosen servers are configuration, not response data — non-negotiable
    /// #3 governs what the *control plane returns*, and these are the operator's
    /// own settings. They are not credentials, so they don't belong in the
    /// Keychain; the tokens and pins they are keyed to already do.
    private func restore() {
        servers = registry.servers()

        guard !servers.isEmpty else {
            stage = .addServer
            return
        }

        // Straight back to where they were, when there is something to unlock.
        // The list is the entry point instead of the *connect form* — not
        // instead of the fast path, which is the whole point of holding a
        // per-device token.
        if let current = servers.first(where: { $0.id == registry.currentID() }),
            tokens.hasToken(for: current.address)
        {
            stage = .locked(current, message: nil)
        } else {
            stage = .servers
        }
    }

    /// Adds or updates a server, and makes it current.
    private func remember(_ server: StoredServer) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            // A re-connect keeps the name it already had unless a new one was
            // typed — retyping a host shouldn't silently erase "Prod EU".
            servers[index].label = server.trimmedLabel ?? servers[index].label
        } else {
            servers.append(server)
        }
        registry.save(servers)
        registry.setCurrentID(server.id)
    }

    // MARK: - Which gate is holding the token

    /// What is guarding the current server's stored token, if there is one.
    var currentProtection: KeychainProtection? {
        currentServer.flatMap { tokens.storedProtection(for: $0.address) }
    }

    func protection(for server: StoredServer) -> KeychainProtection? {
        tokens.storedProtection(for: server.address)
    }

    func hasToken(for server: StoredServer) -> Bool { tokens.hasToken(for: server.address) }

    // MARK: - Enrolment

    /// A token an enrolment code supplied alongside the server address.
    ///
    /// Held only until sign-in reads it. It is not a stored credential — it has
    /// not been validated or accepted yet, and it never reaches the Keychain
    /// until the operator signs in with it.
    private(set) var pendingToken: String?

    /// A scanned enrolment code carried a token that has already been
    /// validated against the server and sealed in the Keychain.
    ///
    /// Straight to signed-in. The operator picked which code to scan and
    /// pressed the button; making them confirm an opaque `sddi_…` string
    /// afterwards is ceremony, not consent.
    func enrolled(with token: String, to server: StoredServer) {
        remember(server)
        self.token = token
        pendingToken = nil
        stage = .signedIn(server)
    }

    func connected(to server: StoredServer, pendingToken: String? = nil) {
        remember(server)
        // Reaching a server is always the start of a new session, so a token
        // still in memory belongs to whatever came before — possibly a
        // different control plane. Clearing here rather than relying on the
        // caller having done it: this is the only path that changes which
        // estate is loaded without going through the list.
        token = nil
        self.pendingToken = pendingToken
        let resolved = servers.first(where: { $0.id == server.id }) ?? server
        stage =
            tokens.hasToken(for: resolved.address)
            ? .locked(resolved, message: nil) : .signIn(resolved)
    }

    func signedIn(with token: String, to server: StoredServer) {
        self.token = token
        pendingToken = nil
        stage = .signedIn(server)
    }

    func unlock() async {
        guard case .locked(let server, _) = stage else { return }
        do {
            let stored = try await tokens.token(
                for: server.address,
                reason: "Unlock your SpatiumDDI token for \(server.displayName)"
            )
            token = stored
            stage = .signedIn(server)
        } catch TokenStore.StoreError.cancelled {
            stage = .locked(server, message: nil)
        } catch TokenStore.StoreError.notFound, TokenStore.StoreError.enrollmentChanged {
            // **Never delete here.** `errSecItemNotFound` does not only mean
            // "the item is gone": the Keychain says exactly the same thing when
            // an item is present but its access control cannot be satisfied by
            // the context presented — a biometric item asked for with a
            // passcode-authenticated context, say. Deleting on that signal
            // destroys a working credential over a failed *read*, and there is
            // no way back from it but pasting the token in again.
            //
            // Nothing needs deleting for recovery either way: `save` clears any
            // existing item before adding, because access control cannot be
            // changed by an update. So the only thing that delete ever achieved
            // here was the data loss.
            if tokens.hasToken(for: server.address) {
                // Still there, so this was the read failing rather than the
                // token being absent. Say so, and leave the way out to the
                // operator — Sign Out is on this screen.
                stage = .locked(
                    server,
                    message: String(
                        localized:
                            "The stored token could not be unsealed. It is still on this device — try again, or sign out to replace it."
                    )
                )
            } else {
                stage = .signIn(server)
            }
        } catch {
            stage = .locked(server, message: error.localizedDescription)
        }
    }

    /// Drops the in-memory token so returning to the app requires unlocking again.
    ///
    /// This app changes production DNS and DHCP from a phone that gets left on
    /// desks. Re-unlocking costs one glance.
    func lockForBackground() {
        guard case .signedIn(let server) = stage else { return }
        token = nil
        stage = .locked(server, message: nil)
    }

    /// The server rejected the stored credential.
    ///
    /// Discards it rather than keeping it: a token the server has revoked will
    /// fail identically on every future unlock, and leaving it in place means
    /// the operator authenticates their way into a dead session forever.
    func sessionRejected() {
        guard case .signedIn(let server) = stage else { return }
        token = nil
        try? tokens.delete(for: server.address)
        stage = .signIn(server)
    }

    func signOut() {
        let server = currentServer
        token = nil
        pendingToken = nil
        if let server { try? tokens.delete(for: server.address) }
        // The server stays configured — its address, name and approved
        // certificate are not the credential, and making the operator re-enter
        // all three to sign back in would be a punishment, not a safeguard.
        stage = server.map { .signIn($0) } ?? .servers
    }

    // MARK: - Several control planes

    /// Show the list. Every session-scoped state goes with the torn-down view.
    func showServers() {
        token = nil
        pendingToken = nil
        stage = .servers
    }

    func showAddServer() {
        token = nil
        pendingToken = nil
        stage = .addServer
    }

    /// Move to another control plane.
    ///
    /// Drops the in-memory token first, so nothing authenticated against the
    /// server being left can outlive the switch. `SignedInView` owns the
    /// `ControlPlaneSession` and every screen's fetched rows, and it is torn
    /// down by this stage change — which is what keeps non-negotiable #3's
    /// "nothing an inactive server returned may linger" true by construction
    /// rather than by remembering to clear things.
    func select(_ server: StoredServer) {
        token = nil
        pendingToken = nil
        registry.setCurrentID(server.id)
        stage = tokens.hasToken(for: server.address) ? .locked(server, message: nil) : .signIn(server)
    }

    /// Forget a server entirely: its token, its certificate pin, its name.
    ///
    /// Matches what Sign Out does to the token, and goes further — an operator
    /// removing a server means it, and leaving an approved certificate behind
    /// for a host they have finished with is a pin nobody is watching.
    func remove(_ server: StoredServer) {
        try? tokens.delete(for: server.address)
        try? trust.removePin(for: server.address)
        servers.removeAll { $0.id == server.id }
        registry.save(servers)

        if registry.currentID() == server.id { registry.setCurrentID(nil) }
        if currentServer?.id == server.id {
            token = nil
            pendingToken = nil
        }
        if servers.isEmpty {
            stage = .addServer
        } else if isCurrent(server) {
            stage = .servers
        }
    }

    func rename(_ server: StoredServer, to label: String?) {
        guard let index = servers.firstIndex(where: { $0.id == server.id }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        servers[index].label = (trimmed?.isEmpty ?? true) ? nil : trimmed
        registry.save(servers)

        // Keep whatever is on screen naming it correctly.
        let renamed = servers[index]
        switch stage {
        case .signIn(let shown) where shown.id == renamed.id:
            stage = .signIn(renamed)
        case .locked(let shown, let message) where shown.id == renamed.id:
            stage = .locked(renamed, message: message)
        case .signedIn(let shown) where shown.id == renamed.id:
            stage = .signedIn(renamed)
        default:
            break
        }
    }

    private func isCurrent(_ server: StoredServer) -> Bool { currentServer?.id == server.id }

    /// Which server the operator was last on, whatever stage they are at now.
    ///
    /// Distinct from `currentServer`, which is derived from the stage and is
    /// therefore `nil` while the list is on screen — exactly when the list needs
    /// to know which row to mark.
    var currentServerID: String? { registry.currentID() }

    var currentServer: StoredServer? {
        switch stage {
        case .servers, .addServer: nil
        case .signIn(let server), .locked(let server, _), .signedIn(let server): server
        }
    }

    var currentAddress: ServerAddress? { currentServer?.address }
}
