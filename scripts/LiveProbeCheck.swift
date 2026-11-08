import Foundation
@main enum LiveProbeCheck {
    static func main() async throws {
        let connection = await ConnectionProbe().measure()
        guard connection.reachable else { throw NSError(domain: "LiveConnection", code: 1) }
        print("PASS live HTTPS connection check: \(Int(connection.latencyMilliseconds ?? 0)) ms")
        let upload = await UploadProbe().measure()
        guard let rate = upload.megabitsPerSecond, rate > 0, upload.bytesSent == UploadProbe.payloadBytes else {
            throw NSError(domain: "LiveUpload", code: 1, userInfo: [NSLocalizedDescriptionKey: upload.errorDescription ?? "Invalid upload"])
        }
        print(String(format: "PASS live upload: %.2f Mbps whole-request estimate, %d bytes sent", rate, upload.bytesSent))
    }
}
