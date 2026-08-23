//
//  APIStatusError.swift
//  SpatiumDDI
//

import Foundation
import OpenAPIRuntime

/// A status the generated client reported as a case rather than a throw.
///
/// The document declares only 200 and 422, so every other status — 401, 403,
/// 404, 503 — arrives as `Output.undocumented(statusCode:)`. Only the call site
/// can see it, and the call site's job is to turn it into this so one error path
/// carries both it and a genuine transport failure.
///
/// Without this the natural shape is `.ok` shorthand, which collapses all of
/// them into an opaque `RuntimeError` and makes non-negotiable #4's honest 403
/// and #5's maintenance window unreachable.
nonisolated struct APIStatusError: Error {
    let status: Int
    /// What the server said in its `detail` field, where it said anything.
    ///
    /// This matters most for 404. The platform returns 404 both for "no such
    /// row" and for "that feature module is switched off", and the body is the
    /// only thing that tells them apart — `{"detail": "Feature 'network.vrf' is
    /// disabled."}`. Reporting the generic 404 message for the second case
    /// tells an operator their data was deleted, which is alarming and wrong.
    let detail: String?

    init(status: Int, detail: String? = nil) {
        self.status = status
        self.detail = detail
    }

    /// Reads the `detail` out of an undocumented response body.
    ///
    /// Bounded: a body this large is not a FastAPI error envelope, and an error
    /// path is the wrong place to buffer an unbounded stream.
    init(status: Int, payload: UndocumentedPayload) async {
        var detail: String?
        if let body = payload.body,
            let data = try? await Data(collecting: body, upTo: 8 * 1024),
            let envelope = try? JSONDecoder().decode(DetailEnvelope.self, from: data),
            !envelope.detail.isEmpty
        {
            detail = envelope.detail
        }
        self.init(status: status, detail: detail)
    }

    private struct DetailEnvelope: Decodable {
        let detail: String
    }

    /// The feature module this error names, if it named one.
    ///
    /// `Feature 'network.vrf' is disabled.` → `network.vrf`
    var disabledFeatureModule: String? {
        guard let detail, detail.hasPrefix("Feature "),
            let start = detail.firstIndex(of: "'"),
            let end = detail[detail.index(after: start)...].firstIndex(of: "'")
        else { return nil }
        return String(detail[detail.index(after: start)..<end])
    }
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
            return .failed(APIErrorMessage.describe(error))
        } catch {
            // A cancelled fetch is a view going away or a refresh superseding
            // this one, and reporting it would flash an error over a screen the
            // operator has already left.
            //
            // Checked on the task rather than by matching `CancellationError`:
            // the request is in URLSession by the time cancellation lands, so
            // what actually comes back is `URLError.cancelled` wrapped in a
            // `ClientError` — which the type match misses entirely, leaving the
            // word "cancelled" rendered as a failure.
            if Task.isCancelled { return .idle }
            return .failed(APIErrorMessage.describe(error))
        }
    }
}
