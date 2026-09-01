//
//  PinnedTLS.swift
//  atlantis
//
//  Certificate-pinned TLS parameters for the collector Atlantis ingest (v2).
//
//  The device trusts exactly one certificate — the collector's — as its anchor.
//  There is no system trust store fallback and no downgrade. Verification is
//  cumulative: the pinned cert must be the exclusive anchor, the hostname/SAN must
//  match, the certificate must be temporally valid, and its DER SHA-256 must equal
//  the pinned digest. The security verify completion is invoked exactly once on
//  every code path.
//

import Foundation
import Network
import Security
import CryptoKit

enum PinnedTLS {

    /// Lowercase hex SHA-256 of the given bytes.
    static func sha256Hex(_ data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time string compare, to avoid leaking digest match position via timing.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }

    /// Cumulative pin decision given the platform-evaluated inputs. Every check must
    /// hold: the exclusive-anchor SecTrust evaluation must have succeeded (which also
    /// enforces hostname/SAN and temporal validity), and the leaf DER digest must
    /// equal the pinned digest. Kept pure so the AND-of-all-checks is unit-testable
    /// without a live TLS handshake.
    static func isVerified(leafDER: Data, expectedSha256: String, trustIsValid: Bool) -> Bool {
        guard trustIsValid else { return false }
        return constantTimeEqual(sha256Hex(leafDER), expectedSha256.lowercased())
    }

    /// Build `NWParameters` for a pinned-TLS connection to `host`. TLS 1.2 minimum
    /// (TLS 1.3 allowed). The pinned certificate is installed as the exclusive anchor;
    /// hostname/SAN and temporal validity are enforced by an SSL policy + SecTrust
    /// evaluation; the DER digest is compared last.
    static func makeParameters(host: String, tls: CollectorTLS) -> NWParameters {
        let tlsOptions = NWProtocolTLS.Options()
        let sec = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)

        let verifyQueue = DispatchQueue(label: "com.proxyman.atlantis.tls.verify")
        sec_protocol_options_set_verify_block(sec, { (_, secTrustRef, completion) in
            let trust = sec_trust_copy_ref(secTrustRef).takeRetainedValue()

            // Exclusive anchor: trust ONLY the pinned collector certificate.
            guard let anchor = SecCertificateCreateWithData(nil, tls.certificateDER as CFData) else {
                completion(false); return
            }
            SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)

            // Hostname/SAN + temporal validity via an SSL policy bound to this host.
            let policy = SecPolicyCreateSSL(true, host as CFString)
            SecTrustSetPolicies(trust, policy)

            var error: CFError?
            let trustValid = SecTrustEvaluateWithError(trust, &error)

            // Leaf DER digest must equal the pinned digest (cumulative with the above).
            let leaf = Self.leafCertificate(of: trust)
            var digestOK = false
            if let leaf = leaf {
                let leafDER = SecCertificateCopyData(leaf) as Data
                digestOK = isVerified(leafDER: leafDER, expectedSha256: tls.certificateSha256, trustIsValid: trustValid)
            }
            completion(digestOK)
        }, verifyQueue)

        return NWParameters(tls: tlsOptions)
    }

    private static func leafCertificate(of trust: SecTrust) -> SecCertificate? {
        if #available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, visionOS 1.0, *) {
            return (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        } else {
            return SecTrustGetCertificateAtIndex(trust, 0)
        }
    }
}
