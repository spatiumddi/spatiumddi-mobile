//
//  TokenStore.swift
//  SpatiumDDI
//

import Foundation
import LocalAuthentication
import Security

/// What the device can put in front of a stored token.
///
/// Non-negotiable #2 says tokens live in the Keychain "gated by biometrics".
/// The requirement underneath that wording is that a token is never left
/// unprotected — and a passcode-gated Keychain item is not unprotected. So this
/// prefers biometry, accepts a passcode, and refuses when there is neither.
///
/// The distinction is kept everywhere rather than collapsed into a Bool because
/// the two are not equivalent and the operator is entitled to know which one is
/// holding their token. See `caveat`.
nonisolated enum KeychainProtection: String, Equatable, Sendable, Codable {
    /// `.biometryCurrentSet` — invalidated the moment enrolment changes.
    case biometrics
    /// `.devicePasscode` — weaker, and survives an enrolment change.
    case passcode

    /// Persisted alongside the item so the protection travels with it.
    ///
    /// A device that gains Face ID after a passcode-only sign-in still holds a
    /// passcode-gated item; only re-signing in upgrades it. Recomputing this
    /// from current device state would therefore report the wrong answer, and
    /// would pick the wrong `LAPolicy` when unsealing.
    var marker: Data { Data(rawValue.utf8) }

    init?(marker: Data) {
        guard let raw = String(data: marker, encoding: .utf8) else { return nil }
        self.init(rawValue: raw)
    }
}

