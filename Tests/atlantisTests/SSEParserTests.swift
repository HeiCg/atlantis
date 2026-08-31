import Foundation
import XCTest
@testable import Atlantis

final class SSEParserTests: XCTestCase {

    private func events(feeding chunks: [Data], maxEventBytes: Int = Int.max) -> (events: [String], omitted: Int) {
        let parser = SSEParser(maxEventBytes: maxEventBytes)
        var all: [String] = []
        for chunk in chunks {
            all.append(contentsOf: parser.parse(chunk))
        }
        return (all, parser.omittedEventCount)
    }

    // MARK: - Split-at-every-position invariant

    func testCafeFixtureSplitAtEveryPositionMatchesWholeInput() {
        // The canonical fixture: `data: café\n\n`. Splitting the raw bytes at every
        // possible position must yield exactly the same decoded event as feeding it
        // whole — including the multi-byte `é` (0xC3 0xA9) split across chunks.
        let input = Array("data: café\n\n".utf8)
        let whole = events(feeding: [Data(input)]).events
        XCTAssertEqual(whole, ["data: café"])

        for split in 0...input.count {
            let first = Data(input[0..<split])
            let second = Data(input[split..<input.count])
            let result = events(feeding: [first, second]).events
            XCTAssertEqual(result, whole, "split at \(split) diverged")
        }
    }

    func testCafeFixtureSplitIntoSingleBytesMatchesWholeInput() {
        let input = Array("data: café\n\n".utf8)
        let byteChunks = input.map { Data([$0]) }
        XCTAssertEqual(events(feeding: byteChunks).events, ["data: café"])
    }

    // MARK: - Line endings

    func testSupportsLFCRLFAndCR() {
        XCTAssertEqual(events(feeding: [Data("data: a\n\n".utf8)]).events, ["data: a"])
        XCTAssertEqual(events(feeding: [Data("data: b\r\n\r\n".utf8)]).events, ["data: b"])
        // A CR-only blank line ending in a lone CR is ambiguous mid-stream (the last
        // CR could begin a CRLF), so it resolves on finish(), not within parse().
        let parser = SSEParser()
        XCTAssertEqual(parser.parse(Data("data: c\r\r".utf8)), [])
        XCTAssertEqual(parser.finish(), ["data: c"])
    }

    func testCRLFDelimiterSplitBetweenChunks() {
        // Split the CRLF pairs at every awkward seam.
        let input = Array("data: x\r\n\r\n".utf8)
        for split in 0...input.count {
            let result = events(feeding: [Data(input[0..<split]), Data(input[split...])]).events
            XCTAssertEqual(result, ["data: x"], "CRLF split at \(split)")
        }
    }

    func testInternalSingleNewlineIsContentNormalisedToLF() {
        // Two data lines in one event; internal CRLF normalised to LF.
        XCTAssertEqual(events(feeding: [Data("data: a\r\ndata: b\r\n\r\n".utf8)]).events,
                       ["data: a\ndata: b"])
    }

    // MARK: - Multiple events / empty chunks / EOF

    func testMultipleEventsInOneChunk() {
        XCTAssertEqual(events(feeding: [Data("data: one\n\ndata: two\n\ndata: three\n\n".utf8)]).events,
                       ["data: one", "data: two", "data: three"])
    }

    func testEmptyChunkIsNoOp() {
        let parser = SSEParser()
        XCTAssertEqual(parser.parse(Data()), [])
        XCTAssertEqual(parser.parse(Data("data: a\n\n".utf8)), ["data: a"])
        XCTAssertEqual(parser.parse(Data()), [])
    }

    func testPartialEventAtEOFNotDeliveredByParse() {
        // No terminating blank line: parse() must not emit it as complete.
        XCTAssertEqual(events(feeding: [Data("data: incomplete".utf8)]).events, [])
    }

    func testFinishReturnsTrailingBlockOnClose() {
        let parser = SSEParser()
        XCTAssertEqual(parser.parse(Data("data: done\n\ndata: trailing".utf8)), ["data: done"])
        XCTAssertEqual(parser.finish(), ["data: trailing"])
    }

    func testFinishEmptyWhenNothingPending() {
        let parser = SSEParser()
        XCTAssertEqual(parser.parse(Data("data: done\n\n".utf8)), ["data: done"])
        XCTAssertEqual(parser.finish(), [])
    }

    // MARK: - Limits

    func testGiantEventWithoutDelimiterIsOmittedNotBuffered() {
        // A very large event with no blank line: content is dropped, marked omitted,
        // and nothing is delivered as a complete event.
        let big = String(repeating: "x", count: 200_000)
        let (evs, omitted) = events(feeding: [Data(big.utf8)], maxEventBytes: 1024)
        XCTAssertEqual(evs, [])
        // finish() must not resurrect the truncated suffix.
        let parser = SSEParser(maxEventBytes: 1024)
        _ = parser.parse(Data(big.utf8))
        XCTAssertEqual(parser.finish(), [])
        _ = omitted
    }

    func testOversizeEventOmittedThenParsingResumes() {
        let big = String(repeating: "y", count: 5000)
        let input = "data: \(big)\n\ndata: small\n\n"
        let (evs, omitted) = events(feeding: [Data(input.utf8)], maxEventBytes: 1024)
        XCTAssertEqual(evs, ["data: small"], "small event after an omitted giant one must still arrive")
        XCTAssertEqual(omitted, 1)
    }

    func testUnderLimitEventNotOmitted() {
        let (evs, omitted) = events(feeding: [Data("data: hello\n\n".utf8)], maxEventBytes: 1024)
        XCTAssertEqual(evs, ["data: hello"])
        XCTAssertEqual(omitted, 0)
    }
}
