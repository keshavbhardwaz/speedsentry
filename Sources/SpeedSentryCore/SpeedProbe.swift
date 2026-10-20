import Foundation

/// A bounded download check. Results estimate throughput to Cloudflare, not a
/// guarantee of the speed available to every service on the internet.
public final class SpeedProbe: @unchecked Sendable {
    public static let downloadBytes = 8 * 1_024 * 1_024
    public static let warmupBytes = 512 * 1_024

    private let lock = NSLock()
    private var activeOperation: ProbeOperation?
    private let configuration: URLSessionConfiguration
    private let endpoint: URL
    private let expectedBytes: Int
    private let warmupBytes: Int
    private let nanoseconds: @Sendable () -> UInt64

    public convenience init() {
        self.init(
            configuration: .ephemeral,
            endpoint: URL(string: "https://speed.cloudflare.com/__down")!,
            expectedBytes: Self.downloadBytes,
            warmupBytes: Self.warmupBytes
        )
    }

    // Injection is intentionally internal: production always uses the bounded
    // Cloudflare check, while tests can exercise the complete delegate lifecycle.
    init(
        configuration: URLSessionConfiguration,
        endpoint: URL,
        expectedBytes: Int,
        warmupBytes: Int,
        nanoseconds: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }
    ) {
        precondition(expectedBytes > warmupBytes && warmupBytes > 0)
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
        self.warmupBytes = warmupBytes
        self.nanoseconds = nanoseconds
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
                    warmupBytes: self.warmupBytes,
                    nanoseconds: self.nanoseconds
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
        request.setValue("SpeedSentry/0.1.0", forHTTPHeaderField: "User-Agent")
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
    private let expectedBytes: Int
    private let warmupBytes: Int
    private let nanoseconds: @Sendable () -> UInt64
    private var completion: ((ProbeOperation, Measurement) -> Void)?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var completed = false
    private var receivedValidResponse = false
    private var bytesReceived = 0
    private var sampleStartBytes = 0
    private var sampleStartNanoseconds: UInt64?
    private var lastDataNanoseconds: UInt64?

    init(
        configuration: URLSessionConfiguration,
        request: URLRequest,
        expectedBytes: Int,
        warmupBytes: Int,
        nanoseconds: @escaping @Sendable () -> UInt64,
        completion: @escaping (ProbeOperation, Measurement) -> Void
    ) {
        self.configuration = configuration
        self.request = request
        self.expectedBytes = expectedBytes
        self.warmupBytes = warmupBytes
        self.nanoseconds = nanoseconds
        self.completion = completion
    }

    func start() {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
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
        lock.lock()
        let isComplete = completed
        if error == nil && !isComplete { receivedValidResponse = true }
        lock.unlock()
        completionHandler(error == nil && !isComplete ? .allow : .cancel)
        if let error { finish(error: error) }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        // Only byte counters are retained; the download is never accumulated in
        // a Data buffer or written to disk.
        let wouldOverflow = data.count > expectedBytes - bytesReceived
        if wouldOverflow {
            lock.unlock()
            finish(error: "Speed server sent more data than the allowed sample.")
            return
        }
        bytesReceived += data.count
        let now = nanoseconds()
        lastDataNanoseconds = now
        if sampleStartNanoseconds == nil && bytesReceived >= warmupBytes {
            sampleStartNanoseconds = now
            sampleStartBytes = bytesReceived
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(error: Self.describe(error))
        } else {
            finish(error: nil)
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
        finish(error: "Speed server redirected the request; the sample is invalid.")
    }

    private func finish(error: String?) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        var description = error
        var speed: Double?
        if description == nil {
            if !receivedValidResponse || bytesReceived != expectedBytes {
                description = "Speed check ended before the complete sample arrived."
            } else if let start = sampleStartNanoseconds, let end = lastDataNanoseconds,
                      end > start, bytesReceived > sampleStartBytes {
                let seconds = Double(end - start) / 1_000_000_000
                speed = Double(bytesReceived - sampleStartBytes) * 8 / seconds / 1_000_000
            } else {
                description = "Speed sample was too short to measure reliably."
            }
        }
        let result = Measurement(
            timestamp: Date(),
            megabitsPerSecond: speed,
            bytesReceived: bytesReceived,
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
