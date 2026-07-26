import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

struct TranscodeSource: Identifiable, @unchecked Sendable {
    let id: String
    let asset: AVAsset
    let fileName: String
    let fileSize: Int64?
    let creationDate: Date?
    let modificationDate: Date?
    let securityScopedURL: URL?
    let photoLibraryAssetIdentifier: String?

    init(
        id: String,
        asset: AVAsset,
        fileName: String,
        fileSize: Int64?,
        creationDate: Date?,
        modificationDate: Date?,
        securityScopedURL: URL? = nil,
        photoLibraryAssetIdentifier: String? = nil
    ) {
        self.id = id
        self.asset = asset
        self.fileName = fileName
        self.fileSize = fileSize
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.securityScopedURL = securityScopedURL
        self.photoLibraryAssetIdentifier = photoLibraryAssetIdentifier
    }

    static func localFile(_ url: URL) -> TranscodeSource {
        let values = try? url.resourceValues(
            forKeys: [
                .fileSizeKey,
                .creationDateKey,
                .contentModificationDateKey,
            ]
        )
        return TranscodeSource(
            id: url.standardizedFileURL.absoluteString,
            asset: AVURLAsset(url: url),
            fileName: url.lastPathComponent,
            fileSize: values?.fileSize.map { Int64($0) },
            creationDate: values?.creationDate,
            modificationDate: values?.contentModificationDate,
            securityScopedURL: url,
            photoLibraryAssetIdentifier: nil
        )
    }
}

enum TranscodeTargetCodec: String, Codable, CaseIterable, Identifiable, Sendable {
    case h264
    case hevc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h264:
            "H.264"
        case .hevc:
            "HEVC"
        }
    }

    func resolvedCodecType(isHDR: Bool) throws -> CMVideoCodecType {
        switch self {
        case .hevc:
            return kCMVideoCodecType_HEVC
        case .h264:
            guard !isHDR else {
                throw TranscodeError.hdrRequiresHEVC
            }
            return kCMVideoCodecType_H264
        }
    }
}

struct TranscodeSettings: Codable, Equatable, Sendable {
    var targetCodec: TranscodeTargetCodec
    var nativeProperties: [String: NativeCompressionValue]

    static let defaultSettings = TranscodeSettings(
        targetCodec: .hevc,
        nativeProperties: [
            "AverageBitRate": .number(8_000_000),
            "MaxKeyFrameInterval": .number(0),
            "MaxKeyFrameIntervalDuration": .number(0),
            "AllowFrameReordering": .bool(true),
            "RealTime": .bool(false),
            "PrioritizeEncodingSpeedOverQuality": .bool(false),
        ]
    )

    var multiPassStorageEnabled: Bool {
        get {
            nativeProperties["MultiPassStorage"] != nil
        }
        set {
            if newValue {
                nativeProperties["MultiPassStorage"] = .bool(true)
                nativeProperties.removeValue(forKey: "RealTime")
                nativeProperties.removeValue(
                    forKey: "PrioritizeEncodingSpeedOverQuality"
                )
            } else {
                nativeProperties.removeValue(forKey: "MultiPassStorage")
            }
        }
    }

    var averageBitRate: Int? {
        get {
            nativeProperties["AverageBitRate"]?.numberValue.map {
                Int($0.rounded())
            }
        }
        set {
            setNumber(newValue.map(Double.init), forKey: "AverageBitRate")
        }
    }

    var quality: Double? {
        get {
            nativeProperties["Quality"]?.numberValue
        }
        set {
            setNumber(newValue, forKey: "Quality")
        }
    }

    var dataRateLimits: [Double]? {
        get {
            guard let values = nativeProperties["DataRateLimits"]?.arrayValue else {
                return nil
            }
            let numbers = values.compactMap(\.numberValue)
            return numbers.count == values.count ? numbers : nil
        }
        set {
            if let newValue {
                nativeProperties["DataRateLimits"] = .array(
                    newValue.map(NativeCompressionValue.number)
                )
            } else {
                nativeProperties.removeValue(forKey: "DataRateLimits")
            }
        }
    }

