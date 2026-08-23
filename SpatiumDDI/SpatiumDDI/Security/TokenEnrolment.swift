//
//  TokenEnrolment.swift
//  SpatiumDDI
//

import Foundation

/// Validating a token against a control plane and sealing it in the Keychain.
///
/// Extracted because this now happens from two places: the sign-in screen,
/// where a token was typed or pasted, and the connect screen, where a scanned
/// enrolment code already carried one. Both paths must apply the same checks —
/// especially the biometric one, which is the difference between a token that
/// is protected and a token that is merely stored.
nonisolated struct TokenEnrolment {
    enum Outcome: Equatable {
        /// Accepted by the server and sealed in the Keychain, behind this.
        ///
        /// Carries the protection rather than a bare success so the caller can
        /// say which gate is actually holding the token — an operator on a
        /// passcode-only device should not be left to assume Face ID is
        /// involved when it is not.
        case enrolled(KeychainProtection)
        /// Refused, with something the operator can act on.
        case failed(FailureMessage)
    }

    var probe: ControlPlaneProbe = ControlPlaneProbe()
    var tokens: TokenStore = TokenStore()

    /// What would guard a token sealed right now, or why nothing could.
    ///
    /// Answerable without writing anything, which is what lets the sign-in
    /// screen warn about a passcode-only device *before* the token is stored
    /// rather than reporting it afterwards.
    var availableProtection: Result<KeychainProtection, TokenStore.StoreError> {
        TokenStore.availableProtection()
    }

    /// Why this device cannot protect a token at all, if it cannot.
    var unprotectedReason: String? {
        if case .failure(let error) = availableProtection {
            return error.localizedDescription
        }
        return nil
    }

    func enrol(_ rawToken: String, for address: ServerAddress) async -> Outcome {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failed(.app("No token to sign in with.")) }

        // Refuse before writing anything that could not be protected at all.
        // Checked here as well as in the store because the message an operator
        // needs is "set a passcode", not a Keychain error code.
        // Foundation already localised this LAError text, so it goes through
        // verbatim rather than being re-keyed against this app's catalogue.
        if let reason = unprotectedReason { return .failed(.server(reason)) }

        switch await probe.validateToken(token, for: address) {
        case .authenticated, .forbidden:
            // `.forbidden` means the credential is good but this account cannot
            // read its own permissions — an authorisation problem to surface
            // later, not a reason to reject a working token here.
            do {
                return .enrolled(try tokens.save(token, for: address))
            } catch {
                return .failed(.server(error.localizedDescription))
            }

        case .rejected:
            return .failed(
                .app("The server rejected that token. Check it hasn't been revoked or expired.")
            )

        case .maintenance:
            return .failed(
                .app("\(address.displayName) is in a change window. Try again once it's finished.")
            )

        case .trustRequired:
            return .failed(
                .app("The server's certificate changed since you connected. Reconnect to review it.")
            )

        case .failed(let error):
            return .failed(.server(error.localizedDescription))
        }
    }
}
