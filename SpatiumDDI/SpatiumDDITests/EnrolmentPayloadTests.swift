//
//  EnrolmentPayloadTests.swift
//  SpatiumDDITests
//

import Foundation
import Testing

@testable import SpatiumDDI

struct EnrolmentPayloadTests {
    private let sampleHex = "52C1AA16D6B4053D86DCD096F12BA5028EA2226CDB990CE73C6896771FFB3A48"

    @Test("A bare API token is accepted on its own")
    func bareToken() throws {
        let payload = try EnrolmentPayload.parse("sddi_9f2c41aa7b3e4d5081c6")
        #expect(payload.token == "sddi_9f2c41aa7b3e4d5081c6")
        #expect(payload.address == nil)
        #expect(payload.certificateFingerprint == nil)
    }

    @Test("Surrounding whitespace from a scan is tolerated")
    func tokenWhitespace() throws {
        #expect(try EnrolmentPayload.parse("  sddi_abc \n").token == "sddi_abc")
    }

    @Test("A full enrolment URI carries server, token and fingerprint")
    func fullURI() throws {
        let uri =
            "spatiumddi://enrol?host=ddi.internal.example&port=8443&token=sddi_abc&fingerprint=\(sampleHex)"
        let payload = try EnrolmentPayload.parse(uri)

        #expect(payload.address == ServerAddress(host: "ddi.internal.example", port: 8443))
        #expect(payload.token == "sddi_abc")
        #expect(payload.certificateFingerprint == EnrolmentPayload.fingerprintData(from: sampleHex))
        #expect(payload.certificateFingerprint?.count == 32)
    }

    @Test("A colon-separated fingerprint parses identically to a bare one")
    func fingerprintWithColons() throws {
        let colons = stride(from: 0, to: sampleHex.count, by: 2)
            .map { offset -> String in
                let start = sampleHex.index(sampleHex.startIndex, offsetBy: offset)
                return String(sampleHex[start..<sampleHex.index(start, offsetBy: 2)])
            }
            .joined(separator: ":")

        #expect(
            EnrolmentPayload.fingerprintData(from: colons)
                == EnrolmentPayload.fingerprintData(from: sampleHex))
    }

    @Test("A server-only code configures the address without a token")
    func serverOnly() throws {
        let payload = try EnrolmentPayload.parse("spatiumddi://enrol?host=192.168.10.4&port=8443")
        #expect(payload.address?.host == "192.168.10.4")
        #expect(payload.token == nil)
    }

    @Test("A code cannot downgrade the connection to HTTP")
    func codeCannotDowngrade() {
        // The guarantee is unchanged — a code can never produce a plaintext
        // connection — but it is now kept by refusing rather than by silently
        // reading `scheme=http` as HTTPS. Coercing it meant an operator who
        // scanned their HTTP lab's code got an HTTPS attempt that failed with a
        // connection error naming nothing useful; this says what is wrong.
        #expect(throws: EnrolmentPayload.ParseError.insecureScheme("http")) {
            try EnrolmentPayload.parse(
                "spatiumddi://enrol?host=lab.internal&scheme=http&token=sddi_x")
        }
    }

    @Test(
        "Codes that aren't ours are rejected",
        arguments: [
            "",
            "   ",
            "https://example.com/enrol?token=sddi_abc",
            "otpauth://totp/example",
            "spatiumddi://something-else?token=sddi_abc",
            "just some text",
        ])
    func rejectsForeignCodes(_ raw: String) {
        #expect(throws: EnrolmentPayload.ParseError.self) {
            try EnrolmentPayload.parse(raw)
        }
    }

    @Test("A code naming neither server nor token configures nothing, so is rejected")
    func emptyURI() {
        #expect(throws: EnrolmentPayload.ParseError.unrecognised) {
            try EnrolmentPayload.parse("spatiumddi://enrol?foo=bar")
        }
    }

    @Test(
        "A malformed fingerprint is rejected rather than silently dropped",
        arguments: [
            "abcd", "zz" + String(repeating: "0", count: 62), String(repeating: "0", count: 63),
        ])
    func rejectsBadFingerprint(_ value: String) {
        #expect(throws: EnrolmentPayload.ParseError.badFingerprint) {
            try EnrolmentPayload.parse("spatiumddi://enrol?token=sddi_a&fingerprint=\(value)")
        }
    }

    // The upstream contract documents `scheme` as "https assumed; http must be
    // explicit". Ignoring it would turn a code for an HTTP lab into a silent
    // HTTPS attempt that fails with a connection error naming nothing useful.
    @Test("An explicitly non-HTTPS code is refused by name")
    func refusesInsecureScheme() {
        #expect(throws: EnrolmentPayload.ParseError.insecureScheme("http")) {
            try EnrolmentPayload.parse("spatiumddi://enrol?host=ddi.lab&scheme=http&token=sddi_abc")
        }
    }

    @Test("An explicit https scheme is accepted")
    func acceptsExplicitHTTPS() throws {
        let payload = try EnrolmentPayload.parse(
            "spatiumddi://enrol?host=ddi.lab&scheme=https&token=sddi_abc"
        )
        #expect(payload.address?.host == "ddi.lab")
        #expect(payload.token == "sddi_abc")
    }

    @Test("A code carrying server, token and fingerprint configures all three")
    func fullEnrolmentCode() throws {
        let fingerprint = String(repeating: "ab", count: 32)
        let payload = try EnrolmentPayload.parse(
            "spatiumddi://enrol?host=ddi.lab&port=8443&token=sddi_abc&fingerprint=\(fingerprint)"
        )
        #expect(payload.address?.host == "ddi.lab")
        #expect(payload.address?.port == 8443)
        #expect(payload.token == "sddi_abc")
        #expect(payload.certificateFingerprint?.count == 32)
    }
}
