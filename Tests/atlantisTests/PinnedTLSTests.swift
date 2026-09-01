import Foundation
import XCTest
import Network
@testable import Atlantis

final class PinnedTLSTests: XCTestCase {

    func testSha256HexKnownVector() {
        // SHA-256("abc") — canonical NIST vector.
        let digest = PinnedTLS.sha256Hex(Data("abc".utf8))
        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSha256HexEmpty() {
        XCTAssertEqual(PinnedTLS.sha256Hex(Data()),
                       "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testConstantTimeEqual() {
        XCTAssertTrue(PinnedTLS.constantTimeEqual("deadbeef", "deadbeef"))
        XCTAssertFalse(PinnedTLS.constantTimeEqual("deadbeef", "deadbeee"))
        XCTAssertFalse(PinnedTLS.constantTimeEqual("deadbeef", "deadbe"))   // length mismatch
        XCTAssertFalse(PinnedTLS.constantTimeEqual("", "x"))
    }

    // MARK: - Cumulative pin decision

    func testIsVerifiedTrueOnlyWhenTrustValidAndDigestMatches() {
        let leaf = Data("collector-cert-der".utf8)
        let good = PinnedTLS.sha256Hex(leaf)

        // Trust valid + digest matches -> verified.
        XCTAssertTrue(PinnedTLS.isVerified(leafDER: leaf, expectedSha256: good, trustIsValid: true))
    }

    func testIsVerifiedFalseWhenDigestMismatch() {
        let leaf = Data("collector-cert-der".utf8)
        let wrong = PinnedTLS.sha256Hex(Data("some-other-cert".utf8))
        // Even with a valid trust chain, a bad pin (wrong digest) must fail.
        XCTAssertFalse(PinnedTLS.isVerified(leafDER: leaf, expectedSha256: wrong, trustIsValid: true))
    }

    func testIsVerifiedFalseWhenTrustInvalid() {
        let leaf = Data("collector-cert-der".utf8)
        let good = PinnedTLS.sha256Hex(leaf)
        // A failed anchor/hostname/validity evaluation must fail regardless of digest.
        XCTAssertFalse(PinnedTLS.isVerified(leafDER: leaf, expectedSha256: good, trustIsValid: false))
    }

    func testIsVerifiedIsCaseInsensitiveOnExpectedDigest() {
        let leaf = Data("collector-cert-der".utf8)
        let upper = PinnedTLS.sha256Hex(leaf).uppercased()
        XCTAssertTrue(PinnedTLS.isVerified(leafDER: leaf, expectedSha256: upper, trustIsValid: true))
    }

    func testMakeParametersBuildsTLSParameters() {
        let tls = CollectorTLS(certificateDER: Data([0x30, 0x82, 0x01]), certificateSha256: String(repeating: "a", count: 64))
        let params = PinnedTLS.makeParameters(host: "192.168.1.42", tls: tls)
        // A TLS protocol option must be present at the top of the stack.
        XCTAssertTrue(params.defaultProtocolStack.applicationProtocols.contains { $0 is NWProtocolTLS.Options })
    }
}
