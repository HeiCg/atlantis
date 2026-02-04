import Foundation
import ObjectiveC
import XCTest
@testable import Atlantis

private struct TestMessageEnvelope: Codable {
    let id: String?
    let messageType: Message.MessageType
    let content: Data?
    let buildVersion: String?
}

private final class TestTransporter: Transporter {
    private let queue = DispatchQueue(label: "com.proxyman.atlantis.tests.transporter")
    private var messages: [TestMessageEnvelope] = []
    var onTrafficPackage: ((TrafficPackage) -> Void)?

    func start(_ config: Configuration) {
        // No-op: avoid Bonjour/network in tests.
    }

    func stop() {
        // No-op
    }

    func send(package: Serializable) {
        guard let data = package.toData(),
              let envelope = try? JSONDecoder().decode(TestMessageEnvelope.self, from: data) else {
            return
        }
        queue.async {
            self.messages.append(envelope)
        }
        guard envelope.messageType == .traffic,
              let content = envelope.content,
              let traffic = try? JSONDecoder().decode(TrafficPackage.self, from: content) else {
            return
        }
        onTrafficPackage?(traffic)
    }

    func drainMessages() -> [TestMessageEnvelope] {
        queue.sync { messages }
    }
}

final class URLSessionSwizzleTests: XCTestCase {
    private let baseURL = URL(string: "https://httpbin.proxyman.app")!
    private var transporter: TestTransporter!

    override func setUp() {
        super.setUp()
        transporter = TestTransporter()
        Atlantis.setIsRunningOniOSPlayground(true)
        Atlantis.setEnableTransportLayer(true)
        Atlantis.setTransporterForTesting(transporter)
        Atlantis.start()
    }

    override func tearDown() {
        Atlantis.stop()
        transporter = nil
        super.tearDown()
    }

