import Foundation

/// A bounded download check. Results estimate throughput to Cloudflare, not a
/// guarantee of the speed available to every service on the internet.
public final class SpeedProbe: @unchecked Sendable {
    public static let downloadBytes = 8 * 1_024 * 1_024
    public static let confirmationDownloadBytes = 64 * 1_024 * 1_024

    private let lock = NSLock()
    private var activeOperation: ProbeOperation?
    private let configuration: URLSessionConfiguration
    private let endpoint: URL
    private let expectedBytes: Int
    private let nanoseconds: @Sendable () -> UInt64
    private let delegateQueue: OperationQueue?
    private let confirmationBytes: Int?
    private let transportTimingProvider: (@Sendable (URLSessionTaskMetrics) -> TransportTiming?)?

    public convenience init(lowDataMode: Bool = false) {
        self.init(
            configuration: .ephemeral,
            endpoint: URL(string: "https://speed.cloudflare.com/__down")!,
            expectedBytes: Self.downloadBytes,
            confirmationBytes: lowDataMode ? nil : Self.confirmationDownloadBytes
        )
    }

    // Injection is intentionally internal: production always uses the bounded
    // Cloudflare check, while tests can exercise the complete delegate lifecycle.
    init(
        configuration: URLSessionConfiguration,
        endpoint: URL,
        expectedBytes: Int,
        nanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        delegateQueue: OperationQueue? = nil,
        confirmationBytes: Int? = nil,
        transportTimingProvider: (@Sendable (URLSessionTaskMetrics) -> TransportTiming?)? = nil
    ) {
        precondition(expectedBytes > 0)
        precondition(confirmationBytes.map { $0 > 0 } ?? true)
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        self.configuration = configuration
        self.endpoint = endpoint
        self.expectedBytes = expectedBytes
        self.nanoseconds = nanoseconds
        self.delegateQueue = delegateQueue
        self.confirmationBytes = confirmationBytes
        self.transportTimingProvider = transportTimingProvider
    }

    /// Overlapping calls return an unavailable result and never start a second
    /// transfer. An incomplete or timed-out sample is also unavailable: it must
    /// not be reported as a fabricated zero-Mbps reading.
    public func measure() async -> Measurement {
        let cancellation = MeasurementCancellation()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: Self.failure("Speed check cancelled."))
                    return
                }
                self.lock.lock()
                guard self.activeOperation == nil else {
                    self.lock.unlock()
                    continuation.resume(returning: Self.failure("A speed check is already running."))
                    return
                }
                let operation = ProbeOperation(
                    configuration: self.configuration,
                    request: self.makeRequest(),
                    expectedBytes: self.expectedBytes,
                    nanoseconds: self.nanoseconds,
                    delegateQueue: self.delegateQueue,
                    confirmationBytes: self.confirmationBytes,
                    transportTimingProvider: self.transportTimingProvider
                ) { [weak self] operation, measurement in
                    if let self {
                        self.lock.lock()
                        if self.activeOperation === operation {
                            self.activeOperation = nil
                        }
                        self.lock.unlock()
                    }
                    continuation.resume(returning: measurement)
                }
                self.activeOperation = operation
                self.lock.unlock()
                // Bind cancellation to this call, so cancelling an older caller
                // can never cancel a newer check on the same SpeedProbe.
                cancellation.install(operation)
                operation.start()
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }

    /// Stops the active check, if any. The awaiting caller always receives one
    /// unavailable result even when cancellation races the final network callback.
    public func cancel() {
        lock.lock()
        let operation = activeOperation
        lock.unlock()
        operation?.cancel()
    }

    private func makeRequest() -> URLRequest {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "bytes" || $0.name == "cachebust" }
        query.append(URLQueryItem(name: "bytes", value: String(expectedBytes)))
        query.append(URLQueryItem(name: "cachebust", value: UUID().uuidString))
        components.queryItems = query
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("SpeedSentry/0.1.1", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func failure(_ description: String) -> Measurement {
        Measurement(timestamp: Date(), megabitsPerSecond: nil, bytesReceived: 0, errorDescription: description)
    }
}

/// Handles the race between task cancellation and installing its operation.
private final class MeasurementCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private weak var operation: ProbeOperation?
    private var cancelled = false

    func install(_ operation: ProbeOperation) {
        lock.lock()
        self.operation = operation
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { operation.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let operation = operation
        lock.unlock()
        operation?.cancel()
    }
}

