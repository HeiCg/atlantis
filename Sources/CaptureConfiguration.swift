//
//  CaptureConfiguration.swift
//  atlantis
//
//  Public value types for the hardened NetCapture collector path: pinned-TLS
//  material, capture memory limits, and excluded endpoints. These are additive —
//  the legacy Bonjour/Proxyman API keeps its own defaults and never sees them.
//

import Foundation

/// Pinned certificate material for the collector's Atlantis TLS ingest (v2).
///
/// The device connects over TLS and trusts *only* this certificate as its anchor:
/// no system trust store, no downgrade. The DER is the exclusive anchor; the
/// SHA-256 (lowercase hex of the DER) is verified cumulatively with the anchor,
/// hostname/SAN and temporal validity.
public struct CollectorTLS: Equatable {

    /// DER-encoded certificate to pin as the exclusive trust anchor.
    public let certificateDER: Data

    /// Lowercase hex SHA-256 of `certificateDER` (64 chars), as published by the
    /// collector's pairing payload (`certificateSha256`).
    public let certificateSha256: String

    public init(certificateDER: Data, certificateSha256: String) {
        self.certificateDER = certificateDER
        self.certificateSha256 = certificateSha256.lowercased()
    }
}

/// Upper bounds on how much captured traffic Atlantis retains in memory before it
/// starts omitting content. Bodies past the limit are dropped but their known size
/// is preserved (`bodyWasOmitted` / `retainedBodyBytes`); the app's own stream is
/// never disturbed.
public struct CaptureLimits: Equatable {

    /// Max retained bytes for a single request or response body.
    public let maxBodyBytes: Int

    /// Max total bytes buffered in the transport's offline pending queue.
    public let maxPendingBytes: Int

    /// Max number of packages buffered in the transport's offline pending queue.
    public let maxPendingPackages: Int

    public init(maxBodyBytes: Int, maxPendingBytes: Int, maxPendingPackages: Int) {
        self.maxBodyBytes = maxBodyBytes
        self.maxPendingBytes = maxPendingBytes
        self.maxPendingPackages = maxPendingPackages
    }

    /// QA defaults for the hardened app: 1 MiB per body, 8 MiB / 50 packages pending.
    public static let qa = CaptureLimits(maxBodyBytes: 1 * 1024 * 1024,
                                         maxPendingBytes: 8 * 1024 * 1024,
                                         maxPendingPackages: 50)
}

/// A host:port pair whose traffic must never be captured — typically the collector's
/// own ingest endpoints, so Atlantis does not record its own uploads.
public struct CaptureEndpoint: Equatable {

    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}
