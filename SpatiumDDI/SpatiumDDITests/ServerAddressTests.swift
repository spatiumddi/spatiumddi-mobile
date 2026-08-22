//
//  ServerAddressTests.swift
//  SpatiumDDITests
//

import Foundation
import Testing

@testable import SpatiumDDI

struct ServerAddressTests {
    @Test("A bare host is assumed to be HTTPS")
    func bareHostDefaultsToHTTPS() throws {
        let address = try ServerAddress.parse("ddi.internal.example")
        #expect(address.scheme == .https)
        #expect(address.host == "ddi.internal.example")
        #expect(address.port == nil)
        #expect(address.origin.absoluteString == "https://ddi.internal.example")
    }

    @Test("Non-standard ports survive parsing and appear in the URL")
    func nonStandardPort() throws {
        let address = try ServerAddress.parse("https://ddi.internal.example:8443")
        #expect(address.port == 8443)
        #expect(address.origin.absoluteString == "https://ddi.internal.example:8443")
        #expect(address.apiBaseURL.absoluteString == "https://ddi.internal.example:8443/api/v1")
        #expect(address.healthURL.absoluteString == "https://ddi.internal.example:8443/health/platform")
    }

    @Test("A default port is not repeated in the URL")
    func defaultPortElided() throws {
        let address = try ServerAddress.parse("https://ddi.internal.example:443")
        #expect(address.origin.absoluteString == "https://ddi.internal.example")
        #expect(address.displayName == "ddi.internal.example")
    }

    @Test("IPv4 literals are accepted")
    func ipv4Literal() throws {
        let address = try ServerAddress.parse("https://192.168.10.4:8443")
        #expect(address.host == "192.168.10.4")
        #expect(address.origin.absoluteString == "https://192.168.10.4:8443")
    }

    @Test("IPv6 literals stay bracketed in the URL but bare in the model")
    func ipv6Literal() throws {
        let address = try ServerAddress.parse("https://[fd00::1]:8443")
        #expect(address.host == "fd00::1")
        #expect(address.origin.absoluteString == "https://[fd00::1]:8443")
        #expect(address.pinKey == "https://[fd00::1]:8443")
    }

    @Test("HTTP is honoured when spelled out, and flagged")
    func explicitHTTP() throws {
        let address = try ServerAddress.parse("http://ddi.lab.internal")
        #expect(address.scheme == .http)
        #expect(address.isInsecureTransport)
    }

    @Test("A downgrade is never inferred from a bare host")
    func noImplicitDowngrade() throws {
        #expect(try ServerAddress.parse("ddi.lab.internal").isInsecureTransport == false)
    }

    @Test("A pasted deep link reduces to its origin")
    func pathIsDiscarded() throws {
        let address = try ServerAddress.parse("https://ddi.internal.example/ui/dashboard?tab=ipam")
        #expect(address.origin.absoluteString == "https://ddi.internal.example")
    }

    @Test("Surrounding whitespace is tolerated")
    func trimsWhitespace() throws {
        #expect(try ServerAddress.parse("  ddi.internal.example \n").host == "ddi.internal.example")
    }

    @Test("Two ports on one host are different trust peers")
    func pinKeyDistinguishesPorts() throws {
        let a = try ServerAddress.parse("https://ddi.internal.example:8443")
        let b = try ServerAddress.parse("https://ddi.internal.example:9443")
        #expect(a.pinKey != b.pinKey)
    }

    @Test(
        "Bad input is rejected",
        arguments: [
            "", "   ",
            "ftp://ddi.internal.example",
            "https://",
        ])
    func rejectsBadInput(_ input: String) {
        #expect(throws: ServerAddress.ParseError.self) {
            try ServerAddress.parse(input)
        }
    }
}

struct CertificateInfoFormattingTests {
    private let sample = CertificateInfo(
        fingerprint: Data([0x52, 0xC1, 0xAA, 0x16, 0xD6, 0xB4, 0x05, 0x3D]),
        subjectSummary: "ddi.lab.test", chainLength: 1, requestedHost: "localhost"
    )

    @Test("Fingerprints print in the form openssl reports")
    func fingerprintHexMatchesOpenSSLForm() {
        #expect(sample.fingerprintHex == "52:C1:AA:16:D6:B4:05:3D")
    }

    @Test("Fingerprints group into scannable runs without losing digits")
    func groupsPreserveAllDigits() {
        #expect(sample.fingerprintGroups == ["52:C1:AA:16", "D6:B4:05:3D"])
        let rejoined = sample.fingerprintGroups.joined(separator: ":")
        #expect(rejoined == sample.fingerprintHex)
    }
}
