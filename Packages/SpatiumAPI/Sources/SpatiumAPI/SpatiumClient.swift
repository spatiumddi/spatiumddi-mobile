//
//  SpatiumClient.swift
//  SpatiumAPI
//

import Foundation
import HTTPTypes
import OpenAPIRuntime
import OpenAPIURLSession

/// Builds a generated client bound to one control plane.
///
/// The `URLSession` is supplied by the caller rather than created here: the app
/// applies its own certificate trust policy through a session delegate, and a
/// client that quietly made its own session would bypass it.
public enum SpatiumClientFactory {
    /// - Parameter onUnauthorized: Called when the server rejects the
    ///   credential. Placed here rather than at each call site for the same
    ///   reason the token is: a rule every future caller has to remember is a
    ///   rule that eventually gets forgotten.
    public static func makeClient(
        serverURL: URL,
        session: URLSession,
        token: String?,
        onUnauthorized: (@Sendable () -> Void)? = nil
    ) -> Client {
        var middlewares: [any ClientMiddleware] = []
        if let token {
            middlewares.append(BearerTokenMiddleware(token: token))
        }
        if let onUnauthorized {
            middlewares.append(UnauthorizedMiddleware(handler: onUnauthorized))
        }
        return Client(
            serverURL: serverURL,
            configuration: Configuration(dateTranscoder: LenientDateTranscoder()),
            transport: URLSessionTransport(configuration: .init(session: session)),
            middlewares: middlewares
        )
    }
}

/// Attaches the operator's credential to every request.
///
/// Kept as middleware so no call site has to remember it, and so the token has
/// exactly one place it can be read from.
public struct BearerTokenMiddleware: ClientMiddleware {
    private let token: String

    public init(token: String) {
        self.token = token
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        var request = request
        request.headerFields[.authorization] = "Bearer \(token)"
        return try await next(request, body, baseURL)
    }
}

/// Reports a rejected credential, wherever in the app the call came from.
///
/// A 401 means the token is no longer usable, and every subsequent request will
/// fail the same way. Without this the operator sits on a screen full of errors
/// with no route back to signing in.
public struct UnauthorizedMiddleware: ClientMiddleware {
    private let handler: @Sendable () -> Void

    public init(handler: @escaping @Sendable () -> Void) {
        self.handler = handler
    }

    public func intercept(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String,
        next: (HTTPRequest, HTTPBody?, URL) async throws -> (HTTPResponse, HTTPBody?)
    ) async throws -> (HTTPResponse, HTTPBody?) {
        let (response, responseBody) = try await next(request, body, baseURL)
        if response.status.code == 401 { handler() }
        return (response, responseBody)
    }
}
