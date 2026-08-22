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
    static func describe(_ error: any Error) -> String {
        if let client = error as? ClientError {
            if let status = (client.response)?.status.code {
                return describe(status: status)
            }
            return describeTransport(client.underlyingError)
        }
        return describeTransport(error)
    }

    private static func describe(status: Int) -> String {
        switch status {
        case 401:
            "Your session is no longer valid. Sign in again."
        case 403:
            "You don't have permission to read this. Ask an administrator to review your role."
        case 404:
            "The server doesn't have this any more — it may have been deleted."
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

    private static func describeTransport(_ error: any Error) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch nsError.code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "Can't reach the server — check this device's network."
        case NSURLErrorTimedOut:
            return "The server didn't respond in time."
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "This device has no network connection."
        default:
            return error.localizedDescription
        }
    }
}
