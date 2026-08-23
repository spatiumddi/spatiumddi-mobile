//
//  APIErrorMessage.swift
//  SpatiumDDI
//

import Foundation
import HTTPTypes
import OpenAPIRuntime

/// Turns a client error into something an operator can act on.
///
/// Non-negotiable #4: a 403 is shown honestly, never swallowed. Non-negotiable
/// #5: a 503 is a change window, not a network failure, and is never retried
/// into automatically.
nonisolated enum APIErrorMessage {
    /// The message for a status the call site caught, preferring what the
    /// server actually said over this app's generic wording.
    static func describe(_ error: APIStatusError) -> LocalizedStringResource {
        // A disabled feature module is a 404 that means something specific and
        // benign. The generic 404 text — "it may have been deleted" — would
        // tell an operator their data is gone, which is both wrong and the kind
        // of wrong that starts an incident.
        if let module = error.disabledFeatureModule {
            return
                "The \(module) feature module is switched off on this server, so there's nothing here to show."
        }
        if let detail = error.detail, error.status == 404 || error.status == 403 {
            // The server's own words, passed through. Not translatable here —
            // it is data, and inventing a key for it would be a lie.
            return LocalizedStringResource(stringLiteral: detail)
        }
        return describe(status: error.status)
    }

    static func describe(_ error: any Error) -> LocalizedStringResource {
        if let status = error as? APIStatusError { return describe(status) }

        // Cancellation is never news. It reached a screen once — as
        // "The operation couldn't be completed. (Swift.CancellationError error
        // 1.)" on the IPAM list — because a view still hand-rolled its own
        // catch. Callers should route through `LoadState.fetching`, which folds
        // cancellation into `.idle`, but this is the backstop: raw Swift error
        // text is never something to show an operator.
        if error is CancellationError { return "The request was cancelled." }
        if let client = error as? ClientError {
            if let status = (client.response)?.status.code {
                return describe(status: status)
            }
            return describeTransport(client.underlyingError)
        }
        return describeTransport(error)
    }

    /// The message for a status the generated client reported directly.
    ///
    /// Not private: the generated `.ok` shorthand throws `RuntimeError`, not
    /// `ClientError`, for any status the document doesn't declare — and this
    /// document declares only 200 and 422. A 401, 403 or 503 therefore arrives
    /// as `Output.undocumented(statusCode:)`, and only the call site can see it.
    static func describe(status: Int) -> LocalizedStringResource {
        switch status {
        case 401:
            "Your session is no longer valid. Sign in again."
        case 403:
            "You don't have permission to read this. Ask an administrator to review your role."
        case 404:
            "The server doesn't have this any more — it may have been deleted."
        case 422:
            "The server rejected that request as invalid."
        case 429:
            "The server is rate-limiting requests. Wait a moment and try again."
        case 503:
            "The server is in a change window. Try again once it's finished."
        case 500...599:
            "The server reported an error (HTTP \(status))."
        default:
            "Unexpected response from the server (HTTP \(status))."
        }
    }

    private static func describeTransport(_ error: any Error) -> LocalizedStringResource {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return LocalizedStringResource(stringLiteral: error.localizedDescription)
        }
        switch nsError.code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Can't reach the server — check this device's network."
        case NSURLErrorTimedOut:
            return "The server didn't respond in time."
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "This device has no network connection."
        case NSURLErrorCancelled:
            // Normally intercepted by the task-cancellation check before it can
            // reach a screen; this is for the case where the session itself was
            // invalidated under an in-flight request.
            return "The request was cancelled."
        default:
            return LocalizedStringResource(stringLiteral: error.localizedDescription)
        }
    }
}
