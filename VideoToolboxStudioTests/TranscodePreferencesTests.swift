import Foundation
import XCTest
@testable import VideoToolboxStudio

@MainActor
final class TranscodePreferencesTests: XCTestCase {
    func test默认记住并恢复最近编码参数() throws {
        let defaults = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }

        let firstStore = TranscodeQueueStore(defaults: defaults)
        XCTAssertTrue(firstStore.rememberLastSettings)
        firstStore.settings.sourceBitRateRatio = 0.85
        firstStore.settings.encodingQuality = .refined
        firstStore.markCustom()

        let restoredStore = TranscodeQueueStore(defaults: defaults)
        XCTAssertTrue(restoredStore.rememberLastSettings)
        XCTAssertEqual(restoredStore.selectedPreset, .custom)
        XCTAssertEqual(restoredStore.settings.sourceBitRateRatio, 0.85)
        XCTAssertEqual(restoredStore.settings.encodingQuality, .refined)
    }

    func test关闭记忆后下次恢复均衡默认参数() throws {
        let defaults = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }

        let firstStore = TranscodeQueueStore(defaults: defaults)
        firstStore.settings.sourceBitRateRatio = 0.35
        firstStore.markCustom()
        firstStore.rememberLastSettings = false

        let restoredStore = TranscodeQueueStore(defaults: defaults)
        XCTAssertFalse(restoredStore.rememberLastSettings)
        XCTAssertEqual(restoredStore.selectedPreset, .balanced)
        XCTAssertEqual(
            restoredStore.settings,
            TranscodePreset.balanced.settings
        )
    }

    private var defaultsSuiteName: String {
        "TranscodePreferencesTests"
    }

    private func makeDefaults() throws -> UserDefaults {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: defaultsSuiteName)
        )
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }
}
