//
//  Transporter.swift
//  atlantis-iOS
//
//  Created by Nghia Tran on 10/23/20.
//  Copyright © 2020 Proxyman. All rights reserved.
//

import Foundation
import Network

#if os(iOS)
import UIKit
#endif

protocol Transporter {

    func start(_ config: Configuration)
    func stop()
    func send(package: Serializable)
}

protocol Serializable {

    func toData() -> Data?
}

extension Serializable {

    func toCompressedData() -> Data? {
        guard let rawData = self.toData() else { return nil }

        // Compress data by gzip
        // Fallback to raw data if it's unsuccess
        return rawData.gzip() ?? rawData
    }
}

final class NetServiceTransport: NSObject {

    struct Constants {
        static let netServiceType = "_Proxyman._tcp"
        static let netServiceDomain = ""
        static let directConnectionPort: NWEndpoint.Port = 10909 // Port for direct simulator connection
    }

    // MARK: - Variables

    // For some reason, Stream Task could send a big file
    // https://github.com/ProxymanApp/atlantis/issues/57
    static let MaximumSizePackage = 52428800 // 50Mb

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.proxyman.atlantis.netservices") // Serial queue for thread safety
    private var pendingPackages: [Serializable] = []
    private var config: Configuration?

    // Multiple task connection support using NWConnection
    private var connections: [NWConnection] = []

    // The maximum number of pending item to prevent Atlantis consumes too much RAM
    private let maxPendingItem = 50

    // Retry mechanism for simulator direct connection
    private var simulatorRetryCount = 0
    private let maxSimulatorRetries = 5

    // Manual/TLS direct connection core (host != nil). Owns its own reconnect,
    // ready-gate and offline queue; the Bonjour/simulator paths above are untouched.
    private lazy var manualCore = ManualTransportCore(
        factory: NWConnectionFactory(queue: queue),
        retry: RetryController(clock: QueueClock(queue: queue)),
        limits: .qa)
    private var isManualMode = false

    // MARK: - Init

    override init() {
        super.init()
        initNotification()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        stop() // Ensure browser and connections are cleaned up
    }
}

// MARK: - Transporter

extension NetServiceTransport: Transporter {

    func start(_ config: Configuration) {
        self.config = config

        queue.async {[weak self] in
            guard let strongSelf = self else { return }

            // Reset all current connections and browser if needed
            strongSelf.stopInternal()

            // Manual direct connection: skip Bonjour entirely and connect
            // straight to the configured host:port (plain TCP, or pinned TLS in
            // collector v2). Delegated to ManualTransportCore, which owns reconnect,
            // the v2 ready-gate and the offline queue. It never falls back to
            // localhost — the simulator path below is the only localhost user.
            if let host = config.host {
                let mode = config.tls == nil ? "TCP" : "pinned TLS"
                print("⚡️[Atlantis] Connecting directly to \(host):\(config.port) over \(mode) (manual mode, Bonjour disabled)...")
                strongSelf.isManualMode = true
                strongSelf.manualCore.start(config)
                return
            }
            strongSelf.isManualMode = false

            #if targetEnvironment(simulator)
            // iOS Simulator: Direct TCP connection
            let endpoint = strongSelf.getEndpointForLocalhost()

            // Reset retry count before starting
            strongSelf.simulatorRetryCount = 0
            print("⚡️[Atlantis][Simulator] Attempting direct connection to Proxyman app on your Mac... without using Bonjour service (due to macOS 15.4+ issue)")
            let connection = NWConnection(to: endpoint, using: .tcp)
            strongSelf.setupAndStartConnection(connection)

            #else
            // iOS Real Device: Use Bonjour Browsing
            if let hostName = config.hostName {
                print("⚡️[Atlantis] Looking for Proxyman app with name \"\(hostName)\" by using Bonjour service on the local network...")
            } else {
                print("⚡️[Atlantis] Looking for Proxyman app using Bonjour service on the local network...")
            }
            strongSelf.startBrowsing()
            #endif
        }
    }

