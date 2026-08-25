//
//  AppSectionTests.swift
//  SpatiumDDITests
//

import Foundation
import Testing
import UIKit

@testable import SpatiumDDI

/// The sidebar's own consistency.
@Suite("Sidebar sections")
struct AppSectionTests {
    /// Every section's symbol has to actually exist.
    ///
    /// A name SF Symbols does not know renders as **nothing at all** — no
    /// placeholder, no warning, no build error. The row simply loses its icon,
    /// which is invisible in a diff and invisible in review, and only shows up
    /// when somebody looks at the running app on a device. That is exactly how
    /// `poweroutlet.type.b.squarefill` shipped: a plausible-looking name for a
    /// symbol actually called `poweroutlet.type.b.square.fill`, one missing
    /// full stop, and a blank row in the Network group.
    @Test("Every section symbol resolves", arguments: AppSection.allCases)
    func symbolExists(section: AppSection) {
        #expect(
            UIImage(systemName: section.symbol) != nil,
            "\(section.rawValue) uses \"\(section.symbol)\", which SF Symbols does not know"
        )
    }

    /// Two rows wearing the same icon in one sidebar is a navigation bug, not a
    /// cosmetic one — the icon is what an operator reaches for at a glance.
    @Test("No two sections share an icon")
    func symbolsAreDistinct() {
        let symbols = AppSection.allCases.map(\.symbol)
        let duplicates = Dictionary(grouping: symbols, by: { $0 }).filter { $0.value.count > 1 }.keys
        #expect(duplicates.isEmpty, "shared by more than one section: \(duplicates.sorted())")
    }

    /// A section reachable from the sidebar but absent from every group would
    /// exist in the enum and nowhere on screen.
    @Test("Every section appears in exactly one group")
    func everySectionIsGrouped() {
        let grouped = AppSection.Group.allCases.flatMap(\.sections)
        for section in AppSection.allCases {
            #expect(
                grouped.count(where: { $0 == section }) == 1,
                "\(section.rawValue) appears \(grouped.count(where: { $0 == section })) times across the groups"
            )
        }
    }
}
