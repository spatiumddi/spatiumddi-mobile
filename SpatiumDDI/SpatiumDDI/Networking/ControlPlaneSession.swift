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

    private let urlSession: URLSession

    init(address: ServerAddress, token: String, trustStore: TrustStore = TrustStore()) {
        self.address = address

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
            token: token
        )
    }

    /// Ends the session's network activity and releases the trust delegate.
    func invalidate() {
        urlSession.finishTasksAndInvalidate()
    }
}