    func stop() {
        queue.async {[weak self] in
            guard let strongSelf = self else { return }
            strongSelf.stopInternal()
        }
    }

    func send(package: Serializable) {
        queue.async {[weak self] in
            guard let strongSelf = self else { return }

            // Manual/TLS mode owns its own queue, ready-gate and framing.
            if strongSelf.isManualMode {
                if let compressed = package.toCompressedData() {
                    strongSelf.manualCore.send(payload: compressed)
                }
                return
            }

            // Ensure we have at least one ready connection
            guard strongSelf.connections.contains(where: { $0.state == .ready }) else {
                // If no connection is ready, append to pending list
                strongSelf.appendToPendingList(package)
                return
            }

            // Send to all ready connections
            strongSelf.streamToAllReadyConnections(package: package)
        }
    }

    private func streamToAllReadyConnections(package: Serializable) {
        // Compress data by gzip
        guard let compressedData = package.toCompressedData() else { return }

        // Send to all *ready* connections
        for connection in connections where connection.state == .ready {
            send(connection: connection, data: compressedData)
        }
    }

    private func send(connection: NWConnection, data: Data) {
        guard connection.state == .ready else {
            print("[\(connection.endpoint.debugDescription)] ⚠️ Attempted to send data on a non-ready connection. State: \(connection.state)")
            return
        }

        // Compose a message
        // [1]: the length of the second message. We reserver 8 bytes to store this data
        // [2]: The actual message

        // 1. Send length of the message first
        let headerData = NSMutableData()
        var lengthPackage = UInt64(data.count) // Use UInt64 for length
        headerData.append(&lengthPackage, length: MemoryLayout<UInt64>.size)

        // Send the length header, must use isComplete = false
        connection.send(content: headerData as Data, isComplete: false, completion: .contentProcessed({ error in
            if let error = error {
                print("[\(connection.endpoint.debugDescription)][Error] Error sending frame header: \(error)")
            }
        }))

        // 2. send the actual message
        connection.send(content: data, completion: .contentProcessed({ error in
            if let error = error {
                print("[\(connection.endpoint.debugDescription)][Error] Error sending frame content: \(error)")
            }
        }))
    }

    private func appendToPendingList(_ package: Serializable) {
        // Remove oldest items if limit exceeded (FIFO approach)
        while pendingPackages.count >= maxPendingItem {
            pendingPackages.removeFirst()
        }
        pendingPackages.append(package)
    }

    private func flushAllPendingPackagesIfNeed() {
        guard !pendingPackages.isEmpty else { return }
        print("[Atlantis] Flushing \(pendingPackages.count) pending items...")
        let packagesToFlush = pendingPackages // Copy packages
        pendingPackages.removeAll() // Clear immediately
        for package in packagesToFlush {
            streamToAllReadyConnections(package: package) // Stream copies
        }
    }
}

// MARK: - Private Connection & Browsing Logic (on queue)

extension NetServiceTransport {

