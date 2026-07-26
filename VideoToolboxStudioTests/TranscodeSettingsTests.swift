import CoreMedia
import VideoToolbox
import XCTest
@testable import VideoToolboxStudio

final class TranscodeSettingsTests: XCTestCase {
    func test默认原生参数合法() throws {
        XCTAssertNoThrow(try TranscodeSettings.defaultSettings.validate())
    }

    func test平均码率直接写入解析结果() {
        let source = makeVideoSummary(
            bitRate: 10_000_000,
            frameRate: 30,
            isHDR: false
        )
        var settings = TranscodeSettings.defaultSettings
        settings.averageBitRate = 7_500_000

        let resolved = VideoTranscoder.resolve(
            settings: settings,
            sourceVideo: source,
            codecType: kCMVideoCodecType_HEVC,
            isHDR: false
        )

        XCTAssertEqual(resolved.averageBitRate, 7_500_000)
        XCTAssertNil(resolved.quality)
        XCTAssertEqual(resolved.maxKeyFrameInterval, 0)
        XCTAssertEqual(resolved.maxKeyFrameIntervalDuration, 0)
        XCTAssertEqual(resolved.codecFourCC, "hvc1")
    }

    func test质量直接写入且不设置平均码率() {
        let source = makeVideoSummary(
            bitRate: 10_000_000,
            frameRate: 60,
            isHDR: false
        )
        var settings = TranscodeSettings.defaultSettings
        settings.averageBitRate = nil
        settings.quality = 0.83

        let resolved = VideoTranscoder.resolve(
            settings: settings,
            sourceVideo: source,
            codecType: kCMVideoCodecType_HEVC,
            isHDR: false
        )

        XCTAssertNil(resolved.averageBitRate)
        XCTAssertEqual(resolved.quality, 0.83)
        XCTAssertNil(resolved.dataRateLimits)
    }

    func test数据速率限制不再经过倍数换算() {
        let source = makeVideoSummary(
            bitRate: 12_000_000,
            frameRate: 30,
            isHDR: false
        )
        var settings = TranscodeSettings.defaultSettings
        settings.dataRateLimits = [1_875_000, 2]

        let resolved = VideoTranscoder.resolve(
            settings: settings,
            sourceVideo: source,
            codecType: kCMVideoCodecType_HEVC,
            isHDR: false
        )

        XCTAssertEqual(resolved.dataRateLimits, [1_875_000, 2])
        XCTAssertEqual(
            resolved.nativeProperties["DataRateLimits"],
            .array([.number(1_875_000), .number(2)])
        )
    }

    func test平均码率和质量不能同时设置() {
        var settings = TranscodeSettings.defaultSettings
        settings.averageBitRate = 8_000_000
        settings.quality = 0.8

        XCTAssertThrowsError(try settings.validate())
    }

    func test互斥码率选择只保留一个原生字段() throws {
        var settings = TranscodeSettings.defaultSettings
        settings.dataRateLimits = [1_000_000, 1]

        settings.selectRateControlProperty("VariableBitRate")

        XCTAssertNil(settings.nativeProperties["AverageBitRate"])
        XCTAssertNil(settings.nativeProperties["DataRateLimits"])
        XCTAssertEqual(
            settings.nativeProperties["VariableBitRate"],
            .number(8_000_000)
        )
        XCTAssertNoThrow(try settings.validate())
    }

    func testVBV字段只跟随CBR或VBR显示语义() {
        var settings = TranscodeSettings.defaultSettings
        settings.setNativeValue(
            .number(2.5),
            forKey: "VBVBufferDuration"
        )
        XCTAssertThrowsError(try settings.validate())

        settings.selectRateControlProperty("ConstantBitRate")
        settings.setNativeValue(
            .number(2.5),
            forKey: "VBVBufferDuration"
        )
        XCTAssertNoThrow(try settings.validate())

        settings.setNativeValue(
            .number(12_000_000),
            forKey: "VBVMaxBitRate"
        )
        XCTAssertThrowsError(try settings.validate())

        settings.selectRateControlProperty("VariableBitRate")
        settings.setNativeValue(
            .number(12_000_000),
            forKey: "VBVMaxBitRate"
        )
        XCTAssertNoThrow(try settings.validate())
    }