    var maxKeyFrameInterval: Int {
        get {
            Int(
                nativeProperties["MaxKeyFrameInterval"]?.numberValue?.rounded()
                    ?? 0
            )
        }
        set {
            nativeProperties["MaxKeyFrameInterval"] = .number(Double(newValue))
        }
    }

    var maxKeyFrameIntervalDuration: Double {
        get {
            nativeProperties["MaxKeyFrameIntervalDuration"]?.numberValue ?? 0
        }
        set {
            nativeProperties["MaxKeyFrameIntervalDuration"] = .number(newValue)
        }
    }

    var allowFrameReordering: Bool {
        get {
            nativeProperties["AllowFrameReordering"]?.boolValue ?? true
        }
        set {
            nativeProperties["AllowFrameReordering"] = .bool(newValue)
        }
    }

    var realTime: Bool {
        get {
            nativeProperties["RealTime"]?.boolValue ?? false
        }
        set {
            nativeProperties["RealTime"] = .bool(newValue)
        }
    }

    var prioritizeEncodingSpeedOverQuality: Bool {
        get {
            nativeProperties["PrioritizeEncodingSpeedOverQuality"]?.boolValue
                ?? false
        }
        set {
            nativeProperties["PrioritizeEncodingSpeedOverQuality"] = .bool(newValue)
        }
    }

    var selectedRateControlKey: String? {
        NativeCompressionPropertyCatalog.rateControlKeys.first {
            nativeProperties[$0] != nil
        }
    }

    mutating func selectRateControlProperty(_ key: String?) {
        for candidate in NativeCompressionPropertyCatalog.rateControlKeys {
            nativeProperties.removeValue(forKey: candidate)
        }
        guard let key,
              let descriptor = NativeCompressionPropertyCatalog.byKey[key],
              descriptor.applies(to: targetCodec)
        else {
            nativeProperties.removeValue(forKey: "DataRateLimits")
            for vbvKey in NativeCompressionPropertyCatalog.vbvKeys {
                nativeProperties.removeValue(forKey: vbvKey)
            }
            return
        }
        nativeProperties[key] = descriptor.suggestedValue ?? .number(0)
        if key != "AverageBitRate" {
            nativeProperties.removeValue(forKey: "DataRateLimits")
        }
        if key != "ConstantBitRate", key != "VariableBitRate" {
            for vbvKey in NativeCompressionPropertyCatalog.vbvKeys {
                nativeProperties.removeValue(forKey: vbvKey)
            }
        } else if key == "ConstantBitRate" {
            nativeProperties.removeValue(forKey: "VBVMaxBitRate")
        }
    }

    mutating func selectCodec(_ codec: TranscodeTargetCodec) {
        targetCodec = codec
        for descriptor in NativeCompressionPropertyCatalog.descriptors
        where !descriptor.applies(to: codec) {
            nativeProperties.removeValue(forKey: descriptor.key)
        }
    }

    mutating func setNativeValue(
        _ value: NativeCompressionValue?,
        forKey key: String
    ) {
        if let value {
            nativeProperties[key] = value
        } else {
            nativeProperties.removeValue(forKey: key)
        }
    }

    func isVisibleInNativeEditor(
        _ descriptor: NativeCompressionPropertyDescriptor
    ) -> Bool {
        if nativeProperties["AllowTemporalCompression"]?.boolValue == false,
           (
               descriptor.key == "AllowFrameReordering"
                   || descriptor.key == "AllowOpenGOP"
           ) {
            return false
        }
        if multiPassStorageEnabled,
           (
               descriptor.key == "RealTime"
                   || descriptor.key == "PrioritizeEncodingSpeedOverQuality"
           ) {
            return false
        }
        if realTime || prioritizeEncodingSpeedOverQuality,
           descriptor.key == "MultiPassStorage" {
            return false
        }
        if descriptor.key == "MaximumRealTimeFrameRate", !realTime {
            return false
        }
        if descriptor.key == "FieldDetail",
           nativeProperties["FieldCount"]?.numberValue != 2 {
            return false
        }
        if descriptor.key == "GammaLevel",
           nativeProperties["TransferFunction"]?.stringValue != "UseGamma" {
            return false
        }
        if nativeProperties["PreserveAlphaChannel"]?.boolValue == false,
           (
               descriptor.key == "TargetQualityForAlpha"
                   || descriptor.key == "AlphaChannelMode"
           ) {
            return false
        }
        return true
    }