    private func startBrowsing() {
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Constants.netServiceType, domain: Constants.netServiceDomain), using: parameters)

        browser.stateUpdateHandler = {[weak self] newState in
            guard let strongSelf = self else { return }
            switch newState {
            case .failed(let error):
                print("[Atlantis][Error] Bonjour Browser failed: \(error). Ensure network permissions and Bonjour service are correct.")
                // Consider implementing retry logic here if desired
                browser.cancel() // Cancel the failed browser
                if strongSelf.browser === browser { // Ensure we are cancelling the current browser
                    strongSelf.browser = nil
                }
            case .ready:
                print("[Atlantis] Bonjour Browser is ready and scanning.")
            case .cancelled:
                print("[Atlantis] Bonjour Browser cancelled.")
                if strongSelf.browser === browser { // Ensure we are cancelling the current browser
                    strongSelf.browser = nil
                }
            case .waiting(let error):

                switch error {
                case .dns(let code):
                    switch Int(code) {
                    case kDNSServiceErr_PolicyDenied:
                        #if targetEnvironment(simulator)
                        print("--------------------------------")
                        print("❌[Atlantis][Error] Bonjour service failed with PolicyDenied (kDNSServiceErr_PolicyDenied). This might be related to a known issue on macOS 15.4+ with iOS Simulators.")
                        print("✅ [Atlantis] Suggested Solutions:")
                        print("[Atlantis] 1. Use Atlantis on a real iOS device.")
                        print("[Atlantis] OR")
                        print("[Atlantis] 2. Don't use Atlantis on iOS Simulator, and use normal Proxy instead. Open Proxyman on macOS -> Certificate menu -> Install certificate on iOS -> Simulators -> Follow guide to set up your iOS Simulator.")
                        print("--------------------------------")
                        print("[Atlantis] Github Issue: https://github.com/ProxymanApp/Proxyman/issues/2294")
                        print("--------------------------------")
                        #else
                        print("--------------------------------")
                        print("[Atlantis][Error] Bonjour service failed with PolicyDenied (kDNSServiceErr_PolicyDenied). This could be due to missing Local Network permission for your app.")
                        print("✅ [Atlantis] Suggested Solutions:")
                        print("[Atlantis] 1. Go to iOS Settings -> Privacy & Security -> Local Network -> Find your app -> Turn ON.")
                        print("[Atlantis] OR")
                        print("[Atlantis] 2. Alternatively, try deleting the app from your device and running it again. Click 'Allow' when system asks for Local Network permission.")
                        print("-------------------------------- ")
                        #endif
                    default:
                        print(code)
                    }
                case .posix:
                    break
                case .tls:
                    break
                @unknown default:
                    break
                }
            case .setup:
                break
            @unknown default:
                break
            }
        }

        browser.browseResultsChangedHandler = {[weak self] results, changes in
            guard let strongSelf = self else { return }
            for change in changes {
                switch change {
                case .added(let result):
                    print("[Atlantis] Bonjour discovered: \(NetServiceTransport.hostname(from: result.endpoint) ?? "Unknown")")
                    strongSelf.connectToEndpointIfNeeded(result.endpoint)
                case .removed(let result):
                    print("[Atlantis] Bonjour removed: \(result.endpoint.debugDescription)")
                    strongSelf.disconnectFromEndpoint(result.endpoint)
                case .changed(_, let newResult, _): // Simplified handling
                    // Re-evaluate connection on change
                    print("[Atlantis] Bonjour changed: \(newResult.endpoint.debugDescription)")
                    strongSelf.connectToEndpointIfNeeded(newResult.endpoint)
                default:
                    break
                }
            }
        }

        self.browser = browser
        browser.start(queue: self.queue)
    }

    private func connectToEndpointIfNeeded(_ endpoint: NWEndpoint) {
        // Prevent duplicate connections to the same endpoint
        guard !connections.contains(where: { $0.endpoint == endpoint }) else {
            print("[Atlantis] Already connected or connecting to \(endpoint.debugDescription). Skipping.")
            return
        }

        // Check if we should connect based on hostname configuration
        guard shouldConnectToEndpoint(endpoint) else {
            return // Log message is printed inside shouldConnectToEndpoint
        }

        print("[Atlantis] ✅ Attempting to connect to \(endpoint.debugDescription)")
        let connection = NWConnection(to: endpoint, using: .tcp)
        setupAndStartConnection(connection)
    }

    private func disconnectFromEndpoint(_ endpoint: NWEndpoint) {
        let connectionsToRemove = connections.filter { $0.endpoint == endpoint }
        connectionsToRemove.forEach { $0.cancel() }
        connections.removeAll { $0.endpoint == endpoint }
        if !connectionsToRemove.isEmpty {
            print("[Atlantis] Disconnected from \(endpoint.debugDescription)")
        }
    }

    private func setupAndStartConnection(_ connection: NWConnection) {
        connections.append(connection)
        setupConnectionStateHandler(connection)
        connection.start(queue: queue)
    }

    private func setupConnectionStateHandler(_ connection: NWConnection) {
        connection.stateUpdateHandler = {[weak self] (newState) in
            guard let strongSelf = self else { return }

            let endpointDesc = connection.endpoint.debugDescription // Capture for logging

            switch newState {
            case .setup:
                break
            case .preparing:
                break
            case .ready:
                print("[\(endpointDesc)] ✅ Connection established.")
                // Send initial connection info and flush pending
                #if targetEnvironment(simulator)
                // Reset retry counter on successful simulator connection
                strongSelf.simulatorRetryCount = 0
                #endif
                strongSelf.sendConnectionPackage(connection: connection)
                strongSelf.flushAllPendingPackagesIfNeed()
            case .waiting(let error):
                #if targetEnvironment(simulator)
                // For simulator, attempt to retry the connection after a delay
                // instead of just printing the waiting state.

                // Cancel the current connection attempt
                connection.cancel()

                // Remove the connection immediately to allow retry
                if let index = strongSelf.connections.firstIndex(where: { $0 === connection }) {
                    strongSelf.connections.remove(at: index)
                }

                // Check retry limit
                if strongSelf.simulatorRetryCount < strongSelf.maxSimulatorRetries {
                    strongSelf.simulatorRetryCount += 1
                    let currentRetry = strongSelf.simulatorRetryCount
                    let maxRetries = strongSelf.maxSimulatorRetries
                    print("Could not found Proxyman app on your Mac.")
                    print("🔄 Attempting re-connect (\(currentRetry)/\(maxRetries)) to Proxyman app in 15 seconds... Make sure Proxyman app is running on your Mac.")

                    // Schedule a retry
                    strongSelf.queue.asyncAfter(deadline: .now() + 15.0) { [weak self] in
                        guard let strongSelf = self else { return }
                        // Re-attempt connection using the original logic
                        let endpoint = strongSelf.getEndpointForLocalhost()
                        let newConnection = NWConnection(to: endpoint, using: .tcp)
                        print("[Atlantis][Simulator] Retry #\(currentRetry): Creating new connection to \(endpoint.debugDescription)")
                        strongSelf.setupAndStartConnection(newConnection) // Start the *new* connection attempt
                    }
                } else {
                    print("❌ [Atlantis][Simulator] Maximum retry limit (\(strongSelf.maxSimulatorRetries)) reached. Stopping connection attempts.")
                }
                #else
                print("[\(endpointDesc)] ⚠️ Connection waiting: \(error).")
                #endif
            case .failed(let error):
                print("[\(endpointDesc)] ❌ Connection failed: \(error).")
                // Remove the failed connection
                strongSelf.connections.removeAll { $0 === connection }
            case .cancelled:
                // Remove the cancelled connection
                strongSelf.connections.removeAll { $0 === connection }
            @unknown default:
                print("[\(endpointDesc)] Unknown connection state.")
                break
            }
        }
    }

    private func sendConnectionPackage(connection: NWConnection) {
        guard let config = config else {
            print("[\(connection.endpoint.debugDescription)][Error] Missing configuration, cannot send connection package.")
            return
        }

        // Create and send the initial connection message
        let connectionMessage = Message.buildConnectionMessage(id: config.id, item: ConnectionPackage(config: config))
        guard let data = connectionMessage.toCompressedData() else {
            print("[\(connection.endpoint.debugDescription)][Error] Could not create connection package data.")
            return
        }
        send(connection: connection, data: data)
    }

    // MARK: - Helper Methods

    // Check if connection should proceed based on configured hostname
    private func shouldConnectToEndpoint(_ endpoint: NWEndpoint) -> Bool {
        // If no specific hostname is configured, always allow connection
        guard let requiredHost = config?.hostName else {
            return true
        }

        // If a hostname is configured, only connect if it matches or contains the required host
        guard let endpointHost = NetServiceTransport.hostname(from: endpoint) else {
            print("[Atlantis] ⚠️ Could not determine hostname for endpoint \(endpoint.debugDescription). Allowing connection attempt.")
            return true // Allow connection if hostname cannot be determined
        }

        // compare
        var lowercasedRequiredHost = requiredHost.lowercased()
        let lowercasedEndpointHost = endpointHost.lowercased()

        // Remove trailing dot from required host if present
        if lowercasedRequiredHost.hasSuffix(".") {
            lowercasedRequiredHost = String(lowercasedRequiredHost.dropLast())
        }

        // Allow connection if the endpoint host *contains* the required host (case-insensitive)
        // This handles cases like required="mac-mini.local" and endpoint="Proxyman-mac-mini.local"
        // or "Proxyman-mac-mini.local" and "mac-mini.local"
        // This is useful for local network discovery where the hostname might vary slightly because Proxyman macOS is stil using old-fashioned BonjourService class.
        // Meanwhile, Atlantis now uses NWBrowser for discovery
        if !lowercasedEndpointHost.contains(lowercasedRequiredHost) {
            print("[Atlantis] ⏭️ Skipping connection to \(endpointHost) (Required host \(requiredHost) not found within endpoint host)")
            return false
        }

        return true
    }

    // Helper to extract hostname string from NWEndpoint
    private class func hostname(from endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case .hostPort(let host, _):
            return "\(host)"
        case .service(let name, _, _, _):
            // Extract hostname from service name (e.g., "MyMac._Proxyman._tcp.local.")
            // This might need refinement based on actual service name formats
            return name
        default:
            return nil
        }
    }

    // Internal stop method to be called on the queue
    private func stopInternal() {
        // Manual/TLS core: release its connection, retry timer and offline queue.
        if isManualMode {
            manualCore.stop()
            isManualMode = false
        }
        browser?.cancel()
        browser = nil
        // Cancel all active connections before removing them
        connections.forEach { $0.cancel() }
        connections.removeAll()
        pendingPackages.removeAll()
        simulatorRetryCount = 0 // Reset retry count on stop
        print("[Atlantis] Transport stopped and connections cleared.") // Added log for clarity
    }
}

