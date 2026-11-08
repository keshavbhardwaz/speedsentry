import XCTest
@testable import SpeedSentryCore
final class WiFiSignalTests: XCTestCase {
    func testSignalQualityAndAlertLifecycle() throws { try WiFiSignalScenarios.run() }
}
