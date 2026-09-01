//
//  SSEParser.swift
//  atlantis
//
//  Incremental, byte-level Server-Sent Events block parser.
//
//  The previous implementation concatenated every chunk into a growing `String`
//  and re-scanned the whole buffer on each `didReceiveData`. That is quadratic,
//  mis-handles a UTF-8 sequence or a delimiter split across chunk boundaries, and
//  keeps unbounded content in memory. This parser instead consumes raw bytes with
//  a cursor and a small boundary state, decoding only complete events and never
//  materialising a truncated suffix as a finished event.
//
//  Boundary rules (SSE): an event is terminated by a blank line, i.e. two adjacent
//  line terminators. A line terminator is CRLF, LF or a lone CR. Both the CRLF pair
//  and the blank-line pair may be split across chunks, so decisions are deferred
//  until enough bytes have arrived. Internal single line terminators are part of the
//  event and are normalised to LF, matching the whole-input reference behaviour.
//

import Foundation

final class SSEParser {

    /// Maximum number of content bytes retained for a single event. When an event
    /// grows past this, its content is dropped, the event is marked omitted, and no
    /// truncated suffix is delivered — parsing resumes cleanly at the next boundary.
    private let maxEventBytes: Int

    /// Count of events whose content exceeded `maxEventBytes` and were dropped.
    private(set) var omittedEventCount = 0

    // Content bytes of the in-progress event, already normalised (CR/CRLF -> LF).
    // Freed as soon as the event is marked omitted so memory stays bounded.
    private var content: [UInt8] = []

    // Logical size of the in-progress event, tracked even while omitting so the
    // limit decision is stable regardless of how input is chunked.
    private var contentByteCount = 0
    private var omitCurrent = false

    // One completed line terminator awaiting classification: it is either an
    // internal newline (content) or the first half of a blank-line delimiter.
    private var sawNewline = false

    // A trailing CR that may still combine with a following LF into one CRLF token.
    private var crHeld = false

    init(maxEventBytes: Int = Int.max) {
        self.maxEventBytes = maxEventBytes
    }

    /// Feed one chunk. Returns the text of every event completed by these bytes,
    /// with CR/CRLF normalised to LF and whitespace-only events skipped.
    func parse(_ data: Data) -> [String] {
        var events: [String] = []
        for byte in data {
            feed(byte, into: &events)
        }
        return events
    }

    /// Finish the stream (called on completion/close). Resolves a dangling CR — which
    /// may complete a final blank-line boundary — then flushes a trailing block that
    /// lacked a terminating blank line, mirroring the historical close behaviour.
    /// A truncated/omitted suffix is never delivered as a complete event.
    func finish() -> [String] {
        var events: [String] = []
        if crHeld {
            crHeld = false
            resolveNewline(into: &events) // a lone trailing CR is a terminator
        }
        // A buffered single newline is a terminator, not content, so it is not part
        // of any trailing block; drop it.
        sawNewline = false
        // Flush a trailing, unterminated block if it carried real content and was not
        // omitted by the size limit.
        if !omitCurrent, contentByteCount > 0 {
            let text = String(decoding: content, as: UTF8.self)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                events.append(text)
            }
        }
        resetEvent()
        return events
    }

    // MARK: - Byte machine

    private func feed(_ byte: UInt8, into events: inout [String]) {
        // Resolve a held CR first.
        if crHeld {
            crHeld = false
            if byte == 0x0A { // CRLF -> single terminator
                resolveNewline(into: &events)
                return
            }
            // Lone CR was a terminator; fall through to process this byte fresh.
            resolveNewline(into: &events)
        }

        switch byte {
        case 0x0D: // CR: wait to see if an LF follows
            crHeld = true
        case 0x0A: // LF terminator
            resolveNewline(into: &events)
        default:
            resolveContent(byte)
        }
    }

    // A completed line terminator token arrived.
    private func resolveNewline(into events: inout [String]) {
        if sawNewline {
            // Two adjacent terminators = blank line = event boundary.
            emit(into: &events)
            sawNewline = false
        } else {
            // Buffer it: internal newline vs. first half of a delimiter is decided
            // by whatever comes next.
            sawNewline = true
        }
    }

    private func resolveContent(_ byte: UInt8) {
        if sawNewline {
            // The buffered terminator was internal to the event; normalise to LF.
            append(0x0A)
            sawNewline = false
        }
        append(byte)
    }

    private func append(_ byte: UInt8) {
        contentByteCount += 1
        if omitCurrent { return }
        if contentByteCount > maxEventBytes {
            // Cross the limit: drop retained content and stop storing until the next
            // boundary. No partial content is kept or delivered.
            omitCurrent = true
            content.removeAll(keepingCapacity: false)
            return
        }
        content.append(byte)
    }

    private func emit(into events: inout [String]) {
        defer { resetEvent() }
        if omitCurrent {
            omittedEventCount += 1
            return
        }
        guard contentByteCount > 0 else { return }
        let text = String(decoding: content, as: UTF8.self)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            events.append(text)
        }
    }

    private func resetEvent() {
        content.removeAll(keepingCapacity: true)
        contentByteCount = 0
        omitCurrent = false
    }
}
