//
//  LenientDateTranscoderTests.swift
//  SpatiumAPITests
//

import Foundation
import Testing

@testable import SpatiumAPI

struct LenientDateTranscoderTests {
    private let transcoder = LenientDateTranscoder()

    @Test("Microsecond timestamps decode — the shape this server actually sends")
    func microseconds() throws {
        let date = try transcoder.decode("2026-05-14T21:59:10.586198Z")
        // Truncated to milliseconds, so .586 not .586198.
        #expect(abs(date.timeIntervalSince1970 - 1_778_795_950.586) < 0.001)
    }

    @Test(
        "Fractional precision is normalised, not rejected",
        arguments: [
            "2026-05-14T21:59:10.5Z",
            "2026-05-14T21:59:10.58Z",
            "2026-05-14T21:59:10.586Z",
            "2026-05-14T21:59:10.586198Z",
            "2026-05-14T21:59:10.586198123Z",
        ])
    func varyingPrecision(_ stamp: String) throws {
        _ = try transcoder.decode(stamp)
    }

    @Test("Timestamps without a fraction still decode")
    func noFraction() throws {
        let date = try transcoder.decode("2026-05-14T21:59:10Z")
        #expect(date.timeIntervalSince1970 == 1_778_795_950)
    }

    @Test("Non-UTC offsets decode")
    func offset() throws {
        let utc = try transcoder.decode("2026-05-14T21:59:10Z")
        let offset = try transcoder.decode("2026-05-14T23:59:10+02:00")
        #expect(utc == offset)
    }

    @Test("A round trip through encode survives decode")
    func roundTrip() throws {
        let original = Date(timeIntervalSince1970: 1_778_795_950.586)
        let decoded = try transcoder.decode(try transcoder.encode(original))
        #expect(abs(decoded.timeIntervalSince1970 - original.timeIntervalSince1970) < 0.001)
    }

    @Test(
        "Rubbish is reported rather than silently becoming a date",
        arguments: [
            "", "not a date", "2026-13-45T99:99:99Z",
        ])
    func rejectsGarbage(_ value: String) {
        #expect(throws: (any Error).self) { try transcoder.decode(value) }
    }

    @Test("Fraction normalisation pads and truncates to three digits")
    func normalisation() {
        #expect(LenientDateTranscoder.normaliseFraction(in: "…10.5Z") == "…10.500Z")
        #expect(LenientDateTranscoder.normaliseFraction(in: "…10.586198Z") == "…10.586Z")
        #expect(LenientDateTranscoder.normaliseFraction(in: "…10.586Z") == "…10.586Z")
        #expect(LenientDateTranscoder.normaliseFraction(in: "…10Z") == "…10Z")
    }
}