// MARK: - Notifications

extension NetServiceTransport {

    private func initNotification() {
        #if os(iOS)
        // Memory Warning notification is only available on iOS
        NotificationCenter.default.addObserver(self, selector: #selector(self.didReceiveMemoryNotification), name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        #endif
    }

    @objc private func didReceiveMemoryNotification() {
        queue.async {[weak self] in
            print("[Atlantis] Received memory warning. Clearing pending packages.")
            self?.pendingPackages.removeAll()
        }
    }

    private func getEndpointForLocalhost() -> NWEndpoint {
        let port = Constants.directConnectionPort
        let host = NWEndpoint.Host("localhost") // Simulators connect to localhost
        let endpoint = NWEndpoint.hostPort(host: host, port: port)
        return endpoint
    }
}

// MARK: - Manual/TLS transport core (injectable, testable)

/// The lifecycle states the core reacts to, abstracted away from `NWConnection` so the
/// reconnect/generation logic can be driven by a fake connection in tests.
enum ChannelState {
    case ready
    case waiting(Error?)
    case failed(Error?)
    case cancelled
}

/// A single connection to the collector. Production wraps `NWConnection` (plain TCP or
/// pinned TLS); tests provide a fake that records endpoints and simulates failures.
protocol ConnectionChannel: AnyObject {
    var stateHandler: ((ChannelState) -> Void)? { get set }
    func start()
    func cancel()
    func send(_ data: Data, isComplete: Bool, completion: @escaping (Error?) -> Void)
    /// Begin delivering inbound framed bytes. `nil` data (or a non-nil error) signals
    /// EOF/read failure.
    func startReceiving(_ handler: @escaping (Data?, Error?) -> Void)
}

/// Creates connections for a host/port, optionally over pinned TLS.
protocol ConnectionFactory {
    func makeConnection(host: String, port: UInt16, tls: CollectorTLS?) -> ConnectionChannel
}

/// Incremental reader for the `[uint64 LE length][payload]` framing. Used only to read
/// the small server control frames; oversize lengths are dropped defensively.
struct FrameReader {
    private var buffer: [UInt8] = []
    private let maxFrame: Int

