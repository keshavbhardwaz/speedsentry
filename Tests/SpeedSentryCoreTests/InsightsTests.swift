import XCTest
@testable import SpeedSentryCore

final class InsightsTests: XCTestCase {
    func testMonitoringReportsProfilesAndHTTP() async throws { try await InsightsScenarios.run() }
}