    func test切换编码器移除互斥专属字段() {
        var settings = TranscodeSettings.defaultSettings
        settings.selectCodec(.h264)
        settings.setNativeValue(.string("CABAC"), forKey: "H264EntropyMode")

        settings.selectCodec(.hevc)

        XCTAssertNil(settings.nativeProperties["H264EntropyMode"])
    }

    func test只读原生字段不能写入() {
        var settings = TranscodeSettings.defaultSettings
        settings.setNativeValue(
            .bool(true),
            forKey: "UsingHardwareAcceleratedVideoEncoder"
        )

        XCTAssertThrowsError(try settings.validate())
    }

    func test原生参数目录没有重复键且说明含完整配置名() {
        let descriptors = NativeCompressionPropertyCatalog.descriptors
        XCTAssertEqual(
            Set(descriptors.map(\.key)).count,
            descriptors.count
        )
        XCTAssertTrue(
            descriptors.allSatisfy {
                $0.helpMessage.contains(
                    "kVTCompressionPropertyKey_\($0.key)"
                )
            }
        )
    }

    func test原生参数目录覆盖80个iPhone公开字段() {
        let expectedKeys: Set<String> = [
            "AverageBitRate",
            "ConstantBitRate",
            "VariableBitRate",
            "Quality",
            "ConstantQualityFactor",
            "DataRateLimits",
            "VBVMaxBitRate",
            "VBVBufferDuration",
            "VBVInitialDelayPercentage",
            "MaxKeyFrameInterval",
            "MaxKeyFrameIntervalDuration",
            "AllowTemporalCompression",
            "AllowFrameReordering",
            "AllowOpenGOP",
            "MoreFramesBeforeStart",
            "MoreFramesAfterEnd",
            "MaxFrameDelayCount",
            "MaxH264SliceBytes",
            "RealTime",
            "MaximizePowerEfficiency",
            "MaximumRealTimeFrameRate",
            "PrioritizeEncodingSpeedOverQuality",
            "MultiPassStorage",
            "SourceFrameCount",
            "ExpectedFrameRate",
            "ExpectedDuration",
            "BaseLayerFrameRate",
            "BaseLayerFrameRateFraction",
            "BaseLayerBitRateFraction",
            "EnableLTR",
            "MaxAllowedFrameQP",
            "MinAllowedFrameQP",
            "ProfileLevel",
            "H264EntropyMode",
            "Depth",
            "OutputBitDepth",
            "CalculateMeanSquaredError",
            "EncoderID",
            "CleanAperture",
            "PixelAspectRatio",
            "FieldCount",
            "FieldDetail",
            "AspectRatio16x9",
            "ProgressiveScan",
            "ColorPrimaries",
            "TransferFunction",
            "YCbCrMatrix",
            "ICCProfile",
            "GammaLevel",
            "PixelTransferProperties",
            "PreserveAlphaChannel",
            "TargetQualityForAlpha",
            "AlphaChannelMode",
            "HDRMetadataInsertionMode",
            "PreserveDynamicHDRMetadata",
            "MasteringDisplayColorVolume",
            "ContentLightLevelInfo",
            "ProjectionKind",
            "ViewPackingKind",
            "MVHEVCVideoLayerIDs",
            "MVHEVCViewIDs",
            "MVHEVCLeftAndRightViewIDs",
            "HeroEye",
            "StereoCameraBaseline",
            "HorizontalDisparityAdjustment",
            "HasLeftStereoEyeView",
            "HasRightStereoEyeView",
            "HorizontalFieldOfView",
            "CameraCalibrationDataLensCollection",
            "NumberOfPendingFrames",
            "PixelBufferPoolIsShared",
            "VideoEncoderPixelBufferAttributes",
            "ReferenceBufferCount",
            "UsingHardwareAcceleratedVideoEncoder",
            "UsingGPURegistryID",
            "EstimatedAverageBytesPerFrame",
            "SupportsBaseFrameQP",
            "RecommendedParallelizedSubdivisionMinimumFrameCount",
            "RecommendedParallelizedSubdivisionMinimumDuration",
            "SupportedPresetDictionaries",
        ]

        XCTAssertEqual(
            Set(NativeCompressionPropertyCatalog.descriptors.map(\.key)),
            expectedKeys
        )
        XCTAssertEqual(expectedKeys.count, 80)
        XCTAssertNil(
            NativeCompressionPropertyCatalog
                .byKey["SuggestedLookAheadFrameCount"]
        )
    }

