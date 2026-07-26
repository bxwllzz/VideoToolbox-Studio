import CoreMedia
import Foundation
import VideoToolbox

indirect enum NativeCompressionValue: Codable, Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([NativeCompressionValue])
    case object([String: NativeCompressionValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([NativeCompressionValue].self) {
            self = .array(value)
        } else {
            self = .object(
                try container.decode([String: NativeCompressionValue].self)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else {
            return nil
        }
        return value
    }

    var numberValue: Double? {
        guard case .number(let value) = self else {
            return nil
        }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else {
            return nil
        }
        return value
    }

    var arrayValue: [NativeCompressionValue]? {
        guard case .array(let value) = self else {
            return nil
        }
        return value
    }

    var foundationObject: AnyObject {
        switch self {
        case .bool(let value):
            return value ? kCFBooleanTrue : kCFBooleanFalse
        case .number(let value):
            return NSNumber(value: value)
        case .string(let value):
            return value as NSString
        case .array(let value):
            return value.map { $0.foundationObject } as NSArray
        case .object(let value):
            return value.mapValues { $0.foundationObject } as NSDictionary
        case .null:
            return NSNull()
        }
    }

    var jsonText: String {
        guard JSONSerialization.isValidJSONObject(foundationObject),
              let data = try? JSONSerialization.data(
                  withJSONObject: foundationObject,
                  options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func parseJSON(_ text: String) throws -> NativeCompressionValue {
        let data = Data(text.utf8)
        let object = try JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        )
        return NativeCompressionValue(foundationObject: object)
    }

    init(foundationObject value: Any) {
        if value is NSNull {
            self = .null
            return
        }
        if let number = value as? NSNumber,
           CFGetTypeID(number) == CFBooleanGetTypeID() {
            self = .bool(number.boolValue)
            return
        }
        switch value {
        case let value as NSNumber:
            self = .number(value.doubleValue)
        case let value as String:
            self = .string(value)
        case let value as NSArray:
            self = .array(value.map(NativeCompressionValue.init(foundationObject:)))
        case let value as NSDictionary:
            var result: [String: NativeCompressionValue] = [:]
            for (key, nestedValue) in value {
                result[String(describing: key)] = NativeCompressionValue(
                    foundationObject: nestedValue
                )
            }
            self = .object(result)
        default:
            self = .null
        }
    }
}

enum NativeCompressionPropertyCategory: String, CaseIterable, Identifiable, Sendable {
    case rateControl
    case frameDependency
    case runtime
    case encodingHints
    case bitstream
    case colorAndGeometry
    case alphaHDR
    case spatialVideo
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rateControl:
            "码率与质量"
        case .frameDependency:
            "帧依赖与图像组"
        case .runtime:
            "运行时约束"
        case .encodingHints:
            "离线编码提示"
        case .bitstream:
            "码流配置"
        case .colorAndGeometry:
            "色彩与画面几何"
        case .alphaHDR:
            "Alpha 与 HDR"
        case .spatialVideo:
            "空间与多视角视频"
        case .diagnostics:
            "只读状态与诊断"
        }
    }
}

enum NativeCompressionPropertyValueKind: Sendable {
    case boolean
    case integer
    case number
    case enumeration([String])
    case dataRateLimits
    case multiPassStorage
    case base64Data
    case json
}

enum NativeCompressionCodecScope: Sendable {
    case all
    case h264
    case hevc

    func contains(_ codec: TranscodeTargetCodec) -> Bool {
        switch (self, codec) {
        case (.all, _), (.h264, .h264), (.hevc, .hevc):
            true
        default:
            false
        }
    }
}

struct NativeCompressionPropertyDescriptor: Identifiable, Sendable {
    let key: String
    let title: String
    let category: NativeCompressionPropertyCategory
    let kind: NativeCompressionPropertyValueKind
    let codecScope: NativeCompressionCodecScope
    let isPubliclySettable: Bool
    let suggestedValue: NativeCompressionValue?
    let minimum: Double?
    let maximum: Double?
    let unit: String?
    let detail: String

    var id: String { key }

    var nativeName: String {
        "kVTCompressionPropertyKey_\(key)"
    }

    func applies(to codec: TranscodeTargetCodec) -> Bool {
        codecScope.contains(codec)
    }

    var helpMessage: String {
        var message = "原生配置名：\(nativeName)；支持字典字段：\(key)。\(detail)"
        if let unit {
            message += " 原生单位：\(unit)。"
        }
        return message
    }
}

enum NativeCompressionPropertyCatalog {
    static let rateControlKeys: [String] = [
        "AverageBitRate",
        "ConstantBitRate",
        "VariableBitRate",
        "Quality",
        "ConstantQualityFactor",
    ]

    static let vbvKeys: Set<String> = [
        "VBVMaxBitRate",
        "VBVBufferDuration",
        "VBVInitialDelayPercentage",
    ]

    static let descriptors: [NativeCompressionPropertyDescriptor] = [
        descriptor(
            "AverageBitRate", "AverageBitRate", .rateControl, .integer,
            suggested: .number(8_000_000), minimum: 1, unit: "bit/s",
            detail: "长期目标平均码率，不是瞬时恒定码率。"
        ),
        descriptor(
            "ConstantBitRate", "ConstantBitRate", .rateControl, .integer,
            suggested: .number(8_000_000), minimum: 1, unit: "bit/s",
            detail: "要求使用恒定码率控制。"
        ),
        descriptor(
            "VariableBitRate", "VariableBitRate", .rateControl, .integer,
            suggested: .number(8_000_000), minimum: 1, unit: "bit/s",
            detail: "iOS 26 的可变码率目标。"
        ),
        descriptor(
            "Quality", "Quality", .rateControl, .number,
            suggested: .number(0.75), minimum: 0, maximum: 1,
            detail: "编码器质量提示；不保证输出体积。"
        ),
        descriptor(
            "ConstantQualityFactor", "ConstantQualityFactor", .rateControl, .number,
            suggested: .number(0.75), minimum: 0, maximum: 1,
            detail: "iOS 26 的恒定质量因子。"
        ),
        descriptor(
            "DataRateLimits", "DataRateLimits", .rateControl, .dataRateLimits,
            suggested: .array([.number(1_500_000), .number(1)]),
            detail: "交替填写数据量与时间窗口，限制任意连续窗口内的数据量。"
        ),
        descriptor(
            "VBVMaxBitRate", "VBVMaxBitRate", .rateControl, .integer,
            suggested: .number(12_000_000), minimum: 1, unit: "bit/s",
            detail: "可变码率模式进入 VBV 的最大码率。"
        ),
        descriptor(
            "VBVBufferDuration", "VBVBufferDuration", .rateControl, .number,
            suggested: .number(2.5), minimum: 0, unit: "s",
            detail: "CBR 或 VBR 的视频缓冲验证器缓冲时长。"
        ),
        descriptor(
            "VBVInitialDelayPercentage", "VBVInitialDelayPercentage", .rateControl,
            .number, suggested: .number(90), minimum: 0, maximum: 100, unit: "%",
            detail: "VBV 初始延迟占缓冲时长的百分比。"
        ),
        descriptor(
            "MaxKeyFrameInterval", "MaxKeyFrameInterval", .frameDependency, .integer,
            suggested: .number(0), minimum: 0, unit: "帧",
            detail: "两个关键帧之间允许的最大帧数。"
        ),
        descriptor(
            "MaxKeyFrameIntervalDuration", "MaxKeyFrameIntervalDuration",
            .frameDependency, .number, suggested: .number(0), minimum: 0, unit: "s",
            detail: "两个关键帧之间允许的最大时长。"
        ),
        descriptor(
            "AllowTemporalCompression", "AllowTemporalCompression",
            .frameDependency, .boolean, suggested: .bool(true),
            detail: "允许使用帧间预测压缩。"
        ),
        descriptor(
            "AllowFrameReordering", "AllowFrameReordering", .frameDependency,
            .boolean, suggested: .bool(true),
            detail: "允许帧重排及双向预测帧。"
        ),
        descriptor(
            "AllowOpenGOP", "AllowOpenGOP", .frameDependency, .boolean,
            suggested: .bool(false), detail: "允许开放式 GOP 依赖结构。"
        ),
        descriptor(
            "MoreFramesBeforeStart", "MoreFramesBeforeStart", .frameDependency,
            .boolean, suggested: .bool(false),
            detail: "指示编码区间开始前是否还会提供额外帧。"
        ),
        descriptor(
            "MoreFramesAfterEnd", "MoreFramesAfterEnd", .frameDependency, .boolean,
            suggested: .bool(false),
            detail: "指示编码区间结束后是否还会提供额外帧。"
        ),
        descriptor(
            "MaxFrameDelayCount", "MaxFrameDelayCount", .runtime, .integer,
            suggested: .number(0), minimum: 0,
            detail: "编码器可保留的最大帧数；具体硬编可能只读。",
            settable: true
        ),
        descriptor(
            "MaxH264SliceBytes", "MaxH264SliceBytes", .runtime, .integer,
            scope: .h264, suggested: .number(1_500), minimum: 1, unit: "byte",
            detail: "H.264 单个 slice 的最大字节数。"
        ),
        descriptor(
            "RealTime", "RealTime", .runtime, .boolean, suggested: .bool(false),
            detail: "要求编码器按实时节奏输出。"
        ),
        descriptor(
            "MaximizePowerEfficiency", "MaximizePowerEfficiency", .runtime,
            .boolean, suggested: .bool(false), detail: "优先提高能效。"
        ),
        descriptor(
            "MaximumRealTimeFrameRate", "MaximumRealTimeFrameRate", .runtime,
            .number, suggested: .number(60), minimum: 0, unit: "帧/s",
            detail: "告知实时编码器可能接收的最大提交帧率。"
        ),
        descriptor(
            "PrioritizeEncodingSpeedOverQuality",
            "PrioritizeEncodingSpeedOverQuality", .runtime, .boolean,
            suggested: .bool(false), detail: "允许以质量换编码速度。"
        ),
        descriptor(
            "MultiPassStorage", "MultiPassStorage", .runtime, .multiPassStorage,
            suggested: .bool(true),
            detail: "请求 VideoToolbox 多遍流程；实际对象由 App 创建并传入。"
        ),
        descriptor(
            "SourceFrameCount", "SourceFrameCount", .encodingHints, .integer,
            suggested: .number(300), minimum: 1, unit: "帧",
            detail: "告知编码器预计输入的总帧数。"
        ),
        descriptor(
            "ExpectedFrameRate", "ExpectedFrameRate", .encodingHints, .number,
            suggested: .number(30), minimum: 0, unit: "帧/s",
            detail: "告知编码器预计输入帧率；不改变时间戳。"
        ),
        descriptor(
            "ExpectedDuration", "ExpectedDuration", .encodingHints, .number,
            suggested: .number(10), minimum: 0, unit: "s",
            detail: "告知编码器预计输入时长。"
        ),
        descriptor(
            "BaseLayerFrameRate", "BaseLayerFrameRate", .encodingHints, .number,
            suggested: .number(30), minimum: 0, unit: "帧/s",
            detail: "设置时间分层码流的基础层帧率。"
        ),
        descriptor(
            "BaseLayerFrameRateFraction", "BaseLayerFrameRateFraction",
            .encodingHints, .number, suggested: .number(0.5), minimum: 0, maximum: 1,
            detail: "设置基础层帧率占总帧率的比例。"
        ),
        descriptor(
            "BaseLayerBitRateFraction", "BaseLayerBitRateFraction",
            .encodingHints, .number, suggested: .number(0.5), minimum: 0, maximum: 1,
            detail: "设置基础层码率占总码率的比例。"
        ),
        descriptor(
            "EnableLTR", "EnableLTR", .encodingHints, .boolean,
            suggested: .bool(false), detail: "启用长期参考帧。"
        ),
        descriptor(
            "MaxAllowedFrameQP", "MaxAllowedFrameQP", .encodingHints, .integer,
            suggested: .number(51), minimum: 0,
            detail: "限制单帧允许的最大量化参数。"
        ),
        descriptor(
            "MinAllowedFrameQP", "MinAllowedFrameQP", .encodingHints, .integer,
            suggested: .number(0), minimum: 0,
            detail: "限制单帧允许的最小量化参数。"
        ),
        descriptor(
            "ProfileLevel", "ProfileLevel", .bitstream, .enumeration([]),
            detail: "设置编码配置档和级别；不设置时按输入保真自动选择。"
        ),
        descriptor(
            "H264EntropyMode", "H264EntropyMode", .bitstream,
            .enumeration(["CAVLC", "CABAC"]), scope: .h264,
            detail: "选择 H.264 熵编码模式。"
        ),
        descriptor(
            "Depth", "Depth", .bitstream, .integer, suggested: .number(0),
            minimum: 0, detail: "选择支持指定像素深度的编码器。"
        ),
        descriptor(
            "OutputBitDepth", "OutputBitDepth", .bitstream, .integer,
            scope: .hevc, suggested: .number(10), minimum: 8, maximum: 16,
            unit: "bit", detail: "请求输出码流位深。"
        ),
        descriptor(
            "CalculateMeanSquaredError", "CalculateMeanSquaredError",
            .bitstream, .boolean, suggested: .bool(false),
            detail: "要求编码器在输出样本中计算均方误差诊断值。"
        ),
        descriptor(
            "EncoderID", "EncoderID", .bitstream, .enumeration([]),
            detail: "指定公开编码器标识；仅在当前会话支持字典标为可写时允许设置。"
        ),
        descriptor(
            "CleanAperture", "CleanAperture", .colorAndGeometry, .json,
            detail: "设置干净孔径字典。"
        ),
        descriptor(
            "PixelAspectRatio", "PixelAspectRatio", .colorAndGeometry, .json,
            detail: "设置像素宽高比字典。"
        ),
        descriptor(
            "FieldCount", "FieldCount", .colorAndGeometry, .integer,
            suggested: .number(1), minimum: 1, maximum: 2,
            detail: "设置每帧包含的场数。"
        ),
        descriptor(
            "FieldDetail", "FieldDetail", .colorAndGeometry, .enumeration([]),
            detail: "设置场顺序。"
        ),
        descriptor(
            "AspectRatio16x9", "AspectRatio16x9", .colorAndGeometry, .boolean,
            suggested: .bool(true), detail: "标记 16:9 画面比例。"
        ),
        descriptor(
            "ProgressiveScan", "ProgressiveScan", .colorAndGeometry, .boolean,
            suggested: .bool(true), detail: "标记逐行扫描。"
        ),
        descriptor(
            "ColorPrimaries", "ColorPrimaries", .colorAndGeometry,
            .enumeration([]), detail: "设置色彩原色；不设置时继承输入。"
        ),
        descriptor(
            "TransferFunction", "TransferFunction", .colorAndGeometry,
            .enumeration([]), detail: "设置传递函数；不设置时继承输入。"
        ),
        descriptor(
            "YCbCrMatrix", "YCbCrMatrix", .colorAndGeometry, .enumeration([]),
            detail: "设置 YCbCr 矩阵；不设置时继承输入。"
        ),
        descriptor(
            "ICCProfile", "ICCProfile", .colorAndGeometry, .base64Data,
            detail: "设置 ICC 色彩配置的原生 CFData；编辑器使用 Base64。"
        ),
        descriptor(
            "GammaLevel", "GammaLevel", .colorAndGeometry, .number,
            suggested: .number(2.2), minimum: 0,
            detail: "设置伽马值。"
        ),
        descriptor(
            "PixelTransferProperties", "PixelTransferProperties",
            .colorAndGeometry, .json, detail: "设置预压缩像素传输属性字典。"
        ),
        descriptor(
            "PreserveAlphaChannel", "PreserveAlphaChannel", .alphaHDR, .boolean,
            scope: .hevc, suggested: .bool(true), detail: "要求保留输入 Alpha 通道。"
        ),
        descriptor(
            "TargetQualityForAlpha", "TargetQualityForAlpha", .alphaHDR, .number,
            scope: .hevc, suggested: .number(0.75), minimum: 0, maximum: 1,
            detail: "设置 Alpha 通道目标质量。"
        ),
        descriptor(
            "AlphaChannelMode", "AlphaChannelMode", .alphaHDR,
            .enumeration(["StraightAlpha", "PremultipliedAlpha"]), scope: .hevc,
            detail: "设置 Alpha 通道解释方式。"
        ),
        descriptor(
            "HDRMetadataInsertionMode", "HDRMetadataInsertionMode", .alphaHDR,
            .enumeration([]), scope: .hevc, detail: "设置 HDR 元数据插入模式。"
        ),
        descriptor(
            "PreserveDynamicHDRMetadata", "PreserveDynamicHDRMetadata",
            .alphaHDR, .boolean, scope: .hevc, suggested: .bool(true),
            detail: "要求保留动态 HDR 元数据。"
        ),
        descriptor(
            "MasteringDisplayColorVolume", "MasteringDisplayColorVolume",
            .alphaHDR, .base64Data, scope: .hevc,
            detail: "设置母版显示色彩体积的原生 CFData；编辑器使用 Base64。"
        ),
        descriptor(
            "ContentLightLevelInfo", "ContentLightLevelInfo", .alphaHDR,
            .base64Data, scope: .hevc,
            detail: "设置内容亮度级别的原生 CFData；编辑器使用 Base64。"
        ),
        descriptor(
            "ProjectionKind", "ProjectionKind", .spatialVideo,
            .enumeration([]), scope: .hevc, detail: "当前投影类型。",
            settable: false
        ),
        descriptor(
            "ViewPackingKind", "ViewPackingKind", .spatialVideo,
            .enumeration([]), scope: .hevc, detail: "当前视图打包类型。",
            settable: false
        ),
        descriptor(
            "MVHEVCVideoLayerIDs", "MVHEVCVideoLayerIDs", .spatialVideo, .json,
            scope: .hevc, detail: "设置多视角 HEVC 视频层 ID 数组。"
        ),
        descriptor(
            "MVHEVCViewIDs", "MVHEVCViewIDs", .spatialVideo, .json,
            scope: .hevc, detail: "设置多视角 HEVC 视图 ID 数组。"
        ),
        descriptor(
            "MVHEVCLeftAndRightViewIDs", "MVHEVCLeftAndRightViewIDs",
            .spatialVideo, .json, scope: .hevc,
            detail: "设置左右眼视图 ID。"
        ),
        descriptor(
            "HeroEye", "HeroEye", .spatialVideo, .enumeration([]), scope: .hevc,
            detail: "当前主要视角。", settable: false
        ),
        descriptor(
            "StereoCameraBaseline", "StereoCameraBaseline", .spatialVideo,
            .integer, scope: .hevc, minimum: 0,
            detail: "当前立体相机基线。", settable: false
        ),
        descriptor(
            "HorizontalDisparityAdjustment", "HorizontalDisparityAdjustment",
            .spatialVideo, .integer, scope: .hevc,
            detail: "当前水平视差调整量。", settable: false
        ),
        descriptor(
            "HasLeftStereoEyeView", "HasLeftStereoEyeView", .spatialVideo,
            .boolean, scope: .hevc, suggested: .bool(true),
            detail: "标记码流包含左眼视图。"
        ),
        descriptor(
            "HasRightStereoEyeView", "HasRightStereoEyeView", .spatialVideo,
            .boolean, scope: .hevc, suggested: .bool(true),
            detail: "标记码流包含右眼视图。"
        ),
        descriptor(
            "HorizontalFieldOfView", "HorizontalFieldOfView", .spatialVideo,
            .integer, scope: .hevc, minimum: 0,
            detail: "设置水平视场角。"
        ),
        descriptor(
            "CameraCalibrationDataLensCollection",
            "CameraCalibrationDataLensCollection", .spatialVideo, .json,
            scope: .hevc, detail: "设置 iOS 26 相机镜头标定集合。"
        ),
        descriptor(
            "NumberOfPendingFrames", "NumberOfPendingFrames", .diagnostics,
            .integer, detail: "当前待编码帧数。", settable: false
        ),
        descriptor(
            "PixelBufferPoolIsShared", "PixelBufferPoolIsShared", .diagnostics,
            .boolean, detail: "编码器像素缓冲池是否共享。", settable: false
        ),
        descriptor(
            "VideoEncoderPixelBufferAttributes",
            "VideoEncoderPixelBufferAttributes", .diagnostics, .json,
            detail: "编码器要求的像素缓冲属性。", settable: false
        ),
        descriptor(
            "ReferenceBufferCount", "ReferenceBufferCount", .diagnostics,
            .integer, detail: "编码器参考帧缓冲数量。", settable: false
        ),
        descriptor(
            "UsingHardwareAcceleratedVideoEncoder",
            "UsingHardwareAcceleratedVideoEncoder", .diagnostics, .boolean,
            detail: "当前会话是否实际使用硬件编码器。", settable: false
        ),
        descriptor(
            "UsingGPURegistryID", "UsingGPURegistryID", .diagnostics, .integer,
            detail: "当前使用的 GPU 注册表标识。", settable: false
        ),
        descriptor(
            "EstimatedAverageBytesPerFrame", "EstimatedAverageBytesPerFrame",
            .diagnostics, .integer, unit: "byte/帧",
            detail: "编码器估计的平均每帧字节数。", settable: false
        ),
        descriptor(
            "SupportsBaseFrameQP", "SupportsBaseFrameQP", .diagnostics,
            .boolean, detail: "编码器是否支持逐帧 BaseFrameQP 请求。",
            settable: false
        ),
        descriptor(
            "RecommendedParallelizedSubdivisionMinimumFrameCount",
            "RecommendedParallelizedSubdivisionMinimumFrameCount",
            .diagnostics, .integer, detail: "并行分段建议的最小帧数。",
            settable: false
        ),
        descriptor(
            "RecommendedParallelizedSubdivisionMinimumDuration",
            "RecommendedParallelizedSubdivisionMinimumDuration",
            .diagnostics, .json, detail: "并行分段建议的最小时长。",
            settable: false
        ),
        descriptor(
            "SupportedPresetDictionaries", "SupportedPresetDictionaries",
            .diagnostics, .json, detail: "编码器公开的原生预设字典，仅作只读检查。",
            settable: false
        ),
    ]

    static let byKey: [String: NativeCompressionPropertyDescriptor] = {
        Dictionary(uniqueKeysWithValues: descriptors.map { ($0.key, $0) })
    }()

    private static func descriptor(
        _ key: String,
        _ title: String,
        _ category: NativeCompressionPropertyCategory,
        _ kind: NativeCompressionPropertyValueKind,
        scope: NativeCompressionCodecScope = .all,
        suggested: NativeCompressionValue? = nil,
        minimum: Double? = nil,
        maximum: Double? = nil,
        unit: String? = nil,
        detail: String,
        settable: Bool = true
    ) -> NativeCompressionPropertyDescriptor {
        NativeCompressionPropertyDescriptor(
            key: key,
            title: title,
            category: category,
            kind: kind,
            codecScope: scope,
            isPubliclySettable: settable,
            suggestedValue: suggested,
            minimum: minimum,
            maximum: maximum,
            unit: unit,
            detail: detail
        )
    }
}

struct NativeCompressionPropertyCapability: Equatable, Sendable {
    let key: String
    let readWriteStatus: String?
    let propertyType: String?
    let supportedValues: [String]
    let supportedMinimum: Double?
    let supportedMaximum: Double?

    var isWritable: Bool {
        readWriteStatus == kVTPropertyReadWriteStatus_ReadWrite as String
    }

    var isReadOnly: Bool {
        readWriteStatus == kVTPropertyReadWriteStatus_ReadOnly as String
    }
}

struct NativeCompressionCapabilities: Equatable, Sendable {
    let encoderID: String?
    let width: Int32
    let height: Int32
    let properties: [String: NativeCompressionPropertyCapability]

    func capability(
        for descriptor: NativeCompressionPropertyDescriptor
    ) -> NativeCompressionPropertyCapability? {
        properties[descriptor.key]
    }

    func isWritable(
        _ descriptor: NativeCompressionPropertyDescriptor
    ) -> Bool {
        descriptor.isPubliclySettable
            && properties[descriptor.key]?.isWritable == true
    }
}

enum NativeCompressionCapabilityState: Equatable, Sendable {
    case loading
    case ready(NativeCompressionCapabilities)
    case failed(String)

    var capabilities: NativeCompressionCapabilities? {
        guard case .ready(let capabilities) = self else {
            return nil
        }
        return capabilities
    }
}

enum NativeCompressionCapabilityProbe {
    static func parseSupportedProperties(
        _ dictionary: NSDictionary
    ) -> [String: NativeCompressionPropertyCapability] {
        var properties: [String: NativeCompressionPropertyCapability] = [:]
        for (rawKey, rawValue) in dictionary {
            let key = String(describing: rawKey)
            let metadata = rawValue as? NSDictionary
            let readWriteStatus = metadata?.object(
                forKey: kVTPropertyReadWriteStatusKey
            ) as? String
            let propertyType = metadata?.object(
                forKey: kVTPropertyTypeKey
            ) as? String
            let supportedValues = (
                metadata?.object(
                    forKey: kVTPropertySupportedValueListKey
                ) as? [Any]
            )?.map(String.init(describing:)) ?? []
            let supportedMinimum = (
                metadata?.object(
                    forKey: kVTPropertySupportedValueMinimumKey
                ) as? NSNumber
            )?.doubleValue
            let supportedMaximum = (
                metadata?.object(
                    forKey: kVTPropertySupportedValueMaximumKey
                ) as? NSNumber
            )?.doubleValue
            properties[key] = NativeCompressionPropertyCapability(
                key: key,
                readWriteStatus: readWriteStatus,
                propertyType: propertyType,
                supportedValues: supportedValues,
                supportedMinimum: supportedMinimum,
                supportedMaximum: supportedMaximum
            )
        }
        return properties
    }

    static func run(
        codecType: CMVideoCodecType,
        width: Int32,
        height: Int32
    ) -> NativeCompressionCapabilityState {
        let encoderSpecification = [
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder
                as String: true,
        ] as CFDictionary

        var selectedEncoderID: CFString?
        var preflightProperties: CFDictionary?
        let preflightStatus = VTCopySupportedPropertyDictionaryForEncoder(
            width: width,
            height: height,
            codecType: codecType,
            encoderSpecification: encoderSpecification,
            encoderIDOut: &selectedEncoderID,
            supportedPropertiesOut: &preflightProperties
        )

        var session: VTCompressionSession?
        let sessionStatus = VTCompressionSessionCreate(
            allocator: nil,
            width: width,
            height: height,
            codecType: codecType,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        guard sessionStatus == noErr, let session else {
            return .failed(
                "无法创建 \(width)×\(height) 硬件编码会话（OSStatus \(sessionStatus)）。"
            )
        }
        defer {
            VTCompressionSessionInvalidate(session)
        }

        var sessionProperties: CFDictionary?
        let queryStatus = VTSessionCopySupportedPropertyDictionary(
            session,
            supportedPropertyDictionaryOut: &sessionProperties
        )
        let dictionary: NSDictionary?
        if queryStatus == noErr {
            dictionary = sessionProperties as NSDictionary?
        } else if preflightStatus == noErr {
            dictionary = preflightProperties as NSDictionary?
        } else {
            dictionary = nil
        }
        guard let dictionary else {
            return .failed(
                "编码器支持字典读取失败（会话 \(queryStatus)，预检 \(preflightStatus)）。"
            )
        }

        let properties = parseSupportedProperties(dictionary)

        return .ready(
            NativeCompressionCapabilities(
                encoderID: selectedEncoderID.map { $0 as String },
                width: width,
                height: height,
                properties: properties
            )
        )
    }
}