/// The per-device API token, held in the Keychain behind a device-owner gate.
///
/// Non-negotiable #2: never `UserDefaults`, never a plist, never a log line.
/// The item is written with an access control that demands the operator be
/// present, so the token cannot be read back by anything — including this app —
/// without them.
nonisolated struct TokenStore: Sendable {
    let service: String

    init(service: String = (Bundle.main.bundleIdentifier ?? "io.spatiumddi.SpatiumDDI") + ".token") {
        self.service = service
    }

    enum StoreError: Error, LocalizedError, Equatable {
        /// Neither biometry nor a passcode — nothing can protect a token here.
        case deviceUnprotected(String)
        case authenticationFailed
        case cancelled
        case notFound
        /// The stored item was invalidated — see `.biometryCurrentSet` below.
        case enrollmentChanged
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .deviceUnprotected(let detail):
                return "This device can't store a token securely: \(detail)"
            case .authenticationFailed:
                return "Authentication failed."
            case .cancelled:
                return "Authentication was cancelled."
            case .notFound:
                return "No saved token for this server."
            case .enrollmentChanged:
                return
                    "The saved token was discarded because this device's biometric enrolment changed. Sign in again."
            case .keychain(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
                return "Keychain error: \(message)"
            }
        }
    }

    private func account(for address: ServerAddress) -> String { "api-token.\(address.pinKey)" }

    // MARK: - What this device can offer

    /// The strongest protection available right now, or why there is none.
    ///
    /// Biometry is preferred. A **lockout** is deliberately still counted as
    /// biometry: `canEvaluatePolicy` refuses after too many failed attempts,
    /// but the enrolment is intact and the lockout clears on the next passcode
    /// unlock. Downgrading a token to passcode protection because of a
    /// temporary lockout would make a transient state permanent.
    static func availableProtection() -> Result<KeychainProtection, StoreError> {
        let context = LAContext()
        var biometryError: NSError?

        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometryError) {
            return .success(.biometrics)
        }
        if (biometryError as? LAError)?.code == .biometryLockout {
            return .success(.biometrics)
        }

        var passcodeError: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &passcodeError) {
            return .success(.passcode)
        }

        // Report the passcode failure, not the biometric one: "no passcode set"
        // is the actionable sentence, and "Face ID not enrolled" would send the
        // operator to fix the wrong thing.
        let detail = passcodeError?.localizedDescription ?? "no passcode is set"
        return .failure(.deviceUnprotected(detail))
    }

    /// The biometric method's own name, for copy. `nil` when there is none.
    ///
    /// Reported independently of `availableProtection()` because the two answer
    /// different questions: this one is about hardware and enrolment, that one
    /// is about what will actually protect the token.
    static func biometryName() -> String? {
        let context = LAContext()
        var error: NSError?
        let usable = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        guard usable || (error as? LAError)?.code == .biometryLockout else { return nil }
        return name(of: context.biometryType)
    }

    /// What this hardware *could* do, enrolled or not.
    ///
    /// The difference matters for the passcode-fallback copy. "Face ID isn't
    /// set up on this device" is a sentence the operator can act on; the same
    /// sentence on an iPad with no Face ID hardware sends them looking for a
    /// setting that does not exist. `biometryType` is only meaningful after a
    /// `canEvaluatePolicy` call, whose result is deliberately ignored here —
    /// the question is about the hardware, not the enrolment.
    static func biometryHardwareName() -> String? {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return name(of: context.biometryType)
    }

    private static func name(of type: LABiometryType) -> String? {
        switch type {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
    }

    /// How to name the gate in operator-facing copy, whatever it turns out to be.
    static func biometryDescription() -> String {
        biometryName() ?? String(localized: "your passcode")
    }

    // MARK: - Reading what is stored

    /// True when a token exists, checked without prompting anyone.
    ///
    /// Asks only for attributes: an attribute-only query doesn't unseal the
    /// value, so it doesn't trip the access control.
    /// Whether the app should behave as though a token is stored.
    ///
    /// Errs towards **yes**, because the two wrong answers are not equally
    /// bad. Saying "yes" when there is nothing costs one unlock attempt that
    /// fails honestly and drops to sign-in. Saying "no" when the token is
    /// there tells the operator their credential is gone and makes them enrol
    /// a new one — over what may have been a momentary refusal.
    func hasToken(for address: ServerAddress) -> Bool {
        presence(for: address) != .absent
    }

    /// What is actually guarding the stored token, or `nil` if there isn't one.
    ///
    /// An item written before this app understood passcode protection carries no
    /// marker; those are biometric by construction, so that is the fallback.
    func storedProtection(for address: ServerAddress) -> KeychainProtection? {
        guard let attributes = attributes(for: address) else { return nil }
        guard let marker = attributes[kSecAttrGeneric as String] as? Data else { return .biometrics }
        return KeychainProtection(marker: marker) ?? .biometrics
    }

    /// Whether a token is stored — and the difference between "no" and
    /// "cannot tell right now", which are not the same answer.
    nonisolated enum Presence: Equatable {
        case present
        case absent
        /// The Keychain refused to say. The item may well be there.
        case unknown(OSStatus)
    }

    /// Looks for the item without prompting for anything.
    ///
    /// **Only `errSecItemNotFound` proves absence.** An item stored
    /// `WhenPasscodeSetThisDeviceOnly` behind an access control answers
    /// `errSecInteractionNotAllowed` when it cannot be reached at that
    /// moment — while the device is locked, or when the query is not allowed
    /// to interact — and reading that as "there is no token" is how a
    /// perfectly good credential comes to be reported missing.
    func presence(for address: ServerAddress) -> Presence {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: address),
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return .present
        case errSecItemNotFound: return .absent
        default: return .unknown(status)
        }
    }

    private func attributes(for address: ServerAddress) -> [String: Any]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: address),
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }

    // MARK: - Writing

    /// Writes the token, replacing any existing one for this server.
    ///
    /// Returns the protection it was actually written with, so the caller can
    /// tell the operator when they got the weaker one rather than leaving them
    /// to assume Face ID is involved.
    ///
    /// `.biometryCurrentSet` ties the item to the biometric enrolment as it
    /// stands now: adding a face or fingerprint destroys it, and the operator
    /// signs in again. That costs a re-auth, and buys that enrolling a new face
    /// on an unlocked phone cannot silently inherit access to production DNS.
    /// `.devicePasscode` carries no such guarantee — which is exactly why the
    /// difference is surfaced rather than smoothed over.
    @discardableResult
    func save(_ token: String, for address: ServerAddress) throws -> KeychainProtection {
        // Enforced here, not left to callers. SecAccessControlCreateWithFlags
        // will happily mint a `.biometryCurrentSet` policy on a device with no
        // enrolment (the simulator does exactly this), and SecItemAdd then
        // succeeds — storing a token nothing would ever be asked to unlock.
        // Non-negotiable #2 is a property of the store, not of its call sites.
        let protection: KeychainProtection
        switch Self.availableProtection() {
        case .success(let available): protection = available
        case .failure(let unprotected): throw unprotected
        }

        var accessError: Unmanaged<CFError>?
        guard
            let access = SecAccessControlCreateWithFlags(
                nil,
                // Both policies additionally require a passcode to exist at
                // all, so "no passcode" is refused by the Keychain even if the
                // check above were ever wrong.
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                protection == .biometrics ? .biometryCurrentSet : .devicePasscode,
                &accessError
            )
        else {
            let detail =
                (accessError?.takeRetainedValue() as Error?)?.localizedDescription
                ?? "a device passcode must be set"
            throw StoreError.deviceUnprotected(detail)
        }

        // Delete first: SecItemUpdate cannot change an item's access control.
        try? delete(for: address)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: address),
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessControl as String: access,
            // Which gate this item was sealed behind. An attribute, not the
            // value, so it can be read back without a prompt — and so it is
            // deleted with the item rather than outliving it in a defaults
            // file that could then disagree with reality.
            kSecAttrGeneric as String: protection.marker,
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        return protection
    }

    // MARK: - Reading

    /// Reads the token, prompting for whatever is guarding it.
    ///
    /// Authenticates explicitly first, then hands the satisfied context to the
    /// Keychain, so the operator sees one prompt carrying our reason string
    /// rather than a bare system dialog.
    ///
    /// The policy is chosen from the item's **own** protection, not from what
    /// the device can do today. A passcode-satisfied context does not unseal a
    /// `.biometryCurrentSet` item, so evaluating the wrong one would re-prompt
    /// or fail for no reason the operator could act on.
    func token(for address: ServerAddress, reason: String) async throws -> String {
        let protection = storedProtection(for: address) ?? .biometrics
        let context = LAContext()

        let policy: LAPolicy
        switch protection {
        case .biometrics:
            // Biometry or nothing: the item's ACL will not accept a passcode
            // either, so offering one as a fallback would be a dead end.
            context.localizedFallbackTitle = ""
            policy = .deviceOwnerAuthenticationWithBiometrics
        case .passcode:
            policy = .deviceOwnerAuthentication
        }

        do {
            try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                throw StoreError.cancelled
            case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                throw StoreError.deviceUnprotected(error.localizedDescription)
            default:
                throw StoreError.authenticationFailed
            }
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: address),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
                throw StoreError.keychain(errSecDecode)
            }
            return token
        case errSecItemNotFound:
            throw StoreError.notFound
        case errSecUserCanceled:
            // Distinct from a failure: `AppFlowModel` shows no error for a
            // cancellation, which is the right answer for a deliberate dismissal.
            throw StoreError.cancelled
        case errSecAuthFailed:
            throw StoreError.authenticationFailed
        // Raised when the item's `.biometryCurrentSet` policy no longer holds.
        case errSecInvalidData, errSecKeySizeNotAllowed:
            throw StoreError.enrollmentChanged
        default:
            throw StoreError.keychain(status)
        }
    }

    func delete(for address: ServerAddress) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: address),
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StoreError.keychain(status)
        }
    }
}
