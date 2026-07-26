import CoreMedia
import XCTest
@testable import VideoToolboxStudio

final class TranscodeSettingsTests: XCTestCase {
    func test所有内置模板参数合法() throws {
        for preset in TranscodePreset.allCases where preset != .custom {
            XCTAssertNoThrow(try preset.settings.validate(), preset.title)
        }
    }

    func test源码率比例会解析为平均码率() {
        let source = makeVideoSummary(
            bitRate: 10_000_000,
            frameRate: 30,
            isHDR: false
        )
        var settings = TranscodeSettings.balanced
        settings.sourceBitRateRatio = 0.6

        let resolved = VideoTranscoder.resolve(
            settings: settings,
            sourceVideo: source,
            codecType: kCMVideoCodecType_HEVC,
            isHDR: false
        )

        XCTAssertEqual(resolved.averageBitRate, 6_000_000)
        XCTAssertNil(resolved.quality)
        XCTAssertEqual(resolved.maxKeyFrameInterval, 0)
        XCTAssertEqual(resolved.maxKeyFrameIntervalDuration, 2)
        XCTAssertEqual(resolved.codecFourCC, "hvc1")
    }

    func test质量模式不同时设置平均码率() {
        let source = makeVideoSummary(
            bitRate: 10_000_000,
            frameRate: 60,
            isHDR: false
        )
        var settings = TranscodeSettings.balanced
        settings.rateControl = .quality
        settings.quality = 0.83

        let resolved = VideoTranscoder.resolve(
            settings: settings,
            sourceVideo: source,
            codecType: kCMVideoCodecType_HEVC,
            isHDR: false
        )

        XCTAssertNil(resolved.averageBitRate)
        XCTAssertEqual(resolved.quality, 0.83)
        XCTAssertEqual(resolved.dataRateLimits, [1_875_000, 1])
    }

    func test质量模式峰值限制相对原视频平均码率() {
        let source = makeVideoSummary(
            bitRate: 12_000_000,
            frameRate: 30,
            isHDR: false
        )
        var settings = TranscodeSettings.balanced
        settings.rateControl = .quality
        settings.dataRateLimitMultiplier = 1.25

        let resolved = VideoTranscoder.resolve(
            settings: settings,
            sourceVideo: source,
            codecType: kCMVideoCodecType_HEVC,
            isHDR: false
        )

        XCTAssertEqual(resolved.dataRateLimits, [1_875_000, 1])
    }

    func test两个关键帧约束保持独立() {
        let source = makeVideoSummary(
            bitRate: 10_000_000,
            frameRate: 60,
            isHDR: false
        )
        var settings = TranscodeSettings.balanced
        settings.maxKeyFrameInterval = 90
        settings.maxKeyFrameIntervalDuration = 2

        let resolved = VideoTranscoder.resolve(
            settings: settings,
            sourceVideo: source,
            codecType: kCMVideoCodecType_HEVC,
            isHDR: false
        )

        XCTAssertEqual(resolved.maxKeyFrameInterval, 90)
        XCTAssertEqual(resolved.maxKeyFrameIntervalDuration, 2)
    }

    func test精细编码请求前向分析并保持目标码率() {
        let source = makeVideoSummary(
            bitRate: 10_000_000,
            frameRate: 30,
            isHDR: false
        )
        var settings = TranscodeSettings.balanced
        settings.encodingQuality = .refined

        let resolved = VideoTranscoder.resolve(
            settings: settings,
            sourceVideo: source,
            codecType: kCMVideoCodecType_HEVC,
            isHDR: false
        )

        XCTAssertEqual(resolved.encodingQuality, .refined)
        XCTAssertEqual(resolved.averageBitRate, 6_000_000)
        XCTAssertEqual(resolved.suggestedLookAheadFrameCount, 60)
    }

    func test精细编码拒绝实时或速度优先() {
        var realTimeSettings = TranscodeSettings.balanced
        realTimeSettings.encodingQuality = .refined
        realTimeSettings.realTime = true
        XCTAssertThrowsError(try realTimeSettings.validate())

        var speedSettings = TranscodeSettings.balanced
        speedSettings.encodingQuality = .refined
        speedSettings.prioritizeEncodingSpeedOverQuality = true
        XCTAssertThrowsError(try speedSettings.validate())
    }

    func testHDR输入拒绝H264() {
        XCTAssertThrowsError(
            try TranscodeTargetCodec.h264.resolvedCodecType(isHDR: true)
        ) { error in
            XCTAssertEqual(error as? TranscodeError, .hdrRequiresHEVC)
        }
    }

    func testHDR自动模式解析为HEVCMain10() throws {
        let source = makeVideoSummary(
            bitRate: 20_000_000,
            frameRate: 30,
            isHDR: true
        )
        let codec = try TranscodeTargetCodec.automatic
            .resolvedCodecType(isHDR: true)
        let resolved = VideoTranscoder.resolve(
            settings: .balanced,
            sourceVideo: source,
            codecType: codec,
            isHDR: true
        )

        XCTAssertEqual(codec, kCMVideoCodecType_HEVC)
        XCTAssertTrue(resolved.profileLevel.localizedCaseInsensitiveContains("main10"))
    }

    private func makeVideoSummary(
        bitRate: Double,
        frameRate: Double,
        isHDR: Bool
    ) -> MediaTrackSummary {
        MediaTrackSummary(
            trackID: 1,
            mediaType: "vide",
            codecType: kCMVideoCodecType_H264,
            codecFourCC: "avc1",
            naturalWidth: 1_920,
            naturalHeight: 1_080,
            nominalFrameRate: frameRate,
            estimatedDataRate: bitRate,
            timeRangeStartSeconds: 0,
            timeRangeDurationSeconds: 10,
            naturalTimeScale: 60_000,
            preferredTransform: MatrixSummary(
                a: 1,
                b: 0,
                c: 0,
                d: 1,
                tx: 0,
                ty: 0
            ),
            languageCode: nil,
            extendedLanguageTag: nil,
            color: MediaColorSummary(
                colorPrimaries: isHDR ? "ITU_R_2020" : "ITU_R_709_2",
                transferFunction: isHDR ? "SMPTE_ST_2084_PQ" : "ITU_R_709_2",
                yCbCrMatrix: isHDR ? "ITU_R_2020" : "ITU_R_709_2",
                bitsPerComponent: isHDR ? 10 : 8,
                masteringDisplayColorVolume: nil,
                contentLightLevelInfo: nil
            ),
            metadata: []
        )
    }
}
