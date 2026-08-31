import Foundation
import XCTest
import Network
@testable import Atlantis

// MARK: - Fakes

/// Virtual clock: no real time passes. `advance(by:)` fires every timer whose deadline
/// has elapsed, in scheduled order.
private final class FakeClock: SchedulerClock {
    private var now: TimeInterval = 0
    private struct Job { let token: ClockToken; let fireAt: TimeInterval; let work: () -> Void }
    private var jobs: [Job] = []

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> ClockToken {
        let token = ClockToken()
        jobs.append(Job(token: token, fireAt: now + delay, work: work))
        return token
    }

    func cancel(_ token: ClockToken) {
        jobs.removeAll { $0.token == token }
    }

    func advance(by seconds: TimeInterval) {
        now += seconds
        // Fire due jobs in order; a fired job may schedule another, which is picked up
        // on the next pass if it is already due.
        var progressed = true
        while progressed {
            progressed = false
            guard let idx = jobs.firstIndex(where: { $0.fireAt <= now }) else { break }
            let job = jobs.remove(at: idx)
            job.work()
            progressed = true
        }
    }

    var pendingCount: Int { jobs.count }
}

private final class FakeChannel: ConnectionChannel {
    var stateHandler: ((ChannelState) -> Void)?
    private(set) var started = false
    private(set) var cancelled = false
    private(set) var sentPayloads: [Data] = []
    private var inboundHandler: ((Data?, Error?) -> Void)?

    let host: String
    let port: UInt16
    let tls: CollectorTLS?

    init(host: String, port: UInt16, tls: CollectorTLS?) {
        self.host = host; self.port = port; self.tls = tls
    }

    func start() { started = true }
    func cancel() { cancelled = true }

    func send(_ data: Data, isComplete: Bool, completion: @escaping (Error?) -> Void) {
        // Record only frame payloads (isComplete == true), not the 8-byte headers.
        if isComplete { sentPayloads.append(data) }
        completion(nil)
    }

    func startReceiving(_ handler: @escaping (Data?, Error?) -> Void) {
        inboundHandler = handler
    }

    // Test drivers
    func becomeReady() { stateHandler?(.ready) }
    func fail() { stateHandler?(.failed(NSError(domain: "test", code: 1))) }
    /// Simulate a pinned-TLS verify-block rejection (NWError.tls).
    func failTLS() { stateHandler?(.failed(NWError.tls(-9808))) }
    func deliverInbound(_ data: Data) { inboundHandler?(data, nil) }
    func deliverEOF() { inboundHandler?(nil, nil) }
    var hasStateHandler: Bool { stateHandler != nil }
}

private final class FakeConnections: ConnectionFactory {
    private(set) var created: [FakeChannel] = []
    var createdCount: Int { created.count }
    var current: FakeChannel? { created.last }
    var lastHost: String? { created.last?.host }
    var lastPort: UInt16? { created.last?.port }

    func makeConnection(host: String, port: UInt16, tls: CollectorTLS?) -> ConnectionChannel {
        let channel = FakeChannel(host: host, port: port, tls: tls)
        created.append(channel)
        return channel
    }

    func failCurrent() { current?.fail() }
}

// MARK: - Control frame builder (matches collector encodeControlFrame envelope)

private func controlFrame(_ type: String) -> Data {
    let inner = "{\"type\":\"\(type)\",\"protocolVersion\":2}"
    let content = Data(inner.utf8).base64EncodedString()
    let envelope = "{\"id\":\"c\",\"messageType\":\"control\",\"content\":\"\(content)\",\"buildVersion\":\"netcapture-2\"}"
    let payload = Data(envelope.utf8)
    var len = UInt64(payload.count).littleEndian
    var frame = Data(bytes: &len, count: MemoryLayout<UInt64>.size)
    frame.append(payload)
    return frame
}

final class TransportLifecycleTests: XCTestCase {

    private func makeCore(_ clock: FakeClock, _ connections: FakeConnections,
                          limits: CaptureLimits = .qa) -> ManualTransportCore {
        // Zero jitter and a tiny base so backoff delays are deterministic and small.
        let retry = RetryController(clock: clock, baseDelay: 1, maxDelay: 30, jitter: { $0 })
        return ManualTransportCore(factory: connections, retry: retry, limits: limits)
    }

    // The brief's exact acceptance snippet: a stopped connection never reconnects, and
    // a subsequent start targets the new host/port — never localhost.
    func testStopThenReconfigureDoesNotReconnectStalely() {
        let clock = FakeClock()
        let connections = FakeConnections()
        let transport = makeCore(clock, connections)

        let configA = Configuration.manual(host: "10.0.0.1", port: 10909)
        let configB = Configuration.manual(host: "10.0.0.2", port: 20000)

        transport.start(configA)
        connections.failCurrent()   // schedules a reconnect for generation A
        transport.stop()            // bumps generation, cancels the pending retry
        clock.advance(by: 180)      // 3 minutes: the stale retry must not fire a connect
        XCTAssertEqual(connections.createdCount, 1)

        transport.start(configB)
        XCTAssertEqual(connections.lastHost, configB.host)
        XCTAssertEqual(connections.lastPort, configB.port)
    }

