import XCTest
@testable import SpeedSentryCore

final class NetworkContextTests: XCTestCase {
    func testIncidentContextMigrationSwitchesAndExports() throws { try NetworkContextScenarios.run() }
}
