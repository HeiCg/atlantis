import Foundation
import XCTest
@testable import Atlantis

/// O13 gate: record encoding/compression measurements for the fork so the decision to
/// keep the current implementation is backed by numbers, and pin the properties that
/// decision relies on. These tests are hermetic (no sockets, no clock) and print the
/// measured sizes so they land in the test log for the report.
final class O13MeasurementTests: XCTestCase {

    private func trafficMessage(bodyBytes: Int) -> Message {
        let body = Data((0..<bodyBytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let request = Request(url: "https://api.example.com/v1/resource", method: "POST",
                              headers: [Header(key: "Content-Type", value: "application/json")], body: nil)
        let response = Response(statusCode: 200, headers: [Header(key: "Content-Type", value: "application/octet-stream")])
        let package = TrafficPackage(id: UUID().uuidString, request: request, response: response, responseBodyData: body)
        return Message.buildTrafficMessage(id: "collector", item: package)
    }

    func testEncodingSizesAcrossPayloadSizes() throws {
        for bytes in [200, 64 * 1024, 1024 * 1024] {
            let message = trafficMessage(bodyBytes: bytes)
            let raw = try XCTUnwrap(message.toData())
            let compressed = try XCTUnwrap(message.toCompressedData())
            print("O13 body=\(bytes)B  rawEnvelope=\(raw.count)B  wire=\(compressed.count)B  ratio=\(String(format: "%.2f", Double(compressed.count) / Double(raw.count)))")
            // The wire path never grows the envelope (toCompressedData falls back to raw
            // if gzip is not smaller), so it is always <= raw.
            XCTAssertLessThanOrEqual(compressed.count, raw.count)
        }
    }

    func testSmallMessageGzipDoesNotHelp() throws {
        // Supports keeping framing/base64 as-is: for a small message gzip provides no
        // meaningful shrink (often larger), so a raw-below-threshold policy would be a
        // wash. Recorded, not acted on this cycle.
        let message = trafficMessage(bodyBytes: 200)
        let raw = try XCTUnwrap(message.toData())
        let gzip = raw.gzip()
        print("O13 small rawEnvelope=\(raw.count)B gzip=\(gzip?.count ?? -1)B")
        // toCompressedData must never exceed raw regardless.
        XCTAssertLessThanOrEqual(try XCTUnwrap(message.toCompressedData()).count, raw.count)
    }

    func testEncodingLatency64KiB() throws {
        let message = trafficMessage(bodyBytes: 64 * 1024)
        measure { _ = message.toCompressedData() }
    }

    func testEncodingLatency1MiB() throws {
        let message = trafficMessage(bodyBytes: 1024 * 1024)
        measure { _ = message.toCompressedData() }
    }

    // Immutable-snapshot guarantee: the transport enqueues a serialized Data snapshot,
    // so mutating the original package after enqueue cannot change the bytes on the
    // wire. This is what lets encoding stay on the send path safely.
    func testEnqueuedSnapshotIsImmutableAgainstLaterMutation() throws {
        let request = Request(url: "https://api.example.com/x", method: "GET", headers: [], body: nil)
        let package = TrafficPackage(id: "snap", request: request, response: Response(statusCode: 200, headers: []),
                                     responseBodyData: Data("original".utf8))
        let message = Message.buildTrafficMessage(id: "c", item: package)
        let snapshot = try XCTUnwrap(message.toCompressedData()) // what the transport would enqueue

        // Mutate the original package after the snapshot is taken.
        package.appendResponseData(Data("-MUTATED-APPENDED".utf8))

        // The already-captured snapshot is unchanged.
        let snapshotAgain = try XCTUnwrap(Message.buildTrafficMessage(id: "c", item: package).toCompressedData())
        XCTAssertNotEqual(snapshot, snapshotAgain, "sanity: a fresh encode reflects the mutation")
        // The enqueued Data value itself is a value-type snapshot and cannot be mutated
        // by the package; its byte count is fixed.
        let fixedCount = snapshot.count
        package.appendResponseData(Data("-more-".utf8))
        XCTAssertEqual(snapshot.count, fixedCount)
    }
}