    func testManualModeNeverUsesLocalhost() {
        let clock = FakeClock()
        let connections = FakeConnections()
        let transport = makeCore(clock, connections)
        transport.start(Configuration.manual(host: "192.168.1.50", port: 10909))
        // Burst of failures across three minutes: every reconnect targets the config
        // host, never localhost.
        for _ in 0..<5 {
            connections.failCurrent()
            clock.advance(by: 60)
        }
        XCTAssertTrue(connections.created.allSatisfy { $0.host == "192.168.1.50" })
        XCTAssertGreaterThan(connections.createdCount, 1, "should have retried")
    }

    func testBurstOfFailuresKeepsOneTimerAndReconnects() {
        let clock = FakeClock()
        let connections = FakeConnections()
        let transport = makeCore(clock, connections)
        transport.start(Configuration.manual(host: "h", port: 1))
        // Repeated immediate failures should never accumulate more than one pending
        // timer (single-timer invariant).
        connections.failCurrent()
        connections.failCurrent()
        connections.failCurrent()
        XCTAssertLessThanOrEqual(clock.pendingCount, 1)
        clock.advance(by: 60)
        XCTAssertGreaterThanOrEqual(connections.createdCount, 2)
    }

    func testThreeMinutesOfflineThenRecovers() {
        let clock = FakeClock()
        let connections = FakeConnections()
        let transport = makeCore(clock, connections)
        transport.start(Configuration.manual(host: "h", port: 1))
        // Fail repeatedly for ~3 minutes, then let a connection come up.
        for _ in 0..<6 {
            connections.failCurrent()
            clock.advance(by: 30)
        }
        let last = connections.current!
        last.becomeReady()
        XCTAssertTrue(last.started)
    }

    // MARK: - Ready gate

    func testTLSModeDoesNotReplayBeforeReadyControlFrame() {
        let clock = FakeClock()
        let connections = FakeConnections()
        let transport = makeCore(clock, connections)
        let tls = CollectorTLS(certificateDER: Data([0x30]), certificateSha256: String(repeating: "a", count: 64))
        transport.start(Configuration.manual(host: "h", port: 1, tls: tls))

        // Queue traffic while offline.
        transport.send(payload: Data("frame-1".utf8))
        let channel = connections.current!
        channel.becomeReady()
        // On ready, only the ConnectionPackage (auth handshake) is sent — NOT the
        // queued traffic, because the v2 ready control frame has not arrived.
        XCTAssertEqual(channel.sentPayloads.count, 1, "only ConnectionPackage before ready")
        XCTAssertFalse(transport.test_isReadyForReplay)

        // Server acknowledges: now the queued traffic is flushed.
        channel.deliverInbound(controlFrame("ready"))
        XCTAssertTrue(transport.test_isReadyForReplay)
        XCTAssertEqual(channel.sentPayloads.count, 2, "queued frame flushed after ready")
        XCTAssertEqual(channel.sentPayloads.last, Data("frame-1".utf8))
    }

    func testLegacyModeReplaysImmediatelyOnReady() {
        let clock = FakeClock()
        let connections = FakeConnections()
        let transport = makeCore(clock, connections)
        // No TLS => legacy Proxyman: no control ACK expected.
        transport.start(Configuration.manual(host: "h", port: 1))
        transport.send(payload: Data("frame-1".utf8))
        let channel = connections.current!
        channel.becomeReady()
        XCTAssertTrue(transport.test_isReadyForReplay)
        // ConnectionPackage + queued frame both sent.
        XCTAssertEqual(channel.sentPayloads.count, 2)
    }

    func testAuthErrorBlocksReconnect() {
        let clock = FakeClock()
        let connections = FakeConnections()
        let transport = makeCore(clock, connections)
        let tls = CollectorTLS(certificateDER: Data([0x30]), certificateSha256: String(repeating: "a", count: 64))
        transport.start(Configuration.manual(host: "h", port: 1, tls: tls))
        connections.current!.becomeReady()
        connections.current!.deliverInbound(controlFrame("auth_error"))
        XCTAssertTrue(transport.test_isBlocked)

        // A subsequent EOF/failure must NOT schedule a reconnect while blocked.
        clock.advance(by: 300)
        XCTAssertEqual(connections.createdCount, 1)
    }

    // MARK: - Certificate/pin failure -> blocked (finding 1)

    func testCertificateFailureBlocksReconnect() {
        let clock = FakeClock()
        let connections = FakeConnections()
        let transport = makeCore(clock, connections)
        let tls = CollectorTLS(certificateDER: Data([0x30]), certificateSha256: String(repeating: "a", count: 64))
        transport.start(Configuration.manual(host: "h", port: 1, tls: tls))

        // A pinned-TLS verify-block rejection (NWError.tls) is permanent: block, never
        // retry a wrong pin.
        connections.current!.failTLS()
        XCTAssertTrue(transport.test_isBlocked)
        clock.advance(by: 300)
        XCTAssertEqual(connections.createdCount, 1, "a bad pin must not reconnect")
    }