    func test支持字典解析保留读写状态范围与枚举() throws {
        let rawDictionary: NSDictionary = [
            "AverageBitRate": [
                kVTPropertyReadWriteStatusKey as String:
                    kVTPropertyReadWriteStatus_ReadWrite as String,
                kVTPropertyTypeKey as String: "Number",
                kVTPropertySupportedValueListKey as String: [
                    1_000_000,
                    8_000_000,
                ],
                kVTPropertySupportedValueMinimumKey as String: 1_000_000,
                kVTPropertySupportedValueMaximumKey as String: 20_000_000,
            ] as NSDictionary,
            "MaxFrameDelayCount": [
                kVTPropertyReadWriteStatusKey as String:
                    kVTPropertyReadWriteStatus_ReadOnly as String,
                kVTPropertyTypeKey as String: "Number",
            ] as NSDictionary,
        ]

        let parsed = NativeCompressionCapabilityProbe
            .parseSupportedProperties(rawDictionary)
        let averageBitRate = try XCTUnwrap(parsed["AverageBitRate"])
        XCTAssertTrue(averageBitRate.isWritable)
        XCTAssertFalse(averageBitRate.isReadOnly)
        XCTAssertEqual(averageBitRate.propertyType, "Number")
        XCTAssertEqual(
            averageBitRate.supportedValues,
            ["1000000", "8000000"]
        )
        XCTAssertEqual(averageBitRate.supportedMinimum, 1_000_000)
        XCTAssertEqual(averageBitRate.supportedMaximum, 20_000_000)

        let maxFrameDelay = try XCTUnwrap(parsed["MaxFrameDelayCount"])
        XCTAssertFalse(maxFrameDelay.isWritable)
        XCTAssertTrue(maxFrameDelay.isReadOnly)
    }

    func test能力模型区分可写只读与不支持字段() throws {
        let capabilities = makeCapabilities(
            writableKeys: ["AverageBitRate"],
            readOnlyKeys: ["MaxFrameDelayCount"]
        )
        let writable = try XCTUnwrap(
            NativeCompressionPropertyCatalog.byKey["AverageBitRate"]
        )
        let readOnly = try XCTUnwrap(
            NativeCompressionPropertyCatalog.byKey["MaxFrameDelayCount"]
        )
        let unsupported = try XCTUnwrap(
            NativeCompressionPropertyCatalog.byKey["Quality"]
        )

        XCTAssertTrue(capabilities.isWritable(writable))
        XCTAssertFalse(capabilities.isWritable(readOnly))
        XCTAssertTrue(capabilities.capability(for: readOnly)?.isReadOnly == true)
        XCTAssertFalse(capabilities.isWritable(unsupported))
        XCTAssertNil(capabilities.capability(for: unsupported))
    }

