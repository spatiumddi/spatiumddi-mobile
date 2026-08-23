//
//  DecisionTests.swift
//  SpatiumDDITests
//

import Foundation
import Testing

@testable import SpatiumDDI

/// Who the app offers a decision to.
///
/// Every rule here is the control plane's, restated so the app can say before
/// the tap what the server would say after it. They are tested rather than
/// trusted because each one is a *refusal*, and a refusal that only shows up
/// as a 409 — after the approver has read the case and made up their mind —
/// is the worst possible time to learn it.
@Suite("Change request rules")
struct ChangeRequestRuleTests {

    @Test("A pending request an approver didn't raise is decidable")
    func decidable() {
        #expect(
            ChangeRequestRules.blocksDeciding(
                state: "pending", isRequester: false, mayDecide: true
            ) == nil
        )
    }

    /// The two-person rule. The platform blocks a self-approval outright, and
    /// a self-*reject* too — that one is just a cancel, and it says so.
    @Test("Your own request is never yours to decide")
    func ownRequest() {
        #expect(
            ChangeRequestRules.blocksDeciding(
                state: "pending", isRequester: true, mayDecide: true
            ) == .ownRequest
        )
    }

    @Test("Deciding needs the approve grant, not merely write access")
    func withoutGrant() {
        #expect(
            ChangeRequestRules.blocksDeciding(
                state: "pending", isRequester: false, mayDecide: false
            ) == .noGrant
        )
    }

    /// Settled wins over everything: there is nothing to explain about
    /// permissions on a row nobody can act on any more.
    @Test(
        "A settled request reports its state, not a permission problem",
        arguments: [
            "approved", "rejected", "expired", "failed",
        ])
    func settled(state: String) {
        #expect(
            ChangeRequestRules.blocksDeciding(
                state: state, isRequester: true, mayDecide: false
            ) == .settled(state)
        )
    }

    /// The server compares a lowercase literal; the app must not care how the
    /// state word arrives.
    @Test("Pending is recognised whatever its casing", arguments: ["pending", "Pending", "PENDING"])
    func pendingCasing(state: String) {
        #expect(ChangeRequestRules.isPending(state))
        #expect(
            ChangeRequestRules.blocksDeciding(
                state: state, isRequester: false, mayDecide: true
            ) == nil
        )
    }

    @Test("The requester may withdraw their own request")
    func requesterCancels() {
        #expect(
            ChangeRequestRules.blocksCancelling(
                state: "pending", isRequester: true, isSuperadmin: false
            ) == nil
        )
    }

    @Test("Someone else's request is not yours to withdraw")
    func strangerCancels() {
        #expect(
            ChangeRequestRules.blocksCancelling(
                state: "pending", isRequester: false, isSuperadmin: false
            ) == .notYours
        )
    }

    @Test("A superadmin may withdraw anyone's request")
    func superadminCancels() {
        #expect(
            ChangeRequestRules.blocksCancelling(
                state: "pending", isRequester: false, isSuperadmin: true
            ) == nil
        )
    }

    /// The pair that matters on your own pending row: no decision, but a
    /// withdrawal — which is exactly what the screen offers instead.
    @Test("Your own pending request offers withdrawal in place of a decision")
    func ownRequestOffersWithdrawal() {
        #expect(
            ChangeRequestRules.blocksDeciding(
                state: "pending", isRequester: true, mayDecide: true
            ) == .ownRequest
        )
        #expect(
            ChangeRequestRules.blocksCancelling(
                state: "pending", isRequester: true, isSuperadmin: false
            ) == nil
        )
    }
}

/// Folding a written row back into the list it came from.
@Suite("Row updates")
struct RowUpdateTests {
    private struct Row: Equatable {
        let id: String
        var resolved: Bool
    }

    private let rows = [
        Row(id: "a", resolved: false),
        Row(id: "b", resolved: false),
        Row(id: "c", resolved: false),
    ]

    @Test("A row that still belongs is replaced in place")
    func replacesInPlace() {
        let updated = RowUpdate.apply(Row(id: "b", resolved: true), to: rows, id: \.id)
        #expect(updated.map(\.id) == ["a", "b", "c"])
        #expect(updated[1].resolved)
    }

    /// Resolving an alert while "unresolved only" is on: the row leaves, and
    /// leaving is the whole point — a resolved row under that heading is a lie
    /// about the estate.
    @Test("A row that no longer belongs leaves the list")
    func removesWhenFilteredOut() {
        let updated = RowUpdate.apply(
            Row(id: "b", resolved: true), to: rows, id: \.id, belongs: { !$0.resolved }
        )
        #expect(updated.map(\.id) == ["a", "c"])
    }

    /// The list may be filtered to something this row was never part of.
    /// Appending it would put a row on screen the operator's own filter says
    /// should not be there.
    @Test("An unknown row is not appended")
    func ignoresUnknownRow() {
        let updated = RowUpdate.apply(Row(id: "z", resolved: true), to: rows, id: \.id)
        #expect(updated == rows)
    }

    @Test("An empty list stays empty")
    func emptyList() {
        #expect(RowUpdate.apply(Row(id: "a", resolved: true), to: [], id: \.id).isEmpty)
    }

    /// Order is what the operator is reading — most severe first for alerts,
    /// soonest to expire for change requests. A replacement must not reshuffle it.
    @Test("Replacing keeps the row where it was")
    func preservesOrder() {
        let updated = RowUpdate.apply(Row(id: "a", resolved: true), to: rows, id: \.id)
        #expect(updated.map(\.id) == ["a", "b", "c"])
    }
}
