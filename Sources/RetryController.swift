//
//  RetryController.swift
//  atlantis
//
//  Reconnect scheduling for the manual/TLS transport. This type OWNS NO SOCKETS: it
//  only computes exponential backoff with injectable jitter and drives a single
//  timer through an injectable clock. The transport core guards each fired callback
//  with a monotonic generation so a stale timer can never resurrect a stopped or
//  reconfigured connection.
//

import Foundation

/// Opaque handle for a scheduled unit of work, so the clock can cancel it.
final class ClockToken {
    fileprivate let id = UUID()
    fileprivate var workItem: DispatchWorkItem?
    init(workItem: DispatchWorkItem? = nil) { self.workItem = workItem }
}

extension ClockToken: Hashable {
    static func == (lhs: ClockToken, rhs: ClockToken) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A clock that can schedule delayed work and cancel it. The real implementation
/// dispatches on the transport's serial queue; tests inject a virtual clock so no
/// real time passes.
protocol SchedulerClock: AnyObject {
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> ClockToken
    func cancel(_ token: ClockToken)
}

/// Production clock backed by a serial `DispatchQueue`.
final class QueueClock: SchedulerClock {
    private let queue: DispatchQueue
    init(queue: DispatchQueue) { self.queue = queue }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) -> ClockToken {
        let item = DispatchWorkItem(block: work)
        let token = ClockToken(workItem: item)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return token
    }

    func cancel(_ token: ClockToken) {
        token.workItem?.cancel()
        token.workItem = nil
    }
}

/// Computes exponential backoff with jitter and keeps at most one pending timer.
/// Scheduling again cancels the previous timer — there is never more than one.
final class RetryController {

    private let clock: SchedulerClock
    private let baseDelay: TimeInterval
    private let maxDelay: TimeInterval
    private let jitter: (TimeInterval) -> TimeInterval
    private var token: ClockToken?
    private(set) var attempt = 0

    /// - Parameter jitter: maps a computed backoff to the actual delay. Injectable so
    ///   tests get deterministic timing; production adds randomised jitter.
    init(clock: SchedulerClock,
         baseDelay: TimeInterval = 1.0,
         maxDelay: TimeInterval = 30.0,
         jitter: @escaping (TimeInterval) -> TimeInterval = RetryController.defaultJitter) {
        self.clock = clock
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    /// Full jitter: a uniformly random delay in `[0, backoff]`.
    static func defaultJitter(_ backoff: TimeInterval) -> TimeInterval {
        return TimeInterval.random(in: 0...backoff)
    }

    /// The delay the next `scheduleRetry` would use, before jitter. Exposed for tests.
    var nextBackoff: TimeInterval {
        return min(maxDelay, baseDelay * pow(2.0, Double(attempt)))
    }

    /// Schedule the next reconnect attempt. Cancels any pending timer first so only
    /// one exists. The caller's `work` is still expected to re-check its generation.
    func scheduleRetry(_ work: @escaping () -> Void) {
        cancelPending()
        let delay = jitter(nextBackoff)
        attempt += 1
        token = clock.schedule(after: delay, work)
    }

    /// Cancel the pending timer, if any.
    func cancelPending() {
        if let token = token {
            clock.cancel(token)
            self.token = nil
        }
    }

    /// Reset backoff after a successful connection so the next disconnect starts over.
    func resetBackoff() {
        attempt = 0
    }
}
