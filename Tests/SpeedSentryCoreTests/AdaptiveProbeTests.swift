import Foundation
import XCTest
@testable import SpeedSentryCore

final class AdaptiveProbeTests: XCTestCase {
    private let screeningBytes = 8 * 1_024 * 1_024
    private let confirmationBytes = 64 * 1_024 * 1_024

    override func setUp() {
        super.setUp()
        AdaptiveURLProtocol.reset()
    }

    func testInitial250MbpsBurstIsReplacedBy100MbpsConfirmation() async throws {
        let clock = sampleClock(screeningMbps: 250, confirmationMbps: 100)
        AdaptiveURLProtocol.setHandler { stub in
            stub.respond(length: stub.requestedBytes)
            stub.sendPayload(count: stub.requestedBytes)
            stub.finish()
        }

        let result = await makeProbe(clock: clock).measure()
        XCTAssertNil(result.errorDescription)
        XCTAssertEqual(try XCTUnwrap(result.megabitsPerSecond), 100, accuracy: 0.000_001)
        XCTAssertEqual(result.bytesReceived, screeningBytes + confirmationBytes)
        XCTAssertEqual(AdaptiveURLProtocol.requestSizes, [screeningBytes, confirmationBytes])
        XCTAssertEqual(clock.callCount, 4, "Each complete request must have one start and one end timestamp")
    }

    func testGenuine150MbpsConfirmationIsNotCappedAt100Mbps() async throws {
        let clock = sampleClock(screeningMbps: 300, confirmationMbps: 150)
        AdaptiveURLProtocol.setHandler { stub in
            stub.respond(length: stub.requestedBytes)
            stub.sendPayload(count: stub.requestedBytes)
            stub.finish()
        }

        let result = await makeProbe(clock: clock).measure()
        XCTAssertNil(result.errorDescription)
        XCTAssertEqual(try XCTUnwrap(result.megabitsPerSecond), 150, accuracy: 0.000_001)
        XCTAssertEqual(result.bytesReceived, screeningBytes + confirmationBytes)
        XCTAssertEqual(AdaptiveURLProtocol.requestSizes, [screeningBytes, confirmationBytes])
    }

    func testSlow15MbpsScreeningUsesOneSmallSample() async throws {
        let clock = sampleClock(screeningMbps: 15)
        AdaptiveURLProtocol.setHandler { stub in
            stub.respond(length: stub.requestedBytes)
            stub.sendPayload(count: stub.requestedBytes)
            stub.finish()
        }

        let result = await makeProbe(clock: clock).measure()
        XCTAssertNil(result.errorDescription)
        XCTAssertEqual(try XCTUnwrap(result.megabitsPerSecond), 15, accuracy: 0.000_001)
        XCTAssertEqual(result.bytesReceived, screeningBytes)
        XCTAssertEqual(AdaptiveURLProtocol.requestSizes, [screeningBytes])
        XCTAssertEqual(clock.callCount, 2)
    }

    func testExactlyOneSecondScreeningDoesNotTriggerConfirmation() async throws {
        let clock = AdaptiveTestClock([1, 1_000_000_001])
        AdaptiveURLProtocol.setHandler { stub in
            stub.respond(length: stub.requestedBytes)
            stub.sendPayload(count: stub.requestedBytes)
            stub.finish()
        }

        let result = await makeProbe(clock: clock).measure()
        XCTAssertNil(result.errorDescription)
        XCTAssertEqual(try XCTUnwrap(result.megabitsPerSecond), 67.108864, accuracy: 0.000_001)
        XCTAssertEqual(result.bytesReceived, screeningBytes)
        XCTAssertEqual(AdaptiveURLProtocol.requestSizes, [screeningBytes])
    }

    func testLowDataModeLeavesFastScreeningUnconfirmed() async throws {
        let clock = sampleClock(screeningMbps: 250)
        AdaptiveURLProtocol.setHandler { stub in
            stub.respond(length: stub.requestedBytes)
            stub.sendPayload(count: stub.requestedBytes)
            stub.finish()
        }

        let result = await makeProbe(clock: clock, confirmation: nil).measure()
        XCTAssertNil(result.errorDescription)
        XCTAssertEqual(try XCTUnwrap(result.megabitsPerSecond), 250, accuracy: 0.000_001)
        XCTAssertEqual(result.bytesReceived, screeningBytes)
        XCTAssertEqual(AdaptiveURLProtocol.requestSizes, [screeningBytes])
        XCTAssertEqual(clock.callCount, 2)
    }

    func testTaskCancellationDuringConfirmationReturnsNoSpeedOrExtraRequest() async {
        let confirmationStarted = expectation(description: "Confirmation request started")
        let clock = sampleClock(screeningMbps: 250, confirmationMbps: 100)
        AdaptiveURLProtocol.setHandler { stub in
            stub.respond(length: stub.requestedBytes)
            if stub.requestedBytes == self.screeningBytes {
                stub.sendPayload(count: stub.requestedBytes)
                stub.finish()
            } else {
                stub.sendPayload(count: 1_024 * 1_024)
                stub.afterDelivery { confirmationStarted.fulfill() }
            }
        }

        let probe = makeProbe(clock: clock)
        let running = Task { await probe.measure() }
        await fulfillment(of: [confirmationStarted], timeout: 5)
        running.cancel()
        let result = await running.value
        XCTAssertNil(result.megabitsPerSecond)
        XCTAssertEqual(result.errorDescription, "Speed check cancelled.")
        XCTAssertGreaterThanOrEqual(result.bytesReceived, screeningBytes)
        XCTAssertLessThanOrEqual(result.bytesReceived, screeningBytes + 1_024 * 1_024)
        XCTAssertEqual(AdaptiveURLProtocol.requestSizes, [screeningBytes, confirmationBytes])
    }