    func sanitized(
        for capabilities: NativeCompressionCapabilities
    ) -> TranscodeSettings {
        var result = self
        for key in Array(result.nativeProperties.keys) {
            guard let descriptor = NativeCompressionPropertyCatalog.byKey[key],
                  descriptor.applies(to: result.targetCodec),
                  capabilities.isWritable(descriptor)
            else {
                result.nativeProperties.removeValue(forKey: key)
                continue
            }
        }

        let selectedRateControlKey = result.selectedRateControlKey
        for key in NativeCompressionPropertyCatalog.rateControlKeys
        where key != selectedRateControlKey {
            result.nativeProperties.removeValue(forKey: key)
        }
        result.removeInactiveDependentProperties()
        return result
    }

    private mutating func removeInactiveDependentProperties() {
        if selectedRateControlKey != "AverageBitRate" {
            nativeProperties.removeValue(forKey: "DataRateLimits")
        }
        if selectedRateControlKey != "ConstantBitRate",
           selectedRateControlKey != "VariableBitRate" {
            for key in NativeCompressionPropertyCatalog.vbvKeys {
                nativeProperties.removeValue(forKey: key)
            }
        } else if selectedRateControlKey == "ConstantBitRate" {
            nativeProperties.removeValue(forKey: "VBVMaxBitRate")
        }
        if nativeProperties["AllowTemporalCompression"]?.boolValue == false {
            nativeProperties.removeValue(forKey: "AllowFrameReordering")
            nativeProperties.removeValue(forKey: "AllowOpenGOP")
        }
        if !realTime {
            nativeProperties.removeValue(forKey: "MaximumRealTimeFrameRate")
        }
        if nativeProperties["FieldCount"]?.numberValue != 2 {
            nativeProperties.removeValue(forKey: "FieldDetail")
        }
        if nativeProperties["TransferFunction"]?.stringValue != "UseGamma" {
            nativeProperties.removeValue(forKey: "GammaLevel")
        }
        if nativeProperties["PreserveAlphaChannel"]?.boolValue == false {
            nativeProperties.removeValue(forKey: "TargetQualityForAlpha")
            nativeProperties.removeValue(forKey: "AlphaChannelMode")
        }
        if multiPassStorageEnabled {
            nativeProperties.removeValue(forKey: "RealTime")
            nativeProperties.removeValue(
                forKey: "PrioritizeEncodingSpeedOverQuality"
            )
        }
    }

    private mutating func setNumber(_ value: Double?, forKey key: String) {
        if let value {
            nativeProperties[key] = .number(value)
        } else {
            nativeProperties.removeValue(forKey: key)
        }
    }

