import Foundation

struct SmallHTTPResult: Sendable {
    let status: Int?
    let bytesSent: Int64
    let duration: TimeInterval
    let error: String?
    var succeeded: Bool { error == nil && status.map { (200..<300).contains($0) } == true }
}

/// A bounded response sink shared by small connection checks and explicit uploads.
final class SmallHTTPTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let configuration: URLSessionConfiguration
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<SmallHTTPResult, Never>?
    private var finished = false
    private var received = 0
    private var status: Int?
    private var started = DispatchTime.now().uptimeNanoseconds
    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.configuration.urlCache = nil; self.configuration.httpCookieStorage = nil
        self.configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration.waitsForConnectivity = false
    }
    func run(_ request: URLRequest) async -> SmallHTTPResult {
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                lock.lock()
                if finished || Task.isCancelled {
                    lock.unlock(); continuation.resume(returning: SmallHTTPResult(status: nil, bytesSent: 0, duration: 0, error: "Cancelled")); return
                }
                self.continuation = continuation
                configuration.timeoutIntervalForResource = request.timeoutInterval
                configuration.timeoutIntervalForRequest = request.timeoutInterval
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request); self.task = task
                started = DispatchTime.now().uptimeNanoseconds
                lock.unlock(); task.resume()
            }
        }, onCancel: { self.finish(error: "Cancelled") })
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let code = (response as? HTTPURLResponse)?.statusCode
        lock.lock(); status = code; lock.unlock()
        let valid = code.map { (200..<300).contains($0) } == true && response.expectedContentLength <= 16_384
        completionHandler(valid ? .allow : .cancel)
        if !valid { finish(error: "Unexpected HTTP response (\(code ?? 0))") }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); received += data.count; let overflow = received > 16_384; lock.unlock()
        if overflow { finish(error: "Response exceeded 16 KiB") }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil); finish(error: "Redirect rejected")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finish(error: error?.localizedDescription) }
    private func finish(error: String?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        let result = SmallHTTPResult(status: status, bytesSent: task?.countOfBytesSent ?? 0, duration: elapsed, error: error)
        let continuation = self.continuation, session = self.session
        self.continuation = nil; self.session = nil; self.task = nil
        lock.unlock()
        session?.invalidateAndCancel(); continuation?.resume(returning: result)
    }
}

public struct ConnectionProbe: Sendable {
    let endpoints: [URL]
    let configuration: URLSessionConfiguration
    public init() {
        endpoints = [URL(string: "https://speed.cloudflare.com/__down?bytes=0")!, URL(string: "https://www.apple.com/library/test/success.html")!]
        configuration = .ephemeral
    }
    init(endpoints: [URL], configuration: URLSessionConfiguration) { self.endpoints = endpoints; self.configuration = configuration }
    public func measure() async -> ConnectionSample {
        // Probe a second provider only when the first fails. One provider failure cannot declare an outage.
        for endpoint in endpoints {
            if Task.isCancelled { break }
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "cachebust", value: UUID().uuidString)]
            var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
            let result = await SmallHTTPTransfer(configuration: configuration).run(request)
            if result.succeeded { return ConnectionSample(latencyMilliseconds: result.duration * 1000, reachable: true) }
        }
        return ConnectionSample(latencyMilliseconds: nil, reachable: false)
    }
}

public struct UploadProbe: Sendable {
    public static let payloadBytes = 4 * 1_024 * 1_024
    public init() {}
    public func measure() async -> UploadSample {
        var request = URLRequest(url: URL(string: "https://speed.cloudflare.com/__up")!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        // No personal files leave the Mac. TLS does not compress this generated payload.
        request.httpBody = Data(repeating: 0xA5, count: Self.payloadBytes)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let result = await SmallHTTPTransfer().run(request)
        let speed = Self.rate(result, expectedBytes: Self.payloadBytes)
        return UploadSample(megabitsPerSecond: speed, bytesSent: Int(result.bytesSent), errorDescription: speed == nil ? (result.error ?? "Incomplete upload or invalid timing") : nil)
    }
    static func rate(_ result: SmallHTTPResult, expectedBytes: Int) -> Double? {
        guard result.succeeded, result.bytesSent == Int64(expectedBytes), result.duration.isFinite, result.duration >= 0.001 else { return nil }
        return Double(expectedBytes) * 8 / result.duration / 1_000_000
    }
}