    init(maxFrame: Int = 8 * 1024 * 1024) { self.maxFrame = maxFrame }

    mutating func reset() { buffer.removeAll(keepingCapacity: false) }
    mutating func append(_ data: Data) { buffer.append(contentsOf: data) }

    mutating func nextFrame() -> Data? {
        guard buffer.count >= 8 else { return nil }
        var len: UInt64 = 0
        for i in 0..<8 { len |= UInt64(buffer[i]) << UInt64(8 * i) }
        if len > UInt64(maxFrame) { reset(); return nil }
        let total = 8 + Int(len)
        guard buffer.count >= total else { return nil }
        let frame = Data(buffer[8..<total])
        buffer.removeFirst(total)
        return frame
    }
}

/// The collector's v2 control frame, sent before replay. Exclusive to authenticated
/// TLS v2; the legacy Proxyman path never emits it.
enum ControlFrame {
    case ready
    case authError

    static func parse(_ frame: Data) -> ControlFrame? {
        let raw = frame.isGzipped ? (frame.gunzip() ?? frame) : frame
        guard let env = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
              (env["messageType"] as? String) == "control",
              let contentB64 = env["content"] as? String,
              let contentData = Data(base64Encoded: contentB64),
              let inner = (try? JSONSerialization.jsonObject(with: contentData)) as? [String: Any],
              let type = inner["type"] as? String else { return nil }
        switch type {
        case "ready": return .ready
        case "auth_error": return .authError
        default: return nil
        }
    }
}

/// Owns the manual/TLS connection lifecycle: connect, send the ConnectionPackage,
/// gate replay on the v2 `ready` control frame, reconnect with generation-guarded
/// backoff, bound the offline queue, and release everything on stop. It holds no
/// direct sockets — connections come from an injected factory and timers from an
/// injected clock — so `TransportLifecycleTests` drives it with fakes.
final class ManualTransportCore {