    func validate() throws {
        if multiPassStorageEnabled,
           (realTime || prioritizeEncodingSpeedOverQuality)
        {
            throw TranscodeError.invalidSettings(
                "MultiPassStorage 不能同时启用 RealTime 或 "
                    + "PrioritizeEncodingSpeedOverQuality。"
            )
        }
        let rateControlCount = NativeCompressionPropertyCatalog.rateControlKeys
            .filter { nativeProperties[$0] != nil }
            .count
        if rateControlCount > 1 {
            throw TranscodeError.invalidSettings(
                "AverageBitRate、ConstantBitRate、VariableBitRate、Quality "
                    + "与 ConstantQualityFactor 只能设置其中一项。"
            )
        }
        if nativeProperties["DataRateLimits"] != nil,
           selectedRateControlKey != "AverageBitRate" {
            throw TranscodeError.invalidSettings(
                "DataRateLimits 仅在当前选择 AverageBitRate 时显示和写入。"
            )
        }
        if nativeProperties["VBVMaxBitRate"] != nil,
           selectedRateControlKey != "VariableBitRate" {
            throw TranscodeError.invalidSettings(
                "VBVMaxBitRate 仅能与 VariableBitRate 同时设置。"
            )
        }
        let hasVBVTiming = nativeProperties["VBVBufferDuration"] != nil
            || nativeProperties["VBVInitialDelayPercentage"] != nil
        if hasVBVTiming,
           selectedRateControlKey != "VariableBitRate",
           selectedRateControlKey != "ConstantBitRate" {
            throw TranscodeError.invalidSettings(
                "VBVBufferDuration 与 VBVInitialDelayPercentage "
                    + "仅能用于 ConstantBitRate 或 VariableBitRate。"
            )
        }
        if let dataRateLimits {
            guard dataRateLimits.count.isMultiple(of: 2),
                  !dataRateLimits.isEmpty,
                  dataRateLimits.enumerated().allSatisfy({
                      $0.element.isFinite && $0.element > 0
                  })
            else {
                throw TranscodeError.invalidSettings(
                    "DataRateLimits 必须交替包含正数的数据量（字节）"
                        + "与时间窗口（秒）。"
                )
            }
        }
        if nativeProperties["AllowTemporalCompression"]?.boolValue == false,
           (
               allowFrameReordering
                   || nativeProperties["AllowOpenGOP"]?.boolValue == true
           ) {
            throw TranscodeError.invalidSettings(
                "AllowTemporalCompression 关闭时不能启用 "
                    + "AllowFrameReordering 或 AllowOpenGOP。"
            )
        }
        if nativeProperties["MaximumRealTimeFrameRate"] != nil, !realTime {
            throw TranscodeError.invalidSettings(
                "MaximumRealTimeFrameRate 仅能在 RealTime 开启时设置。"
            )
        }
        if nativeProperties["FieldDetail"] != nil,
           nativeProperties["FieldCount"]?.numberValue != 2 {
            throw TranscodeError.invalidSettings(
                "FieldDetail 仅能在 FieldCount 为 2 时设置。"
            )
        }
        if nativeProperties["GammaLevel"] != nil,
           nativeProperties["TransferFunction"]?.stringValue != "UseGamma" {
            throw TranscodeError.invalidSettings(
                "GammaLevel 仅能与 TransferFunction=UseGamma 同时设置。"
            )
        }
        if nativeProperties["PreserveAlphaChannel"]?.boolValue == false,
           (
               nativeProperties["TargetQualityForAlpha"] != nil
                   || nativeProperties["AlphaChannelMode"] != nil
           ) {
            throw TranscodeError.invalidSettings(
                "PreserveAlphaChannel 关闭时不能设置 Alpha 子字段。"
            )
        }
        if targetCodec == .h264,
           (
               nativeProperties["ProfileLevel"]?.stringValue ?? ""
           ).localizedCaseInsensitiveContains("Baseline"),
           nativeProperties["H264EntropyMode"]?.stringValue == "CABAC" {
            throw TranscodeError.invalidSettings(
                "H.264 Baseline ProfileLevel 不能使用 CABAC。"
            )
        }
        if let minimumQP = nativeProperties["MinAllowedFrameQP"]?.numberValue,
           let maximumQP = nativeProperties["MaxAllowedFrameQP"]?.numberValue,
           minimumQP > maximumQP {
            throw TranscodeError.invalidSettings(
                "MinAllowedFrameQP 不能大于 MaxAllowedFrameQP。"
            )
        }

        for (key, value) in nativeProperties {
            guard let descriptor = NativeCompressionPropertyCatalog.byKey[key] else {
                throw TranscodeError.invalidSettings(
                    "未知或非公开的 VideoToolbox 属性：\(key)。"
                )
            }
            guard descriptor.applies(to: targetCodec) else {
                throw TranscodeError.invalidSettings(
                    "\(key) 不适用于当前 \(targetCodec.title) 编码器。"
                )
            }
            guard descriptor.isPubliclySettable else {
                throw TranscodeError.invalidSettings(
                    "\(key) 是只读原生属性，不能写入。"
                )
            }
            guard descriptor.accepts(value) else {
                throw TranscodeError.invalidSettings(
                    "\(key) 的值类型与原生字段类型不一致。"
                )
            }
            if let number = value.numberValue {
                guard number.isFinite else {
                    throw TranscodeError.invalidSettings("\(key) 必须是有限数值。")
                }
                if let minimum = descriptor.minimum, number < minimum {
                    throw TranscodeError.invalidSettings(
                        "\(key) 不能小于 \(minimum)。"
                    )
                }
                if let maximum = descriptor.maximum, number > maximum {
                    throw TranscodeError.invalidSettings(
                        "\(key) 不能大于 \(maximum)。"
                    )
                }
            }
        }
    }
}

