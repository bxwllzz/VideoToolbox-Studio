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

    var displayText: String {
        switch self {
        case .bool(let value):
            value ? "true" : "false"
        case .number(let value):
            String(format: "%.8g", value)
        case .string(let value):
            value
        case .array, .object:
            jsonText.replacingOccurrences(of: "\n", with: " ")
        case .null:
            "null"
        }
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
        case let value as Data:
            self = .string(value.base64EncodedString())
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
            self = .string(String(describing: value))
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

    var isCollapsedByDefault: Bool {
        switch self {
        case .colorAndGeometry, .alphaHDR, .spatialVideo:
            true
        default:
            false
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
        var message =
            "原生配置名：\(nativeName)\n"
            + "支持字典字段：\(key)\n\n"
            + "作用：\(detail)\n\n"
            + "影响：\(NativeCompressionPropertyImpact.text(for: key))"
        if let unit {
            message += "\n\n原生单位：\(unit)"
        }
        return message
    }

    var documentationURL: URL? {
        URL(
            string:
                "https://developer.apple.com/documentation/videotoolbox/"
                + nativeName.lowercased()
        )
    }
}

enum NativeCompressionPropertyImpact {
    private static let values: [String: String] = [
        "AverageBitRate":
            "数值越高，通常细节更完整、文件更大；越低则更省空间，但运动区域和纹理更容易出现块状或涂抹。它是长时间平均目标，短时间码率仍可波动。",
        "ConstantBitRate":
            "更严格地稳定输出码率，适合带宽固定的传输；约束越紧，复杂画面越可能牺牲质量，简单画面也可能浪费码率。不要与其他码率主模式同时设置。",
        "VariableBitRate":
            "允许复杂画面使用更多码率、简单画面使用更少码率，通常比恒定码率更高效；目标越高，平均画质和体积通常都越高。不要与其他码率主模式同时设置。",
        "Quality":
            "越接近 1 越偏向画质，通常文件更大、编码更慢；越接近 0 越偏向体积。它是质量提示，不提供固定体积或固定码率保证。",
        "ConstantQualityFactor":
            "越高通常保留更多细节并产生更大的文件；越低压缩更强。目标是让不同复杂度片段保持近似主观质量，因此最终体积不可预先精确确定。",
        "DataRateLimits":
            "窗口允许的数据量越小或时间窗口越长，峰值码率限制越严格，利于网络和存储预算，但会压低复杂片段画质；设置过紧可能被编码器拒绝。",
        "VBVMaxBitRate":
            "上限越高，复杂瞬间可获得更多码率、质量更稳，但峰值带宽更大；上限越低，传输更可控，但快速运动和高纹理画面更易失真。",
        "VBVBufferDuration":
            "缓冲越长，编码器可在更长时间范围调配码率，通常提高压缩效率，但增加延迟和内存；越短则响应更快，码率调度空间更小。",
        "VBVInitialDelayPercentage":
            "比例越高，播放前需要预存的缓冲越多，抗突发码率能力更强但首帧延迟更大；越低启动更快，但更容易出现缓冲不足。",
        "MaxKeyFrameInterval":
            "数值越小，关键帧更频繁，随机定位和错误恢复更快，但文件通常更大；数值越大压缩效率更高，拖动定位和丢包恢复更慢。0 表示交给编码器决定。",
        "MaxKeyFrameIntervalDuration":
            "时长越短，按时间保证关键帧更密集，便于切片和定位，但增加码率开销；越长则压缩效率更高。它与按帧数的上限共同生效。",
        "AllowTemporalCompression":
            "开启后允许利用前后帧相似性，体积通常显著下降；关闭后更接近逐帧独立编码，便于编辑但文件很大，并会使帧重排和开放式图像组失去意义。",
        "AllowFrameReordering":
            "开启后可使用双向预测帧，通常提高压缩效率，但增加编码/解码延迟和缓存；关闭后延迟更低、帧顺序更直接，码率可能上升。",
        "AllowOpenGOP":
            "开启后图像组可跨关键帧边界引用，压缩效率可能更高；关闭后片段边界更独立，更适合随机切割、拼接和错误隔离。",
        "MoreFramesBeforeStart":
            "开启表示编码区间前还会提供参考帧，可改善区间起始处预测质量；若实际没有提供却错误开启，可能造成编码器等待或产生非预期依赖。",
        "MoreFramesAfterEnd":
            "开启表示区间结束后还会提供参考帧，可改善尾部预测；若实际流程不会追加帧，应保持关闭，避免收尾等待或依赖错误。",
        "MaxFrameDelayCount":
            "允许缓存的帧越多，编码器可进行更深的重排和分析，通常提高效率但增加延迟和内存；越小延迟更低。硬件编码器常把它固定为只读值。",
        "MaxH264SliceBytes":
            "上限越小，每帧会拆成更多切片，利于受限网络分包和局部错误恢复，但增加头部开销并可能降低压缩效率；越大则相反。",
        "RealTime":
            "开启后优先保证按输入节奏及时输出，可能减少前瞻分析并降低画质；关闭适合离线转码，可换取更充分的编码决策。与多遍编码互斥。",
        "MaximizePowerEfficiency":
            "开启后编码器更偏向低功耗路径，可能降低速度、工具复杂度或峰值质量；关闭则由系统在性能、质量与能耗之间自行选择。",
        "MaximumRealTimeFrameRate":
            "数值告诉实时编码器最坏情况下的输入帧率；设得过低可能导致排队或丢帧，设得过高可能使编码器采取更保守的质量策略。它不修改视频时间戳。",
        "PrioritizeEncodingSpeedOverQuality":
            "开启后以更快完成和更低计算量为优先，可能降低同码率画质；关闭则允许编码器使用更复杂的搜索。与多遍编码互斥。",
        "MultiPassStorage":
            "开启后允许编码器先分析再重编码关键区间，通常改善同码率画质，但耗时约增加到两遍、需要临时存储，且并非每个硬件配置都接受。",
        "SourceFrameCount":
            "准确填写可帮助离线编码器规划码率和多遍分析；填得过大或过小会使规划偏离实际，但不会自动增加或删除帧。",
        "ExpectedFrameRate":
            "准确值有助于码率、缓存和关键帧策略；设高会让编码器按更高吞吐准备，设低可能低估负载。它只提示，不改帧率和时间戳。",
        "ExpectedDuration":
            "准确时长有助于离线码率分配和多遍规划；错误值可能让前后段分配失衡，但不会裁剪或延长视频。",
        "BaseLayerFrameRate":
            "基础层帧率越高，低层码流运动更流畅但占用更多码率；越低则为增强层留下更多码率，低层播放会更不连贯。",
        "BaseLayerFrameRateFraction":
            "比例越高，更多帧进入基础时间层，基础层更流畅但增强层收益减小；越低则基础层更稀疏。",
        "BaseLayerBitRateFraction":
            "比例越高，更多总码率分配给基础层，兼容低层解码时质量更高；越低则更多码率留给增强层。",
        "EnableLTR":
            "开启长期参考帧可在遮挡、周期运动或丢包后复用较早画面，提高某些场景的效率和恢复性；会增加参考缓冲和编码复杂度。",
        "MaxAllowedFrameQP":
            "上限越低，限制最差画质更严格，但复杂画面可能突破码率目标；上限越高，编码器可更强压缩个别帧。QP 越大通常量化越强、画质越低。",
        "MinAllowedFrameQP":
            "下限越高，限制编码器在简单画面投入过多码率，可减小体积但封顶最佳画质；下限越低，允许简单画面达到更高质量。",
        "ProfileLevel":
            "更高配置档或级别可启用更多编码工具、分辨率和码率，但旧设备兼容性可能下降；选择过低可能被拒绝或限制画质。通常留空由系统匹配最稳妥。",
        "H264EntropyMode":
            "CABAC 通常比 CAVLC 压缩效率更高，但计算量和兼容要求更高；CAVLC 更简单，适用于 Baseline 等受限配置档。",
        "Depth":
            "请求的像素深度会影响可选编码器和输入缓冲格式；更高深度保留更多精度但增加带宽、内存和兼容要求。它不等同于最终码流位深。",
        "OutputBitDepth":
            "10-bit 等更高位深可减少色带并承载 HDR，但文件、处理开销和播放兼容要求更高；8-bit 兼容性最好，但高动态范围和渐变精度有限。",
        "CalculateMeanSquaredError":
            "开启后让编码器计算均方误差诊断，便于客观比较，但会增加少量计算和报告数据；它不直接改善画质。",
        "EncoderID":
            "指定后会固定到某个公开编码器实现，结果更可复现，但可能失去系统自动选择的兼容性或能效优势；错误标识会导致会话创建失败。",
        "CleanAperture":
            "改变显示时采用的有效画面区域，可表达裁边而不重采样像素；参数错误会造成黑边、裁切或显示尺寸不一致。",
        "PixelAspectRatio":
            "改变单个像素的显示宽高比，不会重采样图像；设置错误会让画面横向或纵向拉伸。普通方形像素视频通常无需设置。",
        "FieldCount":
            "1 表示逐帧结构，2 表示隔行场结构；错误设置会造成梳齿、抖动或解码器误判。现代 iPhone 素材通常为 1。",
        "FieldDetail":
            "指定隔行视频的场顺序；上下场顺序设反会产生明显运动抖动。只有 FieldCount 为 2 时才有意义。",
        "AspectRatio16x9":
            "开启只写入 16:9 画面标记，不会裁剪或缩放像素；与真实尺寸不一致时，播放器可能按错误比例显示。",
        "ProgressiveScan":
            "开启表示逐行扫描，关闭表示可能为隔行内容；标记错误会影响播放器去隔行策略，但不会自动转换扫描方式。",
        "ColorPrimaries":
            "决定红绿蓝原色坐标；改成与素材不一致的值会产生整体偏色。通常应继承输入，只有明确做了色彩转换时才覆盖。",
        "TransferFunction":
            "决定码值与显示亮度的关系；错误设置会导致画面过亮、过暗或 HDR 被当作 SDR。通常应与实际像素转换保持一致。",
        "YCbCrMatrix":
            "决定亮度/色度与 RGB 的换算；设置错误会造成色相和饱和度偏差。高清、超高清和 HDR 素材常用的矩阵并不相同。",
        "ICCProfile":
            "嵌入精确色彩配置可改善色彩管理一致性，但增加元数据并要求播放器支持；配置与像素不匹配会导致错误颜色转换。",
        "GammaLevel":
            "数值改变使用 Gamma 传递函数时的亮度曲线；更高通常使中间调更暗，较低使中间调更亮。只有对应传递函数模式下才应设置。",
        "PixelTransferProperties":
            "控制压缩前像素传输、缩放或色彩转换的底层属性；可精细影响锐度、色域和数值范围，但错误字典可能导致色偏或会话失败。",
        "PreserveAlphaChannel":
            "开启后保留透明度，输出更大且只适用于支持 Alpha 的 HEVC 工作流；关闭会丢弃透明信息。没有 Alpha 的输入无需开启。",
        "TargetQualityForAlpha":
            "越高越能保留透明边缘和半透明渐变，但 Alpha 码流更大；越低更省空间，边缘可能出现台阶或光晕。",
        "AlphaChannelMode":
            "Straight 表示颜色未预乘透明度，Premultiplied 表示已预乘；选择错误会导致透明边缘发黑、发白或颜色不正确。",
        "HDRMetadataInsertionMode":
            "决定编码器何时以及如何插入 HDR 元数据；错误模式可能造成播放器遗漏、重复或错误解释 HDR 信息。",
        "PreserveDynamicHDRMetadata":
            "开启后尝试保留逐场景/逐帧动态 HDR 元数据，提高兼容显示的亮度映射准确性；关闭会丢失这类动态指导信息。",
        "MasteringDisplayColorVolume":
            "写入母版显示器的色域和亮度能力，帮助电视做 HDR 映射；数据不准确会导致错误的色调映射。它不会把 SDR 像素自动变成 HDR。",
        "ContentLightLevelInfo":
            "写入内容最大亮度和平均亮度提示，帮助显示设备进行 HDR 亮度映射；数值错误可能导致过度压暗或高光裁切。",
        "ProjectionKind":
            "只读值说明当前投影模型，影响播放器如何把二维帧映射到空间视图；这里用于诊断，不会改变码流。",
        "ViewPackingKind":
            "只读值说明多个视图如何打包；播放器依赖它拆分视角。这里用于确认编码器实际选择，不可直接修改。",
        "MVHEVCVideoLayerIDs":
            "定义多视角 HEVC 各视图对应的视频层；数组错误会让解码器无法关联层，导致缺视图或播放失败。",
        "MVHEVCViewIDs":
            "定义每个视角的标识及顺序；必须与视频层和左右眼映射一致，否则可能串眼或无法组成空间视频。",
        "MVHEVCLeftAndRightViewIDs":
            "明确左右眼对应的视图标识；顺序或编号错误会造成深度反转、观看不适或空间效果失效。",
        "HeroEye":
            "只读值指出主要视角，影响单视图兼容播放时优先使用哪只眼；用于核对实际输出。",
        "StereoCameraBaseline":
            "只读基线表示左右相机光心距离，影响立体深度尺度；元数据错误会使空间比例不自然。这里仅显示实际值。",
        "HorizontalDisparityAdjustment":
            "只读水平视差修正影响零视差平面和观看舒适度；数值异常可能造成画面过度凸出或凹入。",
        "HasLeftStereoEyeView":
            "开启表示码流包含左眼视图；与实际轨道不一致会让播放器误判空间内容。",
        "HasRightStereoEyeView":
            "开启表示码流包含右眼视图；左右眼标记必须与视图 ID 和层 ID 一致。",
        "HorizontalFieldOfView":
            "视场角越大，空间播放呈现更宽广的视野；数值与相机实际不符会造成尺度或透视感错误。它是元数据，不会改变像素。",
        "CameraCalibrationDataLensCollection":
            "镜头标定集合用于空间几何校正；准确数据可减少畸变和视角错位，错误数据会破坏深度与配准。",
        "NumberOfPendingFrames":
            "只读值越高表示编码器内部积压越多，延迟和内存压力越大；持续增长可能说明输入速度超过编码能力。",
        "PixelBufferPoolIsShared":
            "只读值说明像素缓冲池是否在组件间共享；共享通常减少复制和内存带宽，但不直接代表画质高低。",
        "VideoEncoderPixelBufferAttributes":
            "只读字典列出编码器实际要求的像素格式、尺寸和缓冲属性；用于诊断输入转换与零拷贝条件。",
        "ReferenceBufferCount":
            "只读值越大通常表示编码器保留更多参考帧，可能提高压缩效率，也增加内存和解码复杂度。",
        "UsingHardwareAcceleratedVideoEncoder":
            "true 表示当前会话已确认使用硬件编码；false 或查询失败意味着不能宣称硬件路径，并可能显著影响速度与能耗。",
        "UsingGPURegistryID":
            "只读标识用于确认实际关联的 GPU 设备；它主要用于复现实验和诊断，不代表性能评分。",
        "EstimatedAverageBytesPerFrame":
            "只读估计值越高，通常意味着预计码率或单帧复杂度更高；它会随设置和编码过程变化，不等同于最终实测值。",
        "SupportsBaseFrameQP":
            "true 表示编码器支持逐帧基础量化参数请求，可做更细粒度码率控制；false 表示这类逐帧控制不可用。",
        "RecommendedParallelizedSubdivisionMinimumFrameCount":
            "只读建议给出值得并行分段的最少帧数；低于它时并行开销可能大于收益。",
        "RecommendedParallelizedSubdivisionMinimumDuration":
            "只读建议给出值得并行分段的最短时长；用于任务切分，不会直接改变当前编码。",
        "SupportedPresetDictionaries":
            "只读字典列出编码器公开的原生预设组合；用于诊断和复现，不会自动应用其中任何值。",
    ]

    static func text(for key: String) -> String {
        values[key] ?? "该字段会改变编码器的原生行为；请结合本机支持范围和输出报告核对实际结果。"
    }

    static func hasDedicatedText(for key: String) -> Bool {
        values[key] != nil
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
    var readback: NativeCompressionPropertyReadback? = nil

    var isWritable: Bool {
        readWriteStatus == kVTPropertyReadWriteStatus_ReadWrite as String
    }

    var isReadOnly: Bool {
        readWriteStatus == kVTPropertyReadWriteStatus_ReadOnly as String
    }
}

struct NativeCompressionPropertyReadback: Codable, Equatable, Identifiable, Sendable {
    let key: String
    let value: NativeCompressionValue?
    let status: Int32

    var id: String { key }

    var succeeded: Bool {
        status == noErr
    }

    var displayText: String {
        if status != noErr {
            return "查询失败（OSStatus \(status)）"
        }
        return value?.displayText ?? "系统返回空值"
    }
}

struct TranscodeRuntimeDiagnosticsSnapshot: Codable, Equatable, Identifiable, Sendable {
    let stage: String
    let stageTitle: String
    let progress: Double
    let values: [NativeCompressionPropertyReadback]

    var id: String {
        "\(stage)-\(String(format: "%.4f", progress))"
    }

    func readback(for key: String) -> NativeCompressionPropertyReadback? {
        values.first { $0.key == key }
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

        var properties = parseSupportedProperties(dictionary)
        for key in properties.keys.sorted()
        where NativeCompressionPropertyCatalog.byKey[key] != nil {
            properties[key]?.readback = readProperty(
                key: key,
                from: session
            )
        }

        return .ready(
            NativeCompressionCapabilities(
                encoderID: selectedEncoderID.map { $0 as String },
                width: width,
                height: height,
                properties: properties
            )
        )
    }

    static func readProperty(
        key: String,
        from session: VTCompressionSession
    ) -> NativeCompressionPropertyReadback {
        var rawValue: CFTypeRef?
        let status = VTSessionCopyProperty(
            session,
            key: key as CFString,
            allocator: kCFAllocatorDefault,
            valueOut: &rawValue
        )
        return NativeCompressionPropertyReadback(
            key: key,
            value: rawValue.map {
                NativeCompressionValue(foundationObject: $0)
            },
            status: status
        )
    }
}