    func testTransientFailureStillReconnects() {
        // Contrast: a non-TLS failure is transient and DOES retry.
        let clock = FakeClock()
        let connections = FakeConnections()
        let transport = makeCore(clock, connections)
        transport.start(Configuration.manual(host: "h", port: 1))
        connections.current!.fail()
        XCTAssertFalse(transport.test_isBlocked)
        clock.advance(by: 5)
        XCTAssertEqual(connections.createdCount, 2)
    }

    // MARK: - Stale callbacks from a superseded attempt (finding 2)

    func testSingleDisconnectSchedulesOneRetryNoDoubleBackoff() {
        let clock = FakeClock()
        let connections = FakeConnections()
        let transport = makeCore(clock, connections)
        transport.start(Configuration.manual(host: "h", port: 1))
        let channelA = connections.current!

        // For one disconnect, both a state .failed and a read EOF can fire. Only the
        // first must schedule a retry; the second (stale) must be ignored so backoff
        // is not double-incremented.
        channelA.fail()
        channelA.deliverEOF()
        XCTAssertEqual(transport.test_retryAttempt, 1, "one disconnect => one backoff step")
        XCTAssertLessThanOrEqual(clock.pendingCount, 1, "at most one pending timer")
    }

    func testStaleReadAfterReconnectDoesNotTearDownNextConnection() {
        let clock = FakeClock()
        let connections = FakeConnections()
        let transport = makeCore(clock, connections)
        transport.start(Configuration.manual(host: "h", port: 1))
        let channelA = connections.current!

        channelA.fail()          // schedule retry for attempt A
        clock.advance(by: 5)     // fire it -> channel B connects
        let channelB = connections.current!
        XCTAssertEqual(connections.createdCount, 2)
        let attemptAfter = transport.test_retryAttempt

        // channelA's fake keeps its inbound handler live post-teardown. A stale read or
        // EOF from it must be fenced by generation and must NOT reconnect or disturb B.
        channelA.deliverEOF()
        channelA.deliverInbound(Data("stale-garbage".utf8))
        XCTAssertEqual(connections.createdCount, 2, "stale callback must not open a new connection")
        XCTAssertEqual(transport.test_retryAttempt, attemptAfter, "stale callback must not bump backoff")
        XCTAssertTrue(channelB === connections.current, "channel B must remain current")
    }

    // MARK: - Offline queue budget

    func testOfflineQueueRespectsPackageBudget() {
        let clock = FakeClock()
        let connections = FakeConnections()
        // Small budget: at most 3 packages.
        let limits = CaptureLimits(maxBodyBytes: 1 << 20, maxPendingBytes: 1 << 20, maxPendingPackages: 3)
        let transport = makeCore(clock, connections, limits: limits)
        transport.start(Configuration.manual(host: "h", port: 1))

        // Enqueue 10 while offline; only the last 3 survive.
        for i in 0..<10 { transport.send(payload: Data("f\(i)".utf8)) }
        XCTAssertEqual(transport.test_pendingCount, 3)

        let channel = connections.current!
        channel.becomeReady() // legacy: flush immediately
        // ConnectionPackage + 3 retained frames.
        XCTAssertEqual(channel.sentPayloads.count, 4)
        XCTAssertEqual(channel.sentPayloads.suffix(3), [Data("f7".utf8), Data("f8".utf8), Data("f9".utf8)])
    }

    func testOfflineQueueRespectsByteBudget() {
        let clock = FakeClock()
        let connections = FakeConnections()
        let limits = CaptureLimits(maxBodyBytes: 1 << 20, maxPendingBytes: 10, maxPendingPackages: 1000)
        let transport = makeCore(clock, connections, limits: limits)
        transport.start(Configuration.manual(host: "h", port: 1))
        // Each payload is 4 bytes; a 10-byte budget keeps at most the last 2.
        for i in 0..<5 { transport.send(payload: Data("ab\(i)x".utf8)) }
        XCTAssertLessThanOrEqual(transport.test_pendingBytes, 10)
        XCTAssertEqual(transport.test_pendingCount, 2)
    }

    func testStopReleasesOfflineQueue() {
        let clock = FakeClock()
        let connections = FakeConnections()
        let transport = makeCore(clock, connections)
        transport.start(Configuration.manual(host: "h", port: 1))
        for i in 0..<5 { transport.send(payload: Data("f\(i)".utf8)) }
        XCTAssertGreaterThan(transport.test_pendingCount, 0)
        transport.stop()
        XCTAssertEqual(transport.test_pendingCount, 0)
        XCTAssertEqual(transport.test_pendingBytes, 0)
    }
}
