//
//  ControlPlaneSession.swift
//  SpatiumDDI
//

import Foundation
import SpatiumAPI

/// The authenticated connection to one control plane, for the life of a session.
///
/// Owns the `URLSession` so the generated client goes through this app's
/// certificate trust policy. A client that made its own session would bypass the
/// pin the operator approved, which is the one thing the trust flow exists to
/// prevent.
@MainActor
final class ControlPlaneSession {
    let address: ServerAddress
    let client: Client

    /// The opening characters of this session's token, as the server itself
    /// publishes them.
    ///
    /// **Not a secret.** `/api/v1/api-tokens` returns exactly this string in
    /// the `prefix` field of every row it lists, so holding it here reveals
    /// nothing the token list does not already show anyone who can read it.
    ///
    /// It exists because the Access screen has to tell *this device's*
    /// credential apart from the others before offering to revoke one. That is
    /// the difference between "kill the phone I left on a train" and "sign
    /// myself out by accident", and there is nothing else in the response to
    /// distinguish them — an API token, unlike a session, has no `is_current`.
    ///
    /// Empty for a JWT: a `/auth/login` token has no `sddi_` prefix, so it
    /// matches no row rather than the wrong one.
    let tokenPrefix: String

    private let urlSession: URLSession

    init(
        address: ServerAddress,
        token: String,
        trustStore: TrustStore = TrustStore(),
        onUnauthorized: (@Sendable () -> Void)? = nil
    ) {
        self.address = address
        self.tokenPrefix = ControlPlaneSession.publishedPrefix(of: token)

        let delegate = ServerTrustDelegate(address: address, trustStore: trustStore)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false

        self.urlSession = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        // No `servers` in the document, so operation paths are absolute and the
        // origin is the whole base URL.
        self.client = SpatiumClientFactory.makeClient(
            serverURL: address.origin,
            session: urlSession,
            token: token,
            onUnauthorized: onUnauthorized
        )
    }

    /// The part of an API token the server publishes as its `prefix`.
    ///
    /// `sddi_` plus five characters, which is what the platform stores and
    /// lists. Anything not carrying that scheme — a JWT — yields an empty
    /// string, which deliberately matches nothing.
    nonisolated static func publishedPrefix(of token: String) -> String {
        guard token.hasPrefix("sddi_") else { return "" }
        let prefix = token.prefix(10)
        return prefix.count == 10 ? String(prefix) : ""
    }

    /// Ends the session's network activity and releases the trust delegate.
    func invalidate() {
        urlSession.finishTasksAndInvalidate()
    }
}
