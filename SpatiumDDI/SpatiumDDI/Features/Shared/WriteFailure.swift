//
//  WriteFailure.swift
//  SpatiumDDI
//

import Foundation

/// What a write came back with when it did not succeed.
///
/// Every write path in this app has to make the same three-way distinction, so
/// it is made once here rather than four times slightly differently:
///
/// 1. a **soft conflict** the server will accept once the operator has read it,
///    re-sent with `force`;
/// 2. anything else the server said, worded for a write;
/// 3. a transport failure, which never went near the server at all.
///
/// The first is the one that is easy to get wrong. Treating every 409 as final
/// dead-ends a duplicate hostname the operator meant (a round-robin A record);
/// treating every 409 as retryable loops a lost race forever.
nonisolated enum WriteFailure: Equatable {
    /// Re-sendable with `force`, once the operator has read the warnings.
    case confirmable([CollisionWarning])
    /// The end of it, in the operator's terms.
    case failed(FailureMessage)

    /// Classifies whatever a write threw.
    ///
    /// - Parameter forced: whether this attempt already carried `force`. A
    ///   forced attempt has waived the soft warnings, so a second
    ///   `requires_confirmation` means something else went wrong and must not
    ///   be offered as confirmable again — that would loop.
    static func classify(_ error: any Error, forced: Bool = false) async -> WriteFailure {
        // A 422 whose `detail` is a plain string fails to decode inside the
        // generated client, so the status has to be recovered from the
        // `ClientError` before it can be described. Written out rather than
        // with `??` because the right-hand side is `async`.
        var status = error as? APIStatusError
        if status == nil { status = await APIStatusError.recovered(from: error) }

        guard let status else { return .failed(APIErrorMessage.describe(error)) }
        if !forced, let collision = status.collision, collision.requiresConfirmation {
            return .confirmable(collision.warnings)
        }
        return .failed(APIErrorMessage.describeWrite(status))
    }
}
