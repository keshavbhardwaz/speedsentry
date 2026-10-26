import Darwin
import Foundation

/// A local HTTP fixture that paces real TCP payload writes against an
/// absolute monotonic schedule. It uses only 127.0.0.1 and an ephemeral port.
final class PacedLoopbackServer: @unchecked Sendable {
    struct Response: Sendable {
        let bytes: Int
        let megabitsPerSecond: Double
    }

    struct Transfer: Sendable {
        let bytesSent: Int
        let elapsedSeconds: Double
        let error: String?

        var megabitsPerSecond: Double {
            Double(bytesSent) * 8 / elapsedSeconds / 1_000_000
        }
    }

    private let listener: Int32
    private let responses: [Response]
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var completedTransfers: [Transfer] = []
    let endpoint: URL

    convenience init(bytes: Int, megabitsPerSecond: Double, onBodyStart: (@Sendable () -> Void)? = nil) throws {
        try self.init(responses: [Response(bytes: bytes, megabitsPerSecond: megabitsPerSecond)]) { _ in
            onBodyStart?()
        }
    }

    init(responses: [Response], onBodyStart: (@Sendable (Int) -> Void)? = nil) throws {
        precondition(!responses.isEmpty && responses.allSatisfy { $0.bytes > 0 && $0.megabitsPerSecond > 0 })
        self.responses = responses
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.ENOTSOCK) }
        var reuse: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(listener, 1) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(listener)
            throw error
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(listener)
            throw POSIXError(.EIO)
        }
        self.listener = listener
        self.endpoint = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))/__down")!
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            self.serve(onBodyStart: onBodyStart)
        }
    }

    deinit { Darwin.close(listener) }

    var transfer: Transfer? {
        transfers.first
    }

    var transfers: [Transfer] {
        lock.lock()
        defer { lock.unlock() }
        return completedTransfers
    }

    func waitForTransfer(timeout: TimeInterval = 1) -> Transfer? {
        waitForTransfers(count: 1, timeout: timeout)?.first
    }

    func waitForTransfers(count: Int, timeout: TimeInterval = 1) -> [Transfer]? {
        let deadline = DispatchTime.now() + timeout
        while transfers.count < count {
            guard finished.wait(timeout: deadline) == .success else { return nil }
        }
        return transfers
    }

    private func serve(onBodyStart: (@Sendable (Int) -> Void)?) {
        guard var client = acceptClient() else {
            record(bytesSent: 0, elapsedSeconds: 0, error: "No loopback request within 5 seconds.")
            return
        }
        defer { Darwin.close(client) }
        for (index, response) in responses.enumerated() {
            if index > 0 {
                // URLSession may reuse the keep-alive socket or open another.
                // Both behaviors are valid for the same URLSession instance.
                var ready = [pollfd(fd: client, events: Int16(POLLIN), revents: 0),
                             pollfd(fd: listener, events: Int16(POLLIN), revents: 0)]
                guard poll(&ready, 2, 5_000) > 0 else {
                    record(bytesSent: 0, elapsedSeconds: 0, error: "No confirmation request within 5 seconds.")
                    return
                }
                if ready[1].revents & Int16(POLLIN) != 0 || ready[0].revents & Int16(POLLHUP) != 0 {
                    guard let next = acceptClient() else {
                        record(bytesSent: 0, elapsedSeconds: 0, error: "Loopback confirmation accept failed.")
                        return
                    }
                    Darwin.close(client)
                    client = next
                }
            }
            guard readRequest(from: client) else {
                record(bytesSent: 0, elapsedSeconds: 0, error: "Loopback request read failed.")
                return
            }
            let connection = index + 1 == responses.count ? "close" : "keep-alive"
            let headers = Data("HTTP/1.1 200 OK\r\nContent-Length: \(response.bytes)\r\nContent-Type: application/octet-stream\r\nCache-Control: no-store\r\nConnection: \(connection)\r\n\r\n".utf8)
            let start = DispatchTime.now().uptimeNanoseconds
            guard writeAll(headers, to: client) else {
                record(bytesSent: 0, elapsedSeconds: 0, error: "Loopback response header write failed.")
                return
            }
            onBodyStart?(index)
            let chunk = Data(repeating: 0x5A, count: 16_384)
            let bytesPerSecond = response.megabitsPerSecond * 1_000_000 / 8
            var sent = 0
            while sent < response.bytes {
                let count = min(chunk.count, response.bytes - sent)
                let deadline = start + UInt64(Double(sent + count) / bytesPerSecond * 1_000_000_000)
                let now = DispatchTime.now().uptimeNanoseconds
                if deadline > now {
                    Thread.sleep(forTimeInterval: Double(deadline - now) / 1_000_000_000)
                }
                guard writeAll(chunk.prefix(count), to: client) else {
                    record(bytesSent: sent, elapsedSeconds: Self.seconds(since: start), error: "Loopback payload write failed.")
                    return
                }
                sent += count
            }
            record(bytesSent: sent, elapsedSeconds: Self.seconds(since: start), error: nil)
        }
    }

    private func acceptClient() -> Int32? {
        var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 5_000) > 0 else { return nil }
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return nil }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        return client
    }

    private func readRequest(from client: Int32) -> Bool {
        var request = Data()
        var readBuffer = [UInt8](repeating: 0, count: 1_024)
        while request.range(of: Data("\r\n\r\n".utf8)) == nil && request.count < 16_384 {
            let count = Darwin.recv(client, &readBuffer, readBuffer.count, 0)
            guard count > 0 else {
                return false
            }
            request.append(contentsOf: readBuffer.prefix(count))
        }
        return request.range(of: Data("\r\n\r\n".utf8)) != nil
    }

    private func writeAll(_ data: Data, to socket: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            var sent = 0
            while sent < data.count {
                let count = Darwin.send(socket, base.advanced(by: sent), data.count - sent, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    private static func seconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    private func record(bytesSent: Int, elapsedSeconds: Double, error: String?) {
        lock.lock()
        completedTransfers.append(Transfer(bytesSent: bytesSent, elapsedSeconds: elapsedSeconds, error: error))
        lock.unlock()
        finished.signal()
    }
}
