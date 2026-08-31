//
//  Configuration.swift
//  atlantis
//
//  Created by Nghia Tran on 10/23/20.
//  Copyright © 2020 Proxyman. All rights reserved.
//

import Foundation

struct Configuration {

    /// Default Proxyman port, shared by Bonjour discovery and the manual direct connection.
    static let defaultPort: UInt16 = 10909

    let projectName: String
    let deviceName: String
    let id: String
    let hostName: String?

    /// When set, Atlantis skips Bonjour discovery and connects straight to this host over TCP.
    /// It's the plan-B path for physical devices where Bonjour multicast is unavailable.
    let host: String?

    /// TCP port for the manual direct connection. Ignored when `host` is nil.
    let port: UInt16

    /// Optional shared secret sent at the root of the ConnectionPackage handshake.
    /// The official Proxyman app ignores it; a hardened collector can require it.
    let passcode: String?

    /// When set, the manual connection is made over pinned TLS (collector v2) and the
    /// transport waits for the server's `ready` control frame before replaying. `nil`
    /// keeps the legacy plaintext Proxyman behaviour (no ACK expected).
    let tls: CollectorTLS?

    /// Capture memory limits for the hardened path. `nil` on the legacy overloads,
    /// which keep their historical, larger ceilings untouched.
    let limits: CaptureLimits?

    /// Endpoints whose traffic must never be captured (typically the collector's own
    /// ingest ports, so Atlantis does not record its own uploads).
    let excludedEndpoints: [CaptureEndpoint]

    static func `default`(hostName: String? = nil, passcode: String? = nil) -> Configuration {
        let project = Project.current
        let deviceName = Device.current
        return Configuration(projectName: project.name,
                             deviceName: deviceName.name,
                             hostName: hostName,
                             host: nil,
                             port: Configuration.defaultPort,
                             passcode: passcode,
                             tls: nil,
                             limits: nil,
                             excludedEndpoints: [])
    }

    /// Manual configuration that bypasses Bonjour and connects directly to `host:port`.
    static func manual(host: String,
                       port: UInt16 = Configuration.defaultPort,
                       passcode: String? = nil,
                       tls: CollectorTLS? = nil,
                       limits: CaptureLimits? = nil,
                       excludedEndpoints: [CaptureEndpoint] = []) -> Configuration {
        let project = Project.current
        let deviceName = Device.current
        return Configuration(projectName: project.name,
                             deviceName: deviceName.name,
                             hostName: nil,
                             host: host,
                             port: port,
                             passcode: passcode,
                             tls: tls,
                             limits: limits,
                             excludedEndpoints: excludedEndpoints)
    }

    private init(projectName: String,
                 deviceName: String,
                 hostName: String?,
                 host: String?,
                 port: UInt16,
                 passcode: String?,
                 tls: CollectorTLS?,
                 limits: CaptureLimits?,
                 excludedEndpoints: [CaptureEndpoint]) {
        self.projectName = projectName
        self.deviceName = deviceName
        self.hostName = hostName
        self.host = host
        self.port = port
        self.passcode = passcode
        self.tls = tls
        self.limits = limits
        self.excludedEndpoints = excludedEndpoints
        self.id = "\(Project.current.bundleIdentifier)-\(Device.current.model)" // Use this ID to distinguish the message
    }
}