private extension NativeCompressionPropertyDescriptor {
    func accepts(_ value: NativeCompressionValue) -> Bool {
        switch (kind, value) {
        case (.boolean, .bool),
             (.number, .number),
             (.enumeration, .string),
             (.multiPassStorage, .bool),
             (.json, _):
            true
        case (.base64Data, .string(let value)):
            Data(base64Encoded: value) != nil
        case (.integer, .number(let number)):
            number.rounded() == number
                && number >= Double(Int64.min)
                && number <= Double(Int64.max)
        case (.dataRateLimits, .array(let values)):
            !values.isEmpty
                && values.count.isMultiple(of: 2)
                && values.allSatisfy {
                    guard case .number(let number) = $0 else {
                        return false
                    }
                    return number.isFinite && number > 0
                }
        default:
            false
        }
    }
}

extension TranscodeSettings {
    private enum CodingKeys: String, CodingKey {
        case targetCodec
        case nativeProperties

        // 仅用于读取旧版设置；新偏好只写入 nativeProperties。
        case multiPassStorageEnabled
        case multiPassMode
        case encodingQuality
        case averageBitRate
        case dataRateLimits

        // 仅用于读取旧版 App 自造字段；新报告和新偏好不再写入。
        case rateControl
        case fixedBitRate
        case quality
        case dataRateLimitMultiplier
        case maxKeyFrameInterval
        case maxKeyFrameIntervalDuration
        case allowFrameReordering
        case realTime
        case prioritizeEncodingSpeedOverQuality
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = TranscodeSettings.defaultSettings

        let savedCodec = try container.decodeIfPresent(
            String.self,
            forKey: .targetCodec
        )
        if savedCodec == "automatic" {
            targetCodec = .hevc
        } else {
            targetCodec = savedCodec
                .flatMap(TranscodeTargetCodec.init(rawValue:))
                ?? fallback.targetCodec
        }
        if let properties = try container.decodeIfPresent(
            [String: NativeCompressionValue].self,
            forKey: .nativeProperties
        ) {
            nativeProperties = properties
            return
        }
        nativeProperties = [:]

        if let enabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .multiPassStorageEnabled
        ) {
            if enabled {
                nativeProperties["MultiPassStorage"] = .bool(true)
            }
        } else {
            let legacyMultiPassMode = try container.decodeIfPresent(
                String.self,
                forKey: .multiPassMode
            )
            let legacyEncodingQuality = try container.decodeIfPresent(
                String.self,
                forKey: .encodingQuality
            )
            if legacyMultiPassMode == "automatic"
                || legacyEncodingQuality == "refined" {
                nativeProperties["MultiPassStorage"] = .bool(true)
            }
        }