    private let factory: ConnectionFactory
    private let retry: RetryController
    private let limits: CaptureLimits

    private var isStarted = false
    private var blocked = false            // auth/cert failure: do not reconnect
    private var generation = 0             // monotonic; every callback carries its own
    private var current: ConnectionChannel?
    private var config: Configuration?
    private var readyForReplay = false
    private var frameReader = FrameReader()

    // Offline queue of already-serialized+compressed payloads (no length prefix yet).
    private var pending: [Data] = []
    private var pendingBytes = 0

    init(factory: ConnectionFactory, retry: RetryController, limits: CaptureLimits = .qa) {
        self.factory = factory
        self.retry = retry
        self.limits = limits
    }

    // MARK: Public API (must be called on the owning serial queue)

    func start(_ config: Configuration) {
        isStarted = true
        blocked = false
        self.config = config
        generation += 1
        retry.resetBackoff()
        retry.cancelPending()
        teardownConnection()
        connect()
    }

    func stop() {
        isStarted = false
        generation += 1
        retry.cancelPending()
        teardownConnection()
        pending.removeAll()
        pendingBytes = 0
        readyForReplay = false
    }

    /// Enqueue or send an already-compressed payload. Never replays before the
    /// connection is ready (and, in v2, before the `ready` control frame).
    func send(payload: Data) {
        guard isStarted, !blocked else { return }
        if readyForReplay, let channel = current {
            writeFrame(payload, on: channel)
        } else {
            enqueue(payload)
        }
    }

    // MARK: Connect / reconnect

