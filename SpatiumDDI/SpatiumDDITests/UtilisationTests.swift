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

    /// The crash this guards against, exactly as it happened.
    ///
    /// A real estate held `2001:db8:10:1::/64`. 2^64 does not fit in the signed
    /// 64-bit integer the API returns, so the control plane sends `Int64.max` —
    /// and `Int` addition traps on overflow in Swift, so summing it with any
    /// other subnet took the app down with SIGTRAP the moment the overview drew.
    ///
    /// Every other test here used small numbers, which is exactly why none of
    /// them caught it.
    @Test("A clamped IPv6 total does not overflow the sum")
    func clampedTotalDoesNotTrap() {
        let utilisation = OverviewModel.IPAMTotals.weightedUtilisation([
            (allocated: 1, total: Int.max),
            (allocated: 128, total: 256),
            (allocated: 4, total: 16),
        ])
        #expect(utilisation >= 0)
        #expect(utilisation <= 100)
    }

    @Test("Summing many clamped totals still doesn't overflow")
    func manyClampedTotals() {
        let subnets = Array(repeating: (allocated: Int.max, total: Int.max), count: 64)
        let utilisation = OverviewModel.IPAMTotals.weightedUtilisation(subnets)
        #expect(utilisation <= 100)
        #expect(!utilisation.isNaN)
    }

    // Allocated can never exceed total in practice, but floating-point
    // accumulation over clamped values must not be able to report 104% used.
    @Test("Utilisation is capped at 100%")
    func cappedAtFull() {
        let utilisation = OverviewModel.IPAMTotals.weightedUtilisation([
            (allocated: 500, total: 256)
        ])
        #expect(utilisation == 100)
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
