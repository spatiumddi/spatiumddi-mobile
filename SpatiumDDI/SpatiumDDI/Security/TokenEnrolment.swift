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
        /// Accepted by the server and written to the Keychain behind biometry.
        case enrolled
        /// Refused, with something the operator can act on.
        case failed(FailureMessage)
    }

    var probe: ControlPlaneProbe = ControlPlaneProbe()
    var tokens: TokenStore = TokenStore()

    /// Why biometry cannot protect a token on this device, if it cannot.
    var biometryUnavailableReason: String? {
        if case .failure(let error) = TokenStore.biometryAvailability() {
            return error.localizedDescription
        }
        return nil
    }

    func enrol(_ rawToken: String, for address: ServerAddress) async -> Outcome {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return .failed(.app("No token to sign in with.")) }

        // Refuse before writing anything that could not be protected properly.
        // Checked here as well as in the store because the message an operator
        // needs is "set up Face ID", not a Keychain error code.
        // Foundation already localised this LAError text, so it goes through
        // verbatim rather than being re-keyed against this app's catalogue.
        if let reason = biometryUnavailableReason { return .failed(.server(reason)) }

        switch await probe.validateToken(token, for: address) {
        case .authenticated, .forbidden:
            // `.forbidden` means the credential is good but this account cannot
            // read its own permissions — an authorisation problem to surface
            // later, not a reason to reject a working token here.
            do {
                try tokens.save(token, for: address)
                return .enrolled
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
