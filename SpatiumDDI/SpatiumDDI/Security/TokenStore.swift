//
//  TokenStore.swift
//  SpatiumDDI
//

import Foundation
import LocalAuthentication
import Security

/// The per-device API token, held in the Keychain behind a biometric gate.
///
/// Non-negotiable #2: never `UserDefaults`, never a plist, never a log line.
/// The item is written with an access control that demands biometry, so the
/// token cannot be read back by anything — including this app — without the
/// operator present.
nonisolated struct TokenStore: Sendable {
    let service: String

    init(service: String = (Bundle.main.bundleIdentifier ?? "io.spatiumddi.SpatiumDDI") + ".token") {
        self.service = service
    }

    enum StoreError: Error, LocalizedError, Equatable {
        case biometricsUnavailable(String)
        case authenticationFailed
        case cancelled
        case notFound
        /// The stored item was invalidated — see `.biometryCurrentSet` below.
        case enrollmentChanged
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .biometricsUnavailable(let detail):
                return "This device can't store a token securely: \(detail)"
            case .authenticationFailed:
                return "Biometric authentication failed."
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

    /// Whether biometry is usable right now, and why not if it isn't.
    static func biometryAvailability() -> Result<LABiometryType, StoreError> {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            let detail = error?.localizedDescription ?? "biometrics are not set up"
            return .failure(.biometricsUnavailable(detail))
        }
        return .success(context.biometryType)
    }

    /// How to name the biometric method in operator-facing copy.
    static func biometryDescription() -> String {
        guard case .success(let type) = biometryAvailability() else { return "biometrics" }
        switch type {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "biometrics"
        }
    }

    /// True when a token exists, checked without prompting anyone.
    ///
    /// Asks only for attributes: an attribute-only query doesn't unseal the
    /// value, so it doesn't trip the access control.
    func hasToken(for address: ServerAddress) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: address),
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Writes the token, replacing any existing one for this server.
    ///
    /// `.biometryCurrentSet` ties the item to the biometric enrolment as it
    /// stands now: adding a face or fingerprint destroys it, and the operator
    /// signs in again. That costs a re-auth, and buys that enrolling a new face
    /// on an unlocked phone cannot silently inherit access to production DNS.
    func save(_ token: String, for address: ServerAddress) throws {
        // Enforced here, not left to callers. SecAccessControlCreateWithFlags
        // will happily mint a `.biometryCurrentSet` policy on a device with no
        // enrolment (the simulator does exactly this), and SecItemAdd then
        // succeeds — storing a token nothing would ever be asked to unlock.
        // Non-negotiable #2 is a property of the store, not of its call sites.
        if case .failure(let unavailable) = Self.biometryAvailability() {
            throw unavailable
        }

        var accessError: Unmanaged<CFError>?
        guard
            let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                .biometryCurrentSet,
                &accessError
            )
        else {
            let detail =
                (accessError?.takeRetainedValue() as Error?)?.localizedDescription
                ?? "a device passcode must be set"
            throw StoreError.biometricsUnavailable(detail)
        }

        // Delete first: SecItemUpdate cannot change an item's access control.
        try? delete(for: address)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: address),
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessControl as String: access,
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
    }

    /// Reads the token, prompting for biometry.
    ///
    /// Authenticates explicitly first, then hands the satisfied context to the
    /// Keychain, so the operator sees one prompt carrying our reason string
    /// rather than a bare system dialog.
    func token(for address: ServerAddress, reason: String) async throws -> String {
        let context = LAContext()
        context.localizedFallbackTitle = ""  // No passcode fallback: biometry or nothing.

        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel:
                throw StoreError.cancelled
            case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet:
                throw StoreError.biometricsUnavailable(error.localizedDescription)
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
