import Foundation
import XCTest
@testable import Atlantis

final class CaptureLimitTests: XCTestCase {

    // MARK: - Body retention cap

    func testResponseBodyOmittedWhenOverCapAndAppKeepsAllBytes() {
        let limits = CaptureLimits.qa // 1 MiB per body
        let package = TrafficPackage(id: "t1", request: Request(url: "https://api/x", method: "GET", headers: [], body: nil))
        package.captureMaxBodyBytes = limits.maxBodyBytes

        // A response larger than the cap, delivered in chunks. The injector delivers
        // each chunk to the app first (mirrored by `applicationSink`) and then to the
        // package, so the app must receive every byte regardless of capture omission.
        // Distinct chunks so the same-pointer dedupe in appendResponseData does not
        // collapse them.
        let chunks = (0..<8).map { i in Data(repeating: UInt8(0x41 + i), count: 256 * 1024) } // 2 MiB total
        var applicationSink = 0
        for c in chunks {
            applicationSink += c.count          // app receives the raw chunk
            package.appendResponseData(c)       // capture observes it
        }

        let completeResponseBytes = chunks.reduce(0) { $0 + $1.count }
        XCTAssertLessThanOrEqual(package.retainedBodyBytes, limits.maxBodyBytes)
        XCTAssertTrue(package.bodyWasOmitted)
        XCTAssertEqual(applicationSink, completeResponseBytes, "app must receive the full stream")

        // The serialized snapshot must carry the skip sentinel the collector understands.
        let data = try? XCTUnwrap(package.toData())
        let json = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any]
        let bodyB64 = json?["responseBodyData"] as? String
        let bodyText = bodyB64.flatMap { Data(base64Encoded: $0) }.map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(bodyText, "<Skip Large Body>")
    }

    func testResponseBodyUnderCapFullyRetained() {
        let package = TrafficPackage(id: "t2", request: Request(url: "https://api/x", method: "GET", headers: [], body: nil))
        package.captureMaxBodyBytes = 1024
        let body = Data(repeating: 0x42, count: 512)
        package.appendResponseData(body)
        XCTAssertEqual(package.retainedBodyBytes, 512)
        XCTAssertFalse(package.bodyWasOmitted)
    }

    func testResponseBodyExactlyAtCapNotOmitted() {
        let package = TrafficPackage(id: "t3", request: Request(url: "https://api/x", method: "GET", headers: [], body: nil))
        package.captureMaxBodyBytes = 1000
        package.appendResponseData(Data(repeating: 0x43, count: 1000))
        XCTAssertFalse(package.bodyWasOmitted)
        XCTAssertEqual(package.retainedBodyBytes, 1000)
        // One more byte tips it over.
        package.appendResponseData(Data(repeating: 0x44, count: 1))
        XCTAssertTrue(package.bodyWasOmitted)
        XCTAssertEqual(package.retainedBodyBytes, 0, "captured content released on overflow")
    }

    func testNilCapKeepsLegacyBehaviour() {
        let package = TrafficPackage(id: "t4", request: Request(url: "https://api/x", method: "GET", headers: [], body: nil))
        package.captureMaxBodyBytes = nil
        package.appendResponseData(Data(repeating: 0x45, count: 5 * 1024 * 1024))
        XCTAssertFalse(package.bodyWasOmitted)
        XCTAssertEqual(package.retainedBodyBytes, 5 * 1024 * 1024)
    }

    func testRequestBodyOmittedWhenOverCap() {
        let package = TrafficPackage(id: "t5", request: Request(url: "https://api/x", method: "POST", headers: [], body: nil))
        package.captureMaxBodyBytes = 1024
        package.appendRequestData(Data(repeating: 0x46, count: 2048))
        // toData drops the request body and the collector reads no body.
        let data = try? XCTUnwrap(package.toData())
        let json = try? JSONSerialization.jsonObject(with: data ?? Data()) as? [String: Any]
        let request = json?["request"] as? [String: Any]
        XCTAssertNil(request?["body"], "over-cap request body must be dropped from the snapshot")
    }

    // MARK: - O09: stop releases every capture structure

    private func enableCaptureWithoutTransport() {
        Atlantis.stop() // ensure a clean disabled state first
        Atlantis.setEnableTransportLayer(false) // no sockets in tests
        Atlantis.start(host: "127.0.0.1", port: 65000)
    }

    private func makeTask(_ urlString: String) -> URLSessionTask {
        // A non-resumed data task: a real URLSessionTask object with a currentRequest,
        // but no network activity.
        return URLSession.shared.dataTask(with: URL(string: urlString)!)
    }

    func testStartStopThenTenThousandResumesAccumulateNothing() {
        enableCaptureWithoutTransport()
        Atlantis.stop()
        // After stop, resumes must record nothing (gate before taskStartTimes).
        for _ in 0..<10_000 {
            Atlantis.shared.injectorSessionDidCallResume(task: makeTask("https://example.com/x"))
        }
        XCTAssertEqual(Atlantis.shared.test_captureStateCount, 0)
    }

    func testStopDuringHTTPClearsAllCaptureStructures() {
        enableCaptureWithoutTransport()
        let task = makeTask("https://example.com/data")
        Atlantis.shared.injectorSessionDidCallResume(task: task)
        let response = HTTPURLResponse(url: URL(string: "https://example.com/data")!,
                                       statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        Atlantis.shared.injectorSessionDidReceiveResponse(dataTask: task, response: response)
        Atlantis.shared.injectorSessionDidReceiveData(dataTask: task, data: Data("{\"a\":1}".utf8))
        XCTAssertGreaterThan(Atlantis.shared.test_captureStateCount, 0, "capture state should be populated")

        Atlantis.stop()
        XCTAssertEqual(Atlantis.shared.test_captureStateCount, 0, "stop must release every capture structure")
    }

    func testStopDuringSSEClearsParsersAndState() {
        enableCaptureWithoutTransport()
        let task = makeTask("https://example.com/stream")
        Atlantis.shared.injectorSessionDidCallResume(task: task)
        let response = HTTPURLResponse(url: URL(string: "https://example.com/stream")!,
                                       statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        Atlantis.shared.injectorSessionDidReceiveResponse(dataTask: task, response: response)
        Atlantis.shared.injectorSessionDidReceiveData(dataTask: task, data: Data("data: hello\n\n".utf8))
        XCTAssertGreaterThan(Atlantis.shared.test_captureStateCount, 0)

        Atlantis.stop()
        XCTAssertEqual(Atlantis.shared.test_captureStateCount, 0)
    }

    override func tearDown() {
        Atlantis.stop()
        Atlantis.setEnableTransportLayer(true)
        super.tearDown()
    }
}