        if container.contains(.averageBitRate) {
            if let value = try container.decodeIfPresent(
                Int.self,
                forKey: .averageBitRate
            ) {
                nativeProperties["AverageBitRate"] = .number(Double(value))
            }
            if let value = try container.decodeIfPresent(
                Double.self,
                forKey: .quality
            ) {
                nativeProperties["Quality"] = .number(value)
            }
            if let values = try container.decodeIfPresent(
                [Double].self,
                forKey: .dataRateLimits
            ) {
                nativeProperties["DataRateLimits"] = .array(
                    values.map(NativeCompressionValue.number)
                )
            }
        } else {
            let legacyRateControl = try container.decodeIfPresent(
                String.self,
                forKey: .rateControl
            )
            if legacyRateControl == "quality" {
                let value = try container.decodeIfPresent(
                    Double.self,
                    forKey: .quality
                ) ?? 0.76
                nativeProperties["Quality"] = .number(value)
            } else {
                let value = try container.decodeIfPresent(
                    Int.self,
                    forKey: .fixedBitRate
                ) ?? fallback.averageBitRate
                if let value {
                    nativeProperties["AverageBitRate"] = .number(Double(value))
                }
            }

            if let multiplier = try container.decodeIfPresent(
                Double.self,
                forKey: .dataRateLimitMultiplier
            ), let averageBitRate {
                nativeProperties["DataRateLimits"] = .array([
                    .number(Double(averageBitRate) * multiplier / 8),
                    .number(1),
                ])
            }
        }
        let maxKeyFrameInterval = try container.decodeIfPresent(
            Int.self,
            forKey: .maxKeyFrameInterval
        ) ?? fallback.maxKeyFrameInterval
        nativeProperties["MaxKeyFrameInterval"] = .number(
            Double(maxKeyFrameInterval)
        )
        let maxKeyFrameIntervalDuration = try container.decodeIfPresent(
            Double.self,
            forKey: .maxKeyFrameIntervalDuration
        ) ?? fallback.maxKeyFrameIntervalDuration
        nativeProperties["MaxKeyFrameIntervalDuration"] = .number(
            maxKeyFrameIntervalDuration
        )
        let allowFrameReordering = try container.decodeIfPresent(
            Bool.self,
            forKey: .allowFrameReordering
        ) ?? fallback.allowFrameReordering
        nativeProperties["AllowFrameReordering"] = .bool(allowFrameReordering)
        let realTime = try container.decodeIfPresent(
            Bool.self,
            forKey: .realTime
        ) ?? fallback.realTime
        nativeProperties["RealTime"] = .bool(realTime)
        let speedPriority = try container.decodeIfPresent(
            Bool.self,
            forKey: .prioritizeEncodingSpeedOverQuality
        ) ?? fallback.prioritizeEncodingSpeedOverQuality
        nativeProperties["PrioritizeEncodingSpeedOverQuality"] = .bool(
            speedPriority
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(targetCodec.rawValue, forKey: .targetCodec)
        try container.encode(nativeProperties, forKey: .nativeProperties)
    }
}

struct MatrixSummary: Codable, Equatable, Sendable {
    let a: Double
    let b: Double
    let c: Double
    let d: Double
    let tx: Double
    let ty: Double
}

struct MediaColorSummary: Codable, Equatable, Sendable {
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?
    let bitsPerComponent: Int?
    let masteringDisplayColorVolume: String?
    let contentLightLevelInfo: String?

    var isHDR: Bool {
        let transfer = transferFunction?.lowercased() ?? ""
        let primaries = colorPrimaries?.lowercased() ?? ""
        return transfer.contains("2084")
            || transfer.contains("2100")
            || transfer.contains("hlg")
            || transfer.contains("pq")
            || primaries.contains("2020")
            || (bitsPerComponent ?? 8) > 8
    }
}

struct MediaTrackSummary: Codable, Equatable, Sendable {
    let trackID: Int32
    let mediaType: String
    let codecType: UInt32
    let codecFourCC: String
    let naturalWidth: Double?
    let naturalHeight: Double?
    let nominalFrameRate: Double
    let estimatedDataRate: Double
    let timeRangeStartSeconds: Double
    let timeRangeDurationSeconds: Double
    let naturalTimeScale: Int32
    let preferredTransform: MatrixSummary?
    let languageCode: String?
    let extendedLanguageTag: String?
    let color: MediaColorSummary?
    let metadata: [MetadataFieldSummary]
}