    private func connect() {
        guard isStarted, !blocked, let config = config, let host = config.host else { return }
        readyForReplay = false
        frameReader.reset()
        let channel = factory.makeConnection(host: host, port: config.port, tls: config.tls)
        current = channel
        // Capture this attempt's generation. Every callback below is fenced by it, so
        // a callback from a superseded attempt (a second disconnect for the same
        // socket, or a late read after teardown) is dropped instead of acting on the
        // freshly-installed connection.
        let g = generation
        channel.stateHandler = { [weak self] state in
            guard let self, self.isStarted, self.generation == g else { return }
            self.handleState(state, channel: channel)
        }
        channel.startReceiving { [weak self] data, error in
            guard let self, self.isStarted, self.generation == g else { return }
            self.handleInbound(data: data, error: error)
        }
        channel.start()
    }

    private func handleState(_ state: ChannelState, channel: ConnectionChannel) {
        switch state {
        case .ready:
            retry.resetBackoff()
            sendConnectionPackage(on: channel)
            // Legacy (no TLS) path expects no control ACK: stream immediately.
            // v2 waits for the `ready` control frame handled in handleInbound.
            if config?.tls == nil {
                markReadyAndFlush()
            }
        case .failed(let error):
            // A pinned-TLS verify-block rejection surfaces as NWError.tls — a permanent
            // pin/cert failure, not a transient network drop. Enter `blocked` (like an
            // auth_error) so a wrong pin does not retry forever.
            if Self.isCertificateFailure(error) {
                enterBlocked()
            } else {
                handleDisconnect()
            }
        case .waiting:
            // NWConnection keeps retrying a waiting connection on its own; nothing to do.
            break
        case .cancelled:
            break
        }
    }

    private func handleInbound(data: Data?, error: Error?) {
        guard let data = data, error == nil else {
            // EOF or read error enters the same reconnect path as a send failure.
            handleDisconnect()
            return
        }
        frameReader.append(data)
        while let frame = frameReader.nextFrame() {
            guard let control = ControlFrame.parse(frame) else { continue }
            switch control {
            case .ready:
                markReadyAndFlush()
            case .authError:
                // Authentication rejected: blocked, no reconnect.
                enterBlocked()
            }
        }
    }

    /// Terminal failure (auth rejected or certificate/pin invalid): stop, do not retry.
    private func enterBlocked() {
        blocked = true
        generation += 1
        retry.cancelPending()
        teardownConnection()
        readyForReplay = false
    }

    /// A transient disconnect. Bumping the generation here invalidates the just-failed
    /// attempt's remaining callbacks, so the state-update and the read-EOF that both
    /// fire for a single disconnect cannot each schedule a retry (which would double
    /// the backoff), and a stale post-teardown read cannot tear down the next attempt.
    private func handleDisconnect() {
        guard isStarted, !blocked else { return }
        generation += 1
        let g = generation
        teardownConnection()
        readyForReplay = false
        retry.scheduleRetry { [weak self] in
            guard let self, self.isStarted, !self.blocked, self.generation == g else { return }
            self.connect()
        }
    }

    /// Whether a connection failure is a TLS/certificate error (permanent) rather than
    /// a transient network error.
    static func isCertificateFailure(_ error: Error?) -> Bool {
        guard let nwError = error as? NWError else { return false }
        if case .tls = nwError { return true }
        return false
    }

    // MARK: Sending

    private func sendConnectionPackage(on channel: ConnectionChannel) {
        guard let config = config else { return }
        let message = Message.buildConnectionMessage(id: config.id, item: ConnectionPackage(config: config))
        guard let data = message.toCompressedData() else { return }
        writeFrame(data, on: channel)
    }

    private func markReadyAndFlush() {
        guard let channel = current else { return }
        readyForReplay = true
        let toFlush = pending
        pending.removeAll()
        pendingBytes = 0
        for payload in toFlush { writeFrame(payload, on: channel) }
    }

