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
        firstStore.settings.averageBitRate = 9_000_000
        firstStore.settings.multiPassStorageEnabled = true

        let restoredStore = TranscodeQueueStore(defaults: defaults)
        XCTAssertTrue(restoredStore.rememberLastSettings)
        XCTAssertEqual(restoredStore.settings.averageBitRate, 9_000_000)
        XCTAssertTrue(restoredStore.settings.multiPassStorageEnabled)
    }

    func test旧版封装字段迁移为原生字段() throws {
        let currentData = try JSONEncoder().encode(
            TranscodeSettings.defaultSettings
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: currentData) as? [String: Any]
        )
        object.removeValue(forKey: "nativeProperties")
        object["targetCodec"] = "automatic"
        object.removeValue(forKey: "multiPassStorageEnabled")
        object["multiPassMode"] = "automatic"
        object.removeValue(forKey: "averageBitRate")
        object["rateControl"] = "fixedBitRate"
        object["fixedBitRate"] = 7_500_000
        object.removeValue(forKey: "dataRateLimits")
        object["dataRateLimitMultiplier"] = 1.5
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let migrated = try JSONDecoder().decode(
            TranscodeSettings.self,
            from: legacyData
        )

        XCTAssertEqual(migrated.targetCodec, .hevc)
        XCTAssertTrue(migrated.multiPassStorageEnabled)
        XCTAssertEqual(migrated.averageBitRate, 7_500_000)
        XCTAssertEqual(migrated.dataRateLimits, [1_406_250, 1])
    }

    func test新设置不再写入旧版封装字段() throws {
        let data = try JSONEncoder().encode(
            TranscodeSettings.defaultSettings
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertNil(object["rateControl"])
        XCTAssertNil(object["sourceBitRateRatio"])
        XCTAssertNil(object["fixedBitRate"])
        XCTAssertNil(object["dataRateLimitMultiplier"])
        XCTAssertNil(object["multiPassMode"])
        XCTAssertNil(object["averageBitRate"])
        XCTAssertNil(object["multiPassStorageEnabled"])
        let nativeProperties = try XCTUnwrap(
            object["nativeProperties"] as? [String: Any]
        )
        XCTAssertEqual(
            (nativeProperties["AverageBitRate"] as? NSNumber)?.doubleValue,
            8_000_000
        )
        XCTAssertEqual(nativeProperties["AllowFrameReordering"] as? Bool, true)
    }

    func test原生键值字典往返后不改名() throws {
        var settings = TranscodeSettings.defaultSettings
        settings.selectRateControlProperty("VariableBitRate")
        settings.setNativeValue(.number(16_000_000), forKey: "VBVMaxBitRate")
        settings.setNativeValue(.number(2.5), forKey: "VBVBufferDuration")

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(
            TranscodeSettings.self,
            from: data
        )

        XCTAssertEqual(restored, settings)
        XCTAssertEqual(
            restored.nativeProperties["VariableBitRate"],
            .number(8_000_000)
        )
        XCTAssertEqual(
            restored.nativeProperties["VBVMaxBitRate"],
            .number(16_000_000)
        )
    }

    func test关闭记忆后下次恢复原生字段默认值() throws {
        let defaults = try makeDefaults()
        defer {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }

        let firstStore = TranscodeQueueStore(defaults: defaults)
        firstStore.settings.averageBitRate = 3_500_000
        firstStore.rememberLastSettings = false

        let restoredStore = TranscodeQueueStore(defaults: defaults)
        XCTAssertFalse(restoredStore.rememberLastSettings)
        XCTAssertEqual(
            restoredStore.settings,
            TranscodeSettings.defaultSettings
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
