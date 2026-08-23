//
//  UtilisationTests.swift
//  SpatiumDDITests
//

import Testing

@testable import SpatiumDDI

@Suite("Estate utilisation")
struct UtilisationTests {
    /// The bug this guards against: averaging the per-subnet percentages. A tiny
    /// full subnet next to a huge empty one would report the estate as half
    /// consumed, which is a capacity decision made on a wrong number.
    @Test("Utilisation is weighted by subnet size, not averaged")
    func weightsBySize() {
        // A full /30 (4 addresses) and a nearly-empty /16 (65,536).
        let utilisation = OverviewModel.IPAMTotals.weightedUtilisation([
            (allocated: 4, total: 4),
            (allocated: 0, total: 65_536),
        ])
        // Averaging the percentages would give 50%.
        #expect(utilisation < 0.1)
        #expect(abs(utilisation - (4.0 / 65_540.0 * 100)) < 0.0001)
    }

    @Test("A fully allocated estate is 100%")
    func fullEstate() {
        let utilisation = OverviewModel.IPAMTotals.weightedUtilisation([
            (allocated: 256, total: 256),
            (allocated: 16, total: 16),
        ])
        #expect(abs(utilisation - 100) < 0.0001)
    }

    // No subnets means no denominator; reporting 100% or NaN would both be worse
    // than reporting nothing used.
    @Test("An empty estate is zero, not a division by zero")
    func emptyEstate() {
        #expect(OverviewModel.IPAMTotals.weightedUtilisation([]) == 0)
        #expect(OverviewModel.IPAMTotals.weightedUtilisation([(allocated: 0, total: 0)]) == 0)
    }

    @Test("A half-used estate reports half")
    func halfUsed() {
        let utilisation = OverviewModel.IPAMTotals.weightedUtilisation([
            (allocated: 128, total: 256),
            (allocated: 512, total: 1_024),
        ])
        #expect(abs(utilisation - 50) < 0.0001)
    }
}
