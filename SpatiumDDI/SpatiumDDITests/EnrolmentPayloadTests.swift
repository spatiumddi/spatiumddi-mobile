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
    func codeCannotDowngrade() throws {
        // `scheme` is no longer honoured, so a code carrying one is simply
        // parsed as the HTTPS server it names.
        let payload = try EnrolmentPayload.parse(
            "spatiumddi://enrol?host=lab.internal&scheme=http&token=sddi_x")
        #expect(payload.address == ServerAddress(host: "lab.internal", port: nil))
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

}
