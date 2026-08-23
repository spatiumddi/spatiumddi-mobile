//
//  RowUpdate.swift
//  SpatiumDDI
//

import Foundation

/// Folding a written row back into the list it came from.
///
/// Every write in this app returns the row the server settled on, and the list
/// behind it then has to answer a question with two different answers: does
/// this row *change*, or does it *leave*? Resolving an alert while "unresolved
/// only" is on means it leaves. Resolving one with the filter off means it
/// changes and grows a badge.
///
/// Getting that wrong is not cosmetic. A resolved alert left sitting in a list
/// headed "unresolved" is a lie about the estate, and re-fetching to avoid
/// thinking about it costs a round trip and throws away the operator's scroll
/// position for a row whose new contents the server just handed over.
nonisolated enum RowUpdate {
    /// Replaces `updated` in `rows`, or removes it when it no longer belongs.
    ///
    /// - Parameters:
    ///   - id: identity, since the generated row types are not `Identifiable`.
    ///   - belongs: whether the updated row still matches what the list is
    ///     showing. Evaluated only on the updated row: the others were already
    ///     filtered by the server.
    ///
    /// A row that is not present is returned unchanged rather than appended —
    /// the list may be filtered to something this row was never part of, and
    /// inserting it would put a row on screen that the operator's own filter
    /// says should not be there.
    static func apply<Row>(
        _ updated: Row,
        to rows: [Row],
        id: (Row) -> String,
        belongs: (Row) -> Bool = { _ in true }
    ) -> [Row] {
        let updatedID = id(updated)
        guard let index = rows.firstIndex(where: { id($0) == updatedID }) else { return rows }
        var rows = rows
        if belongs(updated) {
            rows[index] = updated
        } else {
            rows.remove(at: index)
        }
        return rows
    }
}