    func test互斥与依赖字段共用同一套可见性规则() throws {
        let realTime = try XCTUnwrap(
            NativeCompressionPropertyCatalog.byKey["RealTime"]
        )
        let speedPriority = try XCTUnwrap(
            NativeCompressionPropertyCatalog
                .byKey["PrioritizeEncodingSpeedOverQuality"]
        )
        let multiPass = try XCTUnwrap(
            NativeCompressionPropertyCatalog.byKey["MultiPassStorage"]
        )
        let frameReordering = try XCTUnwrap(
            NativeCompressionPropertyCatalog.byKey["AllowFrameReordering"]
        )
        let openGOP = try XCTUnwrap(
            NativeCompressionPropertyCatalog.byKey["AllowOpenGOP"]
        )
        let maximumRealTimeFrameRate = try XCTUnwrap(
            NativeCompressionPropertyCatalog
                .byKey["MaximumRealTimeFrameRate"]
        )

        var settings = TranscodeSettings.defaultSettings
        settings.multiPassStorageEnabled = true
        XCTAssertFalse(settings.isVisibleInNativeEditor(realTime))
        XCTAssertFalse(settings.isVisibleInNativeEditor(speedPriority))
        XCTAssertTrue(settings.isVisibleInNativeEditor(multiPass))

        settings.multiPassStorageEnabled = false
        settings.realTime = true
        XCTAssertFalse(settings.isVisibleInNativeEditor(multiPass))
        XCTAssertTrue(
            settings.isVisibleInNativeEditor(maximumRealTimeFrameRate)
        )

        settings.realTime = false
        XCTAssertFalse(
            settings.isVisibleInNativeEditor(maximumRealTimeFrameRate)
        )
        settings.setNativeValue(
            .bool(false),
            forKey: "AllowTemporalCompression"
        )
        XCTAssertFalse(settings.isVisibleInNativeEditor(frameReordering))
        XCTAssertFalse(settings.isVisibleInNativeEditor(openGOP))
    }

    func test能力清洗移除冲突只读和失去父字段的值() throws {
        var settings = TranscodeSettings(
            targetCodec: .hevc,
            nativeProperties: [
                "AverageBitRate": .number(8_000_000),
                "Quality": .number(0.8),
                "DataRateLimits": .array([
                    .number(1_500_000),
                    .number(1),
                ]),
                "RealTime": .bool(false),
                "MaximumRealTimeFrameRate": .number(60),
                "H264EntropyMode": .string("CABAC"),
                "UsingHardwareAcceleratedVideoEncoder": .bool(true),
            ]
        )
        let capabilities = makeCapabilities(
            writableKeys: [
                "AverageBitRate",
                "Quality",
                "DataRateLimits",
                "RealTime",
                "MaximumRealTimeFrameRate",
            ],
            readOnlyKeys: ["UsingHardwareAcceleratedVideoEncoder"]
        )

        settings = settings.sanitized(for: capabilities)

        XCTAssertEqual(settings.selectedRateControlKey, "AverageBitRate")
        XCTAssertNil(settings.nativeProperties["Quality"])
        XCTAssertNotNil(settings.nativeProperties["DataRateLimits"])
        XCTAssertNil(settings.nativeProperties["MaximumRealTimeFrameRate"])
        XCTAssertNil(settings.nativeProperties["H264EntropyMode"])
        XCTAssertNil(
            settings.nativeProperties["UsingHardwareAcceleratedVideoEncoder"]
        )
        XCTAssertNoThrow(try settings.validate())

        let orphanCapabilities = makeCapabilities(
            writableKeys: ["DataRateLimits"]
        )
        let orphaned = settings.sanitized(for: orphanCapabilities)
        XCTAssertNil(orphaned.nativeProperties["AverageBitRate"])
        XCTAssertNil(orphaned.nativeProperties["DataRateLimits"])
        XCTAssertNoThrow(try orphaned.validate())
    }

    func test数据速率限制必须是数据量与时间窗口() {
        var settings = TranscodeSettings.defaultSettings
        settings.dataRateLimits = [1_500_000]

        XCTAssertThrowsError(try settings.validate())
    }

