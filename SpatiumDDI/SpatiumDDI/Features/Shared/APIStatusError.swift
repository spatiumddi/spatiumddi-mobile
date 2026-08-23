//
//  APIStatusError.swift
//  SpatiumDDI
//

import Foundation

/// A status the generated client reported as a case rather than a throw.
///
/// The document declares only 200 and 422, so every other status — 401, 403,
/// 503 — arrives as `Output.undocumented(statusCode:)`. Only the call site can
/// see it, and the call site's job is to turn it into this so one error path
/// carries both it and a genuine transport failure.
///
/// Without this the natural shape is `.ok` shorthand, which collapses all of
/// them into an opaque `RuntimeError` and makes non-negotiable #4's honest 403
/// and #5's maintenance window unreachable.
nonisolated struct APIStatusError: Error {
    let status: Int
}

extension LoadState {
    /// Runs a fetch, folding a thrown status and a transport failure into `.failed`.
    ///
    /// The call site still switches over the generated `Output` — that switch is
    /// the only place a 403 or a 503 is distinguishable — but it throws instead
    /// of assigning, so the four states are produced in one place.
    static func fetching(_ operation: () async throws -> Value) async -> LoadState<Value> {
        do {
            return .loaded(try await operation())
        } catch let error as APIStatusError {
            return .failed(APIErrorMessage.describe(status: error.status))
        } catch is CancellationError {
            // A cancelled fetch is a view going away or a refresh superseding
            // this one. Reporting it as a failure would flash an error over a
            // screen the operator has already left.
            return .idle
        } catch {
            return .failed(APIErrorMessage.describe(error))
        }
    }
}
