import Foundation
import XCTest
@testable import VideoToolboxStudio

@MainActor
final class InstallationStateTests: XCTestCase {
    func testStatePersistsAcrossAppUpdates() throws {
        let suiteName = "InstallationStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let firstLaunch = InstallationState(defaults: defaults)
        let secondLaunch = InstallationState(defaults: defaults)

        XCTAssertEqual(firstLaunch.installationIdentifier, secondLaunch.installationIdentifier)
        XCTAssertEqual(firstLaunch.launchCount, 1)
        XCTAssertEqual(secondLaunch.launchCount, 2)
    }
}
