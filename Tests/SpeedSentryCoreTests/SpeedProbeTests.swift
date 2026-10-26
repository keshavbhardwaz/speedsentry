import Foundation
import XCTest
@testable import SpeedSentryCore

final class SpeedProbeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    func testStreamingMeasurementUsesWholeRequestWhenTransportMetricsAreMissing() async throws {
        let clock = TestClock([1, 2_000_000_001])
        StubURLProtocol.setHandler { stub in
            stub.respond(length: 10)
            stub.send(Data(repeating: 1, count: 4))
            stub.send(Data(repeating: 1, count: 3))
            stub.send(Data(repeating: 1, count: 3))
            stub.finish()
        }
        let result = await makeProbe(clock: clock).measure()
        XCTAssertNil(result.errorDescription)
        XCTAssertEqual(try XCTUnwrap(result.megabitsPerSecond), 0.000040, accuracy: 0.000000001)
        XCTAssertEqual(result.bytesReceived, 10)
        XCTAssertEqual(clock.callCount, 2, "Data callback cadence must not define the timing window.")
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-cache, no-store")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.timeoutInterval, 30)
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "bytes" }?.value, "10")
        XCTAssertFalse(try XCTUnwrap(query.first { $0.name == "cachebust" }?.value).isEmpty)
    }

    func testIncompleteDownloadIsUnavailableInsteadOfZeroMbps() async {
        StubURLProtocol.setHandler { stub in
            stub.respond(length: 10)
            stub.send(Data(repeating: 1, count: 4))
            stub.send(Data(repeating: 1, count: 3))
            stub.finish()
        }
        let result = await makeProbe().measure()
        XCTAssertNil(result.megabitsPerSecond)
        XCTAssertEqual(result.bytesReceived, 7)
        XCTAssertNotNil(result.errorDescription)
    }

    func testUnexpectedStatusIsUnavailableAndBodyIsNotMeasured() async {
        StubURLProtocol.setHandler { stub in
            stub.respond(status: 503, length: 10)
            stub.finish()
        }
        let result = await makeProbe().measure()
        XCTAssertNil(result.megabitsPerSecond)
        XCTAssertEqual(result.errorDescription, "Speed server returned HTTP 503.")
        XCTAssertEqual(result.bytesReceived, 0)
    }

    func testWrongContentLengthIsUnavailable() async {
        StubURLProtocol.setHandler { stub in
            stub.respond(length: 11)
            stub.finish()
        }
        let result = await makeProbe().measure()
        XCTAssertNil(result.megabitsPerSecond)
        XCTAssertEqual(result.errorDescription, "Speed server returned an unexpected sample length.")
    }

    func testCompressedResponseIsUnavailable() async {
        StubURLProtocol.setHandler { stub in
            stub.respond(length: 10, encoding: "gzip")
            stub.finish()
        }
        let result = await makeProbe().measure()
        XCTAssertNil(result.megabitsPerSecond)
        XCTAssertEqual(result.errorDescription, "Speed server returned compressed data; the sample is invalid.")
    }

    func testOfflineFailureIsDescriptive() async {
        StubURLProtocol.setHandler { stub in
            stub.fail(URLError(.notConnectedToInternet))
        }
        let result = await makeProbe().measure()
        XCTAssertNil(result.megabitsPerSecond)
        XCTAssertEqual(result.errorDescription, "No internet connection.")
    }

    func testTimeoutAfterPartialDataRemainsUnavailable() async {
        StubURLProtocol.setHandler { stub in
            stub.respond(length: 10)
            stub.send(Data(repeating: 1, count: 4))
            stub.send(Data(repeating: 1, count: 3))
            stub.fail(URLError(.timedOut))
        }
        let result = await makeProbe().measure()
        XCTAssertNil(result.megabitsPerSecond)
        XCTAssertEqual(result.bytesReceived, 7)
        XCTAssertEqual(result.errorDescription, "Speed check timed out after 30 seconds before the complete sample arrived.")
    }

    func testExcessDataIsRejected() async {
        StubURLProtocol.setHandler { stub in
            stub.respond(length: 10)
            stub.send(Data(repeating: 1, count: 11))
            stub.finish()
        }
        let result = await makeProbe().measure()
        XCTAssertNil(result.megabitsPerSecond)
        XCTAssertEqual(result.errorDescription, "Speed server sent more data than the allowed sample.")
    }

    func testOneChunkSampleUsesWholeRequestTimingInsteadOfCallbackTiming() async throws {
        StubURLProtocol.setHandler { stub in
            stub.respond(length: 10)
            stub.send(Data(repeating: 1, count: 10))
            stub.finish()
        }
        let result = await makeProbe().measure()
        XCTAssertNil(result.errorDescription)
        XCTAssertEqual(try XCTUnwrap(result.megabitsPerSecond), 0.000040, accuracy: 0.000000001)
        XCTAssertEqual(result.bytesReceived, 10)
    }

    func testBackwardsMonotonicClockCannotProduceAnInflatedSpeed() async {
        StubURLProtocol.setHandler { stub in
            stub.respond(length: 10)
            stub.send(Data(repeating: 1, count: 10))
            stub.finish()
        }
        let result = await makeProbe(clock: TestClock([2, 1])).measure()
        XCTAssertNil(result.megabitsPerSecond)
        XCTAssertEqual(result.errorDescription, ThroughputEstimationError.invalidRequestDuration.localizedDescription)
    }

    func testOverlapDoesNotStartSecondRequestAndCancellationAllowsNextCheck() async {
        let started = expectation(description: "First request started")
        StubURLProtocol.setHandler { stub in
            stub.respond(length: 10)
            started.fulfill()
            // Leave the response open until the caller cancels it.
        }
        let probe = makeProbe()
        let first = Task { await probe.measure() }
        await fulfillment(of: [started], timeout: 2)
        let overlapping = await probe.measure()
        XCTAssertEqual(overlapping.errorDescription, "A speed check is already running.")
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        probe.cancel()
        let cancelled = await first.value
        XCTAssertNil(cancelled.megabitsPerSecond)
        XCTAssertEqual(cancelled.errorDescription, "Speed check cancelled.")

        StubURLProtocol.setHandler { stub in stub.fail(URLError(.notConnectedToInternet)) }
        let next = await probe.measure()
        XCTAssertEqual(next.errorDescription, "No internet connection.")
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testTaskCancellationFinishesTheAwaitingCheck() async {
        let started = expectation(description: "Request started")
        StubURLProtocol.setHandler { stub in
            stub.respond(length: 10)
            started.fulfill()
        }
        let probe = makeProbe()
        let running = Task { await probe.measure() }
        await fulfillment(of: [started], timeout: 2)
        running.cancel()
        let result = await running.value
        XCTAssertNil(result.megabitsPerSecond)
        XCTAssertEqual(result.errorDescription, "Speed check cancelled.")
    }

    private func makeProbe(clock: TestClock = TestClock([1, 2_000_000_001])) -> SpeedProbe {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return SpeedProbe(
            configuration: configuration,
            endpoint: URL(string: "https://speed-probe.invalid/__down")!,
            expectedBytes: 10,
            nanoseconds: { clock.next() },
            transportTimingProvider: { _ in nil }
        )
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]
    private var index = 0

    init(_ values: [UInt64]) { self.values = values }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let value = values[min(index, values.count - 1)]
        index += 1
        return value
    }
}

private final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((StubURLProtocol) -> Void)?
    private static var recordedRequests: [URLRequest] = []
    private let deliveryQueue = DispatchQueue(label: "SpeedSentry.probe-test-delivery")

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequests
    }

    static func setHandler(_ handler: @escaping (StubURLProtocol) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        recordedRequests = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recordedRequests.append(request)
        let handler = Self.handler
        Self.lock.unlock()
        handler?(self)
    }

    override func stopLoading() {}

    func respond(status: Int = 200, length: Int, encoding: String? = nil) {
        var headers = ["Content-Length": String(length), "Content-Type": "application/octet-stream"]
        if let encoding { headers["Content-Encoding"] = encoding }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func send(_ data: Data) {
        deliveryQueue.async {
            self.client?.urlProtocol(self, didLoad: data)
            // URLSession can coalesce immediately adjacent URLProtocol chunks.
            // Yield between deliveries; throughput assertions use an injected
            // monotonic clock and do not depend on this wall-clock delay.
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    func finish() { deliveryQueue.async { self.client?.urlProtocolDidFinishLoading(self) } }
    func fail(_ error: Error) { deliveryQueue.async { self.client?.urlProtocol(self, didFailWithError: error) } }
}