    func testExplicitCancellationDuringConfirmationDoesNotReturnInitialPeak() async {
        let confirmationStarted = expectation(description: "Confirmation request started")
        AdaptiveURLProtocol.setHandler { stub in
            stub.respond(length: stub.requestedBytes)
            if stub.requestedBytes == self.screeningBytes {
                stub.sendPayload(count: stub.requestedBytes)
                stub.finish()
            } else {
                confirmationStarted.fulfill()
            }
        }

        let probe = makeProbe(clock: sampleClock(screeningMbps: 250, confirmationMbps: 100))
        let running = Task { await probe.measure() }
        await fulfillment(of: [confirmationStarted], timeout: 5)
        probe.cancel()
        let result = await running.value
        XCTAssertNil(result.megabitsPerSecond)
        XCTAssertEqual(result.errorDescription, "Speed check cancelled.")
        XCTAssertEqual(result.bytesReceived, screeningBytes)
        XCTAssertEqual(AdaptiveURLProtocol.requestSizes, [screeningBytes, confirmationBytes])
    }

    func testFailedConfirmationReportsUnavailableWithAllReceivedBytes() async {
        AdaptiveURLProtocol.setHandler { stub in
            stub.respond(length: stub.requestedBytes)
            if stub.requestedBytes == self.screeningBytes {
                stub.sendPayload(count: stub.requestedBytes)
                stub.finish()
            } else {
                stub.sendPayload(count: 1_024 * 1_024)
                stub.fail(URLError(.timedOut))
            }
        }

        let result = await makeProbe(clock: sampleClock(screeningMbps: 250, confirmationMbps: 100)).measure()
        XCTAssertNil(result.megabitsPerSecond, "The initial burst must never substitute for a failed confirmation")
        XCTAssertNotNil(result.errorDescription)
        XCTAssertEqual(result.bytesReceived, screeningBytes + 1_024 * 1_024)
        XCTAssertEqual(AdaptiveURLProtocol.requestSizes, [screeningBytes, confirmationBytes])
    }

    private func makeProbe(clock: AdaptiveTestClock, confirmation: Int? = 64 * 1_024 * 1_024) -> SpeedProbe {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AdaptiveURLProtocol.self]
        return SpeedProbe(
            configuration: configuration,
            endpoint: URL(string: "https://adaptive-probe.invalid/__down")!,
            expectedBytes: screeningBytes,
            nanoseconds: { clock.next() },
            confirmationBytes: confirmation,
            transportTimingProvider: { _ in nil }
        )
    }

    private func sampleClock(screeningMbps: Double, confirmationMbps: Double? = nil) -> AdaptiveTestClock {
        let firstDuration = UInt64((Double(screeningBytes) * 8 / screeningMbps * 1_000).rounded())
        var times: [UInt64] = [1, 1 + firstDuration]
        if let confirmationMbps {
            let secondStart = 2 + firstDuration
            let secondDuration = UInt64((Double(confirmationBytes) * 8 / confirmationMbps * 1_000).rounded())
            times += [secondStart, secondStart + secondDuration]
        }
        return AdaptiveTestClock(times)
    }
}

private final class AdaptiveTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private let times: [UInt64]
    private var index = 0

    init(_ times: [UInt64]) { self.times = times }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return index
    }

    func next() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let time = times[min(index, times.count - 1)]
        index += 1
        return time
    }
}

private final class AdaptiveURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((AdaptiveURLProtocol) -> Void)?
    private static var recordedSizes: [Int] = []
    private let deliveryQueue = DispatchQueue(label: "SpeedSentry.adaptive-test-delivery")
    private let stateLock = NSLock()
    private var stopped = false

    var requestedBytes: Int {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        return Int(items?.first { $0.name == "bytes" }?.value ?? "") ?? 0
    }

    static var requestSizes: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSizes
    }

    static func setHandler(_ handler: @escaping (AdaptiveURLProtocol) -> Void) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        recordedSizes = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recordedSizes.append(requestedBytes)
        let handler = Self.handler
        Self.lock.unlock()
        handler?(self)
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }

    private var isStopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    func respond(length: Int) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(length), "Content-Type": "application/octet-stream", "Content-Encoding": "identity"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    func sendPayload(count: Int) {
        deliveryQueue.async {
            let chunk = Data(repeating: 1, count: min(count, 1_024 * 1_024))
            var remaining = count
            while remaining > 0, !self.isStopped {
                let size = min(remaining, chunk.count)
                self.client?.urlProtocol(self, didLoad: size == chunk.count ? chunk : chunk.prefix(size))
                remaining -= size
            }
        }
    }

    func afterDelivery(_ action: @escaping () -> Void) {
        deliveryQueue.async { if !self.isStopped { action() } }
    }

    func finish() {
        deliveryQueue.async { if !self.isStopped { self.client?.urlProtocolDidFinishLoading(self) } }
    }

    func fail(_ error: Error) {
        deliveryQueue.async { if !self.isStopped { self.client?.urlProtocol(self, didFailWithError: error) } }
    }
}
