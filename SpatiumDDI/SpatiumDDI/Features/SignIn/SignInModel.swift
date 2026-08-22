//
//  SignInModel.swift
//  SpatiumDDI
//

import Foundation
import Observation

/// Takes an API token, checks the server accepts it, and stores it behind biometry.
///
/// Minting a per-device token at "sign in on this device" needs `/auth/login`,
/// which needs the generated client. Until then the operator supplies a token
/// they created in the web UI. Everything after that point — validation,
/// storage, the biometric gate — is the real path, not a placeholder.
@Observable
final class SignInModel {
    enum State: Equatable {
        case idle
        case validating
        case storing
        case failed(String)
    }

    var tokenInput: String = ""
    private(set) var state: State = .idle
    /// Presented after a scan, so the operator sees what the code contained.
    var scanNotice: String?
    var isScanning = false

    let address: ServerAddress
    private let probe: ControlPlaneProbe
    private let tokens: TokenStore
    private let trust: TrustStore
    private let onSignedIn: (String) -> Void

    init(
        address: ServerAddress,
        probe: ControlPlaneProbe = ControlPlaneProbe(),
        tokens: TokenStore = TokenStore(),
        trust: TrustStore = TrustStore(),
        onSignedIn: @escaping (String) -> Void
    ) {
        self.address = address
        self.probe = probe
        self.tokens = tokens
        self.trust = trust
        self.onSignedIn = onSignedIn
    }

    /// Takes what a QR code claimed, and acts on none of it without saying so.
    ///
    /// A code is whatever was printed on the thing the camera pointed at. It can
    /// fill in a token; it cannot silently move the app to another server, and a
    /// certificate fingerprint that disagrees with the one already pinned is
    /// reported rather than quietly reconciled.
    func apply(_ payload: EnrolmentPayload) {
        isScanning = false

        if let scanned = payload.address, scanned != address {
            state = .failed(
                "That code is for \(scanned.displayName), not \(address.displayName). "
                    + "Go back and change server if you meant to connect there."
            )
            return
        }

        if let scanned = payload.certificateFingerprint,
            let pinned = trust.pinnedFingerprint(for: address),
            scanned != pinned
        {
            state = .failed(
                "That code carries a different certificate fingerprint than the one you approved "
                    + "for \(address.displayName). Do not continue until you know why."
            )
            return
        }

        guard let token = payload.token else {
            state = .failed("That code didn't contain a token.")
            return
        }

        tokenInput = token
        state = .idle
        scanNotice = "Token filled in from the scanned code. Review it, then sign in."
    }

    var isBusy: Bool { state == .validating || state == .storing }

    /// The server takes either an `sddi_` API token or a JWT. Anything else is
    /// almost certainly a paste mistake, and saying so beats a 401 round trip.
    var looksLikeAToken: Bool {
        let trimmed = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("sddi_") || trimmed.split(separator: ".").count == 3
    }

    var biometryDescription: String { TokenStore.biometryDescription() }

    var biometryUnavailableReason: String? {
        if case .failure(let error) = TokenStore.biometryAvailability() {
            return error.localizedDescription
        }
        return nil
    }

    func signIn() async {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }

        // Refuse before writing anything we couldn't protect properly.
        if let reason = biometryUnavailableReason {
            state = .failed(reason)
            return
        }

        state = .validating
        switch await probe.validateToken(token, for: address) {
        case .authenticated, .forbidden:
            // .forbidden means the credential is good but this account can't read
            // its own permissions — an authorisation problem to surface later,
            // not a reason to reject a working token here.
            await store(token)

        case .rejected:
            state = .failed("The server rejected that token. Check it hasn't been revoked or expired.")

        case .maintenance:
            state = .failed("\(address.displayName) is in a change window. Try again once it's finished.")

        case .trustRequired:
            state = .failed("The server's certificate changed since you connected. Reconnect to review it.")

        case .failed(let error):
            state = .failed(error.localizedDescription)
        }
    }

    private func store(_ token: String) async {
        state = .storing
        do {
            try tokens.save(token, for: address)
            tokenInput = ""
            state = .idle
            onSignedIn(token)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