    func testSelectorExistenceForSwizzledAPIs() {
        let sessionClass = NSClassFromString("__NSCFURLLocalSessionConnection")
            ?? NSClassFromString("__NSCFURLSessionConnection")
        XCTAssertNotNil(sessionClass)
        if let sessionClass = sessionClass {
            let responseSelector: Selector
            if #available(iOS 16.0, tvOS 16.0, *) {
                responseSelector = NSSelectorFromString("_didReceiveResponse:sniff:")
            } else if #available(iOS 13.0, tvOS 13.0, *) {
                responseSelector = NSSelectorFromString("_didReceiveResponse:sniff:rewrite:")
            } else {
                responseSelector = NSSelectorFromString("_didReceiveResponse:sniff:")
            }
            assertSelectorExists(baseClass: sessionClass, selector: responseSelector, name: "URLSession response")
            assertSelectorExists(baseClass: sessionClass, selector: NSSelectorFromString("_didReceiveData:"), name: "URLSession data")
            assertSelectorExists(baseClass: sessionClass, selector: NSSelectorFromString("_didFinishWithError:"), name: "URLSession complete")
        }

        let resumeClass: AnyClass? = {
            if !ProcessInfo.processInfo.responds(to: #selector(getter: ProcessInfo.operatingSystemVersion)) {
                return NSClassFromString("__NSCFLocalSessionTask")
            }
            let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
            if majorVersion < 9 || majorVersion >= 14 {
                return URLSessionTask.self
            }
            return NSClassFromString("__NSCFURLSessionTask")
        }()
        XCTAssertNotNil(resumeClass)
        if let resumeClass = resumeClass {
            assertSelectorExists(baseClass: resumeClass, selector: NSSelectorFromString("resume"), name: "URLSession resume")
        }

        let urlSessionClass: AnyClass = URLSession.self
        assertSelectorExists(baseClass: urlSessionClass, selector: NSSelectorFromString("uploadTaskWithRequest:fromFile:"), name: "upload from file")
        assertSelectorExists(baseClass: urlSessionClass, selector: NSSelectorFromString("uploadTaskWithRequest:fromFile:completionHandler:"), name: "upload from file + completion")
        assertSelectorExists(baseClass: urlSessionClass, selector: NSSelectorFromString("uploadTaskWithRequest:fromData:"), name: "upload from data")
        assertSelectorExists(baseClass: urlSessionClass, selector: NSSelectorFromString("uploadTaskWithRequest:fromData:completionHandler:"), name: "upload from data + completion")

        let webSocketClass = NSClassFromString("__NSURLSessionWebSocketTask")
        XCTAssertNotNil(webSocketClass)
        if let webSocketClass = webSocketClass {
            assertSelectorExists(baseClass: webSocketClass, selector: NSSelectorFromString("sendMessage:completionHandler:"), name: "websocket send")
            assertSelectorExists(baseClass: webSocketClass, selector: NSSelectorFromString("receiveMessageWithCompletionHandler:"), name: "websocket receive")
            assertSelectorExists(baseClass: webSocketClass, selector: NSSelectorFromString("sendPingWithPongReceiveHandler:"), name: "websocket ping/pong")
            assertSelectorExists(baseClass: webSocketClass, selector: NSSelectorFromString("cancelWithCloseCode:reason:"), name: "websocket cancel")
        }
    }

    func testGetRequestCaptured() {
        let url = baseURL.appendingPathComponent("get")
        let package = waitForTrafficPackage(matching: { package in
            package.request.method == "GET" && package.request.url.contains("/get")
        }) {
            let session = makeSession()
            let task = session.dataTask(with: url)
            task.resume()
        }
        assertPackageHasSuccessResponse(package)
        XCTAssertEqual(package.request.method, "GET")
        XCTAssertTrue(package.request.url.contains("/get"))
        XCTAssertFalse(package.responseBodyData.isEmpty)
    }

    func testPostRequestCaptured() {
        let url = baseURL.appendingPathComponent("post")
        let body = "hello-atlantis".data(using: .utf8)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        let package = waitForTrafficPackage(matching: { package in
            package.request.method == "POST" && package.request.url.contains("/post")
        }) {
            let session = makeSession()
            let task = session.dataTask(with: request)
            task.resume()
        }
        assertPackageHasSuccessResponse(package)
        XCTAssertEqual(package.request.body, body)
        XCTAssertFalse(package.responseBodyData.isEmpty)
    }

    func testDownloadRequestCaptured() {
        let url = baseURL.appendingPathComponent("bytes/32")
        let package = waitForTrafficPackage(matching: { package in
            package.request.method == "GET" && package.request.url.contains("/bytes/32")
        }) {
            let session = makeSession()
            let task = session.downloadTask(with: url)
            task.resume()
        }
        assertPackageHasSuccessResponse(package)
        XCTAssertFalse(package.responseBodyData.isEmpty)
    }

    func testUploadFromDataCaptured() {
        let url = baseURL.appendingPathComponent("post")
        let body = "upload-data-body".data(using: .utf8)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        let package = waitForTrafficPackage(matching: { package in
            package.request.method == "POST" && package.request.url.contains("/post")
        }) {
            let session = makeSession()
            let task = session.uploadTask(with: request, from: body)
            task.resume()
        }
        assertPackageHasSuccessResponse(package)
        XCTAssertEqual(package.request.body, body)
    }

    func testUploadFromDataWithCompletionCaptured() {
        let url = baseURL.appendingPathComponent("post")
        let body = "upload-data-body-completion".data(using: .utf8)!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        let package = waitForTrafficPackage(matching: { package in
            package.request.method == "POST" && package.request.url.contains("/post")
        }) {
            let session = makeSession()
            let task = session.uploadTask(with: request, from: body) { _, _, _ in }
            task.resume()
        }
        assertPackageHasSuccessResponse(package)
        XCTAssertEqual(package.request.body, body)
    }

    func testUploadFromFileCaptured() {
        let url = baseURL.appendingPathComponent("post")
        let body = "upload-file-body".data(using: .utf8)!
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? body.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        let package = waitForTrafficPackage(matching: { package in
            package.request.method == "POST" && package.request.url.contains("/post")
        }) {
            let session = makeSession()
            let task = session.uploadTask(with: request, fromFile: fileURL)
            task.resume()
        }
        assertPackageHasSuccessResponse(package)
        XCTAssertEqual(package.request.body, body)
    }

    func testUploadFromFileWithCompletionCaptured() {
        let url = baseURL.appendingPathComponent("post")
        let body = "upload-file-body-completion".data(using: .utf8)!
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? body.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")

        let package = waitForTrafficPackage(matching: { package in
            package.request.method == "POST" && package.request.url.contains("/post")
        }) {
            let session = makeSession()
            let task = session.uploadTask(with: request, fromFile: fileURL) { _, _, _ in }
            task.resume()
        }
        assertPackageHasSuccessResponse(package)
        XCTAssertEqual(package.request.body, body)
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return URLSession(configuration: config)
    }

    private func waitForTrafficPackage(matching predicate: @escaping (TrafficPackage) -> Bool,
                                       action: () -> Void) -> TrafficPackage {
        let expectation = expectation(description: "Wait for traffic package")
        var capturedPackage: TrafficPackage?
        transporter.onTrafficPackage = { package in
            guard predicate(package) else { return }
            capturedPackage = package
            expectation.fulfill()
        }
        action()
        wait(for: [expectation], timeout: 30)
        return capturedPackage!
    }

    private func assertPackageHasSuccessResponse(_ package: TrafficPackage,
                                                 file: StaticString = #filePath,
                                                 line: UInt = #line) {
        XCTAssertEqual(package.response?.statusCode, 200, file: file, line: line)
    }

    private func assertSelectorExists(baseClass: AnyClass,
                                      selector: Selector,
                                      name: String,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        let method = class_getInstanceMethod(baseClass, selector)
        XCTAssertNotNil(method, "Missing selector: \(name)", file: file, line: line)
        XCTAssertTrue(baseClass.instancesRespond(to: selector), "Selector not implemented: \(name)", file: file, line: line)
    }
}