    func test两个关键帧约束保持独立() {
        let source = makeVideoSummary(
            bitRate: 10_000_000,
            frameRate: 60,
            isHDR: false
        )
        var settings = TranscodeSettings.defaultSettings
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

    func test多遍存储请求保持平均码率() {
        let source = makeVideoSummary(
            bitRate: 10_000_000,
            frameRate: 30,
            isHDR: false
        )
        var settings = TranscodeSettings.defaultSettings
        settings.multiPassStorageEnabled = true

        let resolved = VideoTranscoder.resolve(
            settings: settings,
            sourceVideo: source,
            codecType: kCMVideoCodecType_HEVC,
            isHDR: false
        )

        XCTAssertTrue(resolved.multiPassStorageEnabled)
        XCTAssertEqual(resolved.averageBitRate, 8_000_000)
    }

    func test多遍存储拒绝实时或速度优先() {
        var realTimeSettings = TranscodeSettings.defaultSettings
        realTimeSettings.multiPassStorageEnabled = true
        realTimeSettings.realTime = true
        XCTAssertThrowsError(try realTimeSettings.validate())

        var speedSettings = TranscodeSettings.defaultSettings
        speedSettings.multiPassStorageEnabled = true
        speedSettings.prioritizeEncodingSpeedOverQuality = true
        XCTAssertThrowsError(try speedSettings.validate())
    }

    func test依赖字段不能脱离原生父字段写入() {
        var realTimeSettings = TranscodeSettings.defaultSettings
        realTimeSettings.realTime = false
        realTimeSettings.setNativeValue(
            .number(60),
            forKey: "MaximumRealTimeFrameRate"
        )
        XCTAssertThrowsError(try realTimeSettings.validate())

        var fieldSettings = TranscodeSettings.defaultSettings
        fieldSettings.setNativeValue(.number(1), forKey: "FieldCount")
        fieldSettings.setNativeValue(
            .string("TemporalTopFirst"),
            forKey: "FieldDetail"
        )
        XCTAssertThrowsError(try fieldSettings.validate())

        var gammaSettings = TranscodeSettings.defaultSettings
        gammaSettings.setNativeValue(.number(2.2), forKey: "GammaLevel")
        XCTAssertThrowsError(try gammaSettings.validate())
    }

    func testH264Baseline拒绝CABAC() {
        var settings = TranscodeSettings.defaultSettings
        settings.selectCodec(.h264)
        settings.setNativeValue(
            .string("H264_Baseline_AutoLevel"),
            forKey: "ProfileLevel"
        )
        settings.setNativeValue(.string("CABAC"), forKey: "H264EntropyMode")

        XCTAssertThrowsError(try settings.validate())
    }

    func testCFData字段只接受Base64原始值() {
        var settings = TranscodeSettings.defaultSettings
        settings.setNativeValue(.string("AQID"), forKey: "ICCProfile")
        XCTAssertNoThrow(try settings.validate())

        settings.setNativeValue(.string("不是 Base64"), forKey: "ICCProfile")
        XCTAssertThrowsError(try settings.validate())
    }

    func testHDR输入拒绝H264() {
        XCTAssertThrowsError(
            try TranscodeTargetCodec.h264.resolvedCodecType(isHDR: true)
        ) { error in
            XCTAssertEqual(error as? TranscodeError, .hdrRequiresHEVC)
        }
    }

    func testHDR的HEVC解析为Main10() throws {
        let source = makeVideoSummary(
            bitRate: 20_000_000,
            frameRate: 30,
            isHDR: true
        )
        let codec = try TranscodeTargetCodec.hevc
            .resolvedCodecType(isHDR: true)
        let resolved = VideoTranscoder.resolve(
            settings: .defaultSettings,
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

    private func makeCapabilities(
        writableKeys: Set<String>,
        readOnlyKeys: Set<String> = []
    ) -> NativeCompressionCapabilities {
        let properties = Dictionary(
            uniqueKeysWithValues: writableKeys.map {
                (
                    $0,
                    NativeCompressionPropertyCapability(
                        key: $0,
                        readWriteStatus:
                            kVTPropertyReadWriteStatus_ReadWrite as String,
                        propertyType: nil,
                        supportedValues: [],
                        supportedMinimum: nil,
                        supportedMaximum: nil
                    )
                )
            } + readOnlyKeys.map {
                (
                    $0,
                    NativeCompressionPropertyCapability(
                        key: $0,
                        readWriteStatus:
                            kVTPropertyReadWriteStatus_ReadOnly as String,
                        propertyType: nil,
                        supportedValues: [],
                        supportedMinimum: nil,
                        supportedMaximum: nil
                    )
                )
            }
        )
        return NativeCompressionCapabilities(
            encoderID: "测试编码器",
            width: 1_920,
            height: 1_080,
            properties: properties
        )
    }
}