    private func writeFrame(_ payload: Data, on channel: ConnectionChannel) {
        var len = UInt64(payload.count).littleEndian
        let header = Data(bytes: &len, count: MemoryLayout<UInt64>.size)
        let g = generation
        channel.send(header, isComplete: false) { _ in }
        channel.send(payload, isComplete: true) { [weak self] error in
            guard let self, self.isStarted, self.generation == g else { return }
            if error != nil { self.handleDisconnect() }
        }
    }

    private func enqueue(_ payload: Data) {
        pending.append(payload)
        pendingBytes += payload.count
        // Enforce both budgets, dropping oldest first.
        while (pending.count > limits.maxPendingPackages || pendingBytes > limits.maxPendingBytes),
              !pending.isEmpty {
            let removed = pending.removeFirst()
            pendingBytes -= removed.count
        }
    }

    private func teardownConnection() {
        current?.stateHandler = nil
        current?.cancel()
        current = nil
        frameReader.reset()
    }

    // MARK: - Test hooks
    #if DEBUG
    var test_isReadyForReplay: Bool { readyForReplay }
    var test_isBlocked: Bool { blocked }
    var test_pendingCount: Int { pending.count }
    var test_pendingBytes: Int { pendingBytes }
    var test_generation: Int { generation }
    var test_retryAttempt: Int { retry.attempt }
    #endif
}

// MARK: - Production NWConnection-backed factory

/// Real connections: plain TCP for the legacy Proxyman path, pinned TLS for v2.
final class NWConnectionFactory: ConnectionFactory {
    private let queue: DispatchQueue
    init(queue: DispatchQueue) { self.queue = queue }

    func makeConnection(host: String, port: UInt16, tls: CollectorTLS?) -> ConnectionChannel {
        let nwPort = NWEndpoint.Port(rawValue: port) ?? NetServiceTransport.Constants.directConnectionPort
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let parameters: NWParameters = tls.map { PinnedTLS.makeParameters(host: host, tls: $0) } ?? .tcp
        let connection = NWConnection(to: endpoint, using: parameters)
        return NWConnectionChannel(connection: connection, queue: queue)
    }
}

/// Adapts a single `NWConnection` to `ConnectionChannel`.
final class NWConnectionChannel: ConnectionChannel {
    private let connection: NWConnection
    private let queue: DispatchQueue
    var stateHandler: ((ChannelState) -> Void)?
    private var inboundHandler: ((Data?, Error?) -> Void)?
    private var isCancelled = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.stateHandler?(.ready)
            case .failed(let e): self?.stateHandler?(.failed(e))
            case .waiting(let e): self?.stateHandler?(.waiting(e))
            case .cancelled: self?.stateHandler?(.cancelled)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        isCancelled = true
        // Drop BOTH handlers so no state-update or in-flight read callback can fire
        // after cancel and act on behalf of a superseded connection.
        connection.stateUpdateHandler = nil
        inboundHandler = nil
        connection.cancel()
    }

    func send(_ data: Data, isComplete: Bool, completion: @escaping (Error?) -> Void) {
        connection.send(content: data, isComplete: isComplete, completion: .contentProcessed({ error in
            completion(error)
        }))
    }

    func startReceiving(_ handler: @escaping (Data?, Error?) -> Void) {
        inboundHandler = handler
        receiveLoop()
    }

    private func receiveLoop() {
        guard !isCancelled else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.isCancelled, let handler = self.inboundHandler else { return }
            if let data = data, !data.isEmpty { handler(data, nil) }
            if let error = error { handler(nil, error); return }
            if isComplete { handler(nil, nil); return }
            self.receiveLoop()
        }
    }
}

#if DEBUG
// Helper for logging endpoint descriptions
extension NWEndpoint {
    var debugDescription: String {
        switch self {
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        case .service(let name, let type, let domain, _):
            return "\(name).\(type).\(domain)"
        case .unix(let path):
            return "unix:\(path)"
        case .url(let url):
            return url.absoluteString
        case .opaque:
            return "opaque"
        @unknown default:
            return "UnknownEndpoint"
        }
    }
}
#endif