struct MetadataFieldSummary: Codable, Equatable, Hashable, Sendable {
    let identifier: String
    let keySpace: String
    let commonKey: String
    let valueFingerprint: String
}

struct MediaAssetSummary: Codable, Equatable, Sendable {
    let fileName: String
    let fileSize: Int64
    let durationSeconds: Double
    let tracks: [MediaTrackSummary]
    let metadata: [MetadataFieldSummary]
    let creationDate: String?
    let modificationDate: String?

    var videoTracks: [MediaTrackSummary] {
        tracks.filter { $0.mediaType == AVMediaType.video.rawValue }
    }

    var nonVideoTracks: [MediaTrackSummary] {
        tracks.filter { $0.mediaType != AVMediaType.video.rawValue }
    }
}

struct PreservationCheck: Codable, Equatable, Sendable {
    let name: String
    let passed: Bool
    let inputValue: String
    let outputValue: String
    let detail: String
}

struct ResolvedTranscodeSettings: Codable, Equatable, Sendable {
    let codecType: UInt32
    let codecFourCC: String
    let multiPassStorageEnabled: Bool
    let profileLevel: String
    let pixelFormat: UInt32
    let nativeProperties: [String: NativeCompressionValue]
    let averageBitRate: Int?
    let quality: Double?
    let dataRateLimits: [Double]?
    let expectedFrameRate: Double
    let maxKeyFrameInterval: Int
    let maxKeyFrameIntervalDuration: Double
    let allowFrameReordering: Bool
    let realTime: Bool
    let prioritizeEncodingSpeedOverQuality: Bool
}

struct TranscodeSizeEstimate: Equatable, Sendable {
    let sourceFileName: String
    let sampledDurationSeconds: Double
    let sourceDurationSeconds: Double
    let estimatedOutputBytes: Int64
    let lowerBoundBytes: Int64
    let upperBoundBytes: Int64
    let estimatedOutputToInputRatio: Double?
}

enum TranscodeError: LocalizedError, Equatable {
    case invalidSettings(String)
    case unsupportedInput(String)
    case multipleVideoTracks(Int)
    case hdrRequiresHEVC
    case cannotPreserveTrack(String)
    case readerFailed(String)
    case writerFailed(String)
    case compressionSessionFailed(OSStatus)
    case propertyRejected(String, OSStatus)
    case frameEncodingFailed(OSStatus)
    case cancelled
    case verificationFailed([String])

    var errorDescription: String? {
        switch self {
        case .invalidSettings(let message),
             .unsupportedInput(let message):
            message
        case .multipleVideoTracks(let count):
            "输入包含 \(count) 条视频轨道；当前版本为避免静默丢失，只接受单视频轨道文件。"
        case .hdrRequiresHEVC:
            "HDR 或 10-bit 输入不能用 H.264 保真输出，请选择 HEVC。"
        case .cannotPreserveTrack(let description):
            "MOV 容器无法无损承载轨道 \(description)，任务已停止且未生成残缺输出。"
        case .readerFailed(let message):
            "读取媒体失败：\(message)"
        case .writerFailed(let message):
            "封装输出失败：\(message)"
        case .compressionSessionFailed(let status):
            "无法创建严格硬件编码会话（OSStatus \(status)）。"
        case .propertyRejected(let key, let status):
            "编码器拒绝公开属性 \(key)（OSStatus \(status)）。"
        case .frameEncodingFailed(let status):
            "视频帧编码失败（OSStatus \(status)）。"
        case .cancelled:
            "任务已取消，未完成输出已清理。"
        case .verificationFailed(let failures):
            "输出复核未通过：" + failures.joined(separator: "；")
        }
    }
}

func mediaFourCC(_ value: UInt32) -> String {
    let bytes = [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ]
    return String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", value)
}