private final class ProbeOperation: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private let request: URLRequest
    private var expectedBytes: Int
    private let nanoseconds: @Sendable () -> UInt64
    private let delegateQueue: OperationQueue?
    private let confirmationBytes: Int?
    private let transportTimingProvider: (@Sendable (URLSessionTaskMetrics) -> TransportTiming?)?
    private var completion: ((ProbeOperation, Measurement) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var completed = false
    private var receivedValidResponse = false
    private var bytesReceived = 0
    private var totalBytesReceived = 0
    private var isConfirmation = false
    private var requestStartNanoseconds: UInt64?
    private var transportTiming: TransportTiming?

    init(
        configuration: URLSessionConfiguration,
        request: URLRequest,
        expectedBytes: Int,
        nanoseconds: @escaping @Sendable () -> UInt64,
        delegateQueue: OperationQueue?,
        confirmationBytes: Int?,
        transportTimingProvider: (@Sendable (URLSessionTaskMetrics) -> TransportTiming?)?,
        completion: @escaping (ProbeOperation, Measurement) -> Void
    ) {
        self.configuration = configuration
        self.request = request
        self.expectedBytes = expectedBytes
        self.nanoseconds = nanoseconds
        self.delegateQueue = delegateQueue
        self.confirmationBytes = confirmationBytes
        self.transportTimingProvider = transportTimingProvider
        self.completion = completion
    }

    func start() {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        requestStartNanoseconds = nanoseconds()
        lock.unlock()
        task.resume()
    }

    func cancel() { finish(error: "Speed check cancelled.") }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        guard !completed, dataTask.taskIdentifier == task?.taskIdentifier else {
            lock.unlock()
            completionHandler(.cancel)
            return
        }
        let error: String?
        if let response = response as? HTTPURLResponse {
            if response.statusCode != 200 {
                error = "Speed server returned HTTP \(response.statusCode)."
            } else if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"),
                      !encoding.isEmpty && encoding.lowercased() != "identity" {
                error = "Speed server returned compressed data; the sample is invalid."
            } else if response.expectedContentLength != Int64(expectedBytes) {
                error = "Speed server returned an unexpected sample length."
            } else {
                error = nil
            }
        } else {
            error = "Speed server returned an invalid HTTP response."
        }
        if error == nil { receivedValidResponse = true }
        lock.unlock()
        completionHandler(error == nil ? .allow : .cancel)
        if let error { finish(error: error, taskIdentifier: dataTask.taskIdentifier) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !completed, dataTask.taskIdentifier == task?.taskIdentifier else { lock.unlock(); return }
        // Only byte counters are retained; the download is never accumulated in
        // a Data buffer or written to disk.
        let wouldOverflow = data.count > expectedBytes - bytesReceived
        if wouldOverflow {
            lock.unlock()
            finish(error: "Speed server sent more data than the allowed sample.", taskIdentifier: dataTask.taskIdentifier)
            return
        }
        bytesReceived += data.count
        totalBytesReceived += data.count
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed, task.taskIdentifier == self.task?.taskIdentifier else { return }
        if let transportTimingProvider {
            transportTiming = transportTimingProvider(metrics)
            return
        }
        let transactions = metrics.transactionMetrics
        // Custom URLProtocol implementations may supply no transport metrics.
        // In that case only the full monotonic request interval is safe to use.
        guard let transaction = transactions.last else { return }
        let duration = transaction.responseStartDate.flatMap { start in
            transaction.responseEndDate.map { $0.timeIntervalSince(start) }
        } ?? .nan
        transportTiming = TransportTiming(
            durationSeconds: duration,
            bytesReceived: transaction.countOfResponseBodyBytesAfterDecoding,
            isNetworkLoad: transaction.resourceFetchType == .networkLoad,
            transactionCount: transactions.count
        )
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(error: Self.describe(error), taskIdentifier: task.taskIdentifier)
        } else {
            finish(error: nil, taskIdentifier: task.taskIdentifier)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
        finish(error: "Speed server redirected the request; the sample is invalid.", taskIdentifier: task.taskIdentifier)
    }

    private func finish(error: String?, taskIdentifier: Int? = nil) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        if let taskIdentifier, taskIdentifier != task?.taskIdentifier { lock.unlock(); return }
        var description = error
        var speed: Double?
        if description == nil {
            if !receivedValidResponse || bytesReceived != expectedBytes {
                description = "Speed check ended before the complete sample arrived."
            } else {
                let end = nanoseconds()
                let elapsed = requestStartNanoseconds.flatMap { start in
                    end > start ? Double(end - start) / 1_000_000_000 : nil
                } ?? .nan
                do {
                    // Network response metrics cover ALL payload bytes, including
                    // those buffered before the delegate receives its first chunk.
                    let estimate = try ThroughputEstimator.estimate(
                        bytesReceived: bytesReceived,
                        requestDurationSeconds: elapsed,
                        transport: transportTiming
                    )
                    if !isConfirmation, let confirmationBytes, estimate.durationSeconds < 1,
                       let session {
                        // Short transfers can consume an ISP's burst allowance.
                        // Confirm fast results with a longer transfer on this session.
                        // Report that transfer's rate while accounting for all traffic.
                        var nextRequest = request
                        var url = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                        var query = url.queryItems ?? []
                        query.removeAll { $0.name == "bytes" || $0.name == "cachebust" }
                        query.append(URLQueryItem(name: "bytes", value: String(confirmationBytes)))
                        query.append(URLQueryItem(name: "cachebust", value: UUID().uuidString))
                        url.queryItems = query
                        nextRequest.url = url.url!
                        let nextTask = session.dataTask(with: nextRequest)
                        task = nextTask
                        expectedBytes = confirmationBytes
                        bytesReceived = 0
                        receivedValidResponse = false
                        transportTiming = nil
                        isConfirmation = true
                        requestStartNanoseconds = nanoseconds()
                        lock.unlock()
                        nextTask.resume()
                        return
                    }
                    speed = estimate.megabitsPerSecond
                } catch {
                    description = error.localizedDescription
                }
            }
        }
        completed = true
        let result = Measurement(
            timestamp: Date(),
            megabitsPerSecond: speed,
            bytesReceived: totalBytesReceived,
            errorDescription: description
        )
        let completion = self.completion
        self.completion = nil
        let task = self.task
        let session = self.session
        self.task = nil
        self.session = nil
        lock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
        completion?(self, result)
    }

    private static func describe(_ error: Error) -> String {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else {
            return "Speed check failed: \(error.localizedDescription)"
        }
        switch error.code {
        case NSURLErrorNotConnectedToInternet:
            return "No internet connection."
        case NSURLErrorNetworkConnectionLost:
            return "The internet connection was lost during the speed check."
        case NSURLErrorTimedOut:
            return "Speed check timed out after 30 seconds before the complete sample arrived."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed, NSURLErrorCannotConnectToHost:
            return "The speed server could not be reached."
        case NSURLErrorCancelled:
            return "Speed check cancelled."
        default:
            return "Speed check failed: \(error.localizedDescription)"
        }
    }
}
