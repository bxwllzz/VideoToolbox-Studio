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
    case automatic
    case h264
    case hevc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            "自动保真"
        case .h264:
            "H.264"
        case .hevc:
            "HEVC"
        }
    }

    func resolvedCodecType(isHDR: Bool) throws -> CMVideoCodecType {
        switch self {
        case .automatic, .hevc:
            return kCMVideoCodecType_HEVC
        case .h264:
            guard !isHDR else {
                throw TranscodeError.hdrRequiresHEVC
            }
            return kCMVideoCodecType_H264
        }
    }
}

enum TranscodeRateControl: String, Codable, CaseIterable, Identifiable, Sendable {
    case sourceRatio
    case fixedBitRate
    case quality

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sourceRatio:
            "源码率比例"
        case .fixedBitRate:
            "固定平均码率"
        case .quality:
            "质量因子"
        }
    }
}

struct TranscodeSettings: Codable, Equatable, Sendable {
    var targetCodec: TranscodeTargetCodec
    var rateControl: TranscodeRateControl
    var sourceBitRateRatio: Double
    var fixedBitRate: Int
    var quality: Double
    var dataRateLimitMultiplier: Double?
    var maxKeyFrameInterval: Int
    var maxKeyFrameIntervalDuration: Double
    var allowFrameReordering: Bool
    var realTime: Bool
    var prioritizeEncodingSpeedOverQuality: Bool

    static let balanced = TranscodeSettings(
        targetCodec: .automatic,
        rateControl: .sourceRatio,
        sourceBitRateRatio: 0.60,
        fixedBitRate: 8_000_000,
        quality: 0.76,
        dataRateLimitMultiplier: 1.50,
        maxKeyFrameInterval: 0,
        maxKeyFrameIntervalDuration: 2,
        allowFrameReordering: true,
        realTime: false,
        prioritizeEncodingSpeedOverQuality: false
    )

    func validate() throws {
        guard (0.10...1.50).contains(sourceBitRateRatio) else {
            throw TranscodeError.invalidSettings("源码率比例必须在 10%～150% 之间。")
        }
        guard (100_000...200_000_000).contains(fixedBitRate) else {
            throw TranscodeError.invalidSettings("固定平均码率必须在 0.1～200 Mbps 之间。")
        }
        guard (0...1).contains(quality) else {
            throw TranscodeError.invalidSettings("质量因子必须在 0～1 之间。")
        }
        if let dataRateLimitMultiplier,
           !(1...4).contains(dataRateLimitMultiplier)
        {
            throw TranscodeError.invalidSettings("峰值码率倍数必须在 1～4 之间。")
        }
        guard (0...1_000_000).contains(maxKeyFrameInterval) else {
            throw TranscodeError.invalidSettings("最大关键帧间隔不能小于 0。")
        }
        guard (0...3_600).contains(maxKeyFrameIntervalDuration) else {
            throw TranscodeError.invalidSettings("最大关键帧时长必须在 0～3600 秒之间。")
        }
    }
}

enum TranscodePreset: String, CaseIterable, Identifiable, Sendable {
    case fidelity
    case balanced
    case compact
    case compatible
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fidelity:
            "保真优先"
        case .balanced:
            "均衡压缩"
        case .compact:
            "更小体积"
        case .compatible:
            "H.264 兼容"
        case .custom:
            "专业自定义"
        }
    }

    var summary: String {
        switch self {
        case .fidelity:
            "HEVC，源视频码率约 80%，保留更多画面细节。"
        case .balanced:
            "HEVC，源视频码率约 60%，适合大多数视频。"
        case .compact:
            "HEVC，源视频码率约 40%，优先减小文件。"
        case .compatible:
            "H.264，源视频码率约 70%；HDR 输入会明确拒绝。"
        case .custom:
            "直接控制公开的 VideoToolbox 编码参数。"
        }
    }

    var settings: TranscodeSettings {
        switch self {
        case .fidelity:
            var value = TranscodeSettings.balanced
            value.sourceBitRateRatio = 0.80
            value.quality = 0.88
            return value
        case .balanced:
            return .balanced
        case .compact:
            var value = TranscodeSettings.balanced
            value.sourceBitRateRatio = 0.40
            value.quality = 0.62
            value.dataRateLimitMultiplier = 1.25
            return value
        case .compatible:
            var value = TranscodeSettings.balanced
            value.targetCodec = .h264
            value.sourceBitRateRatio = 0.70
            return value
        case .custom:
            return .balanced
        }
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
    let profileLevel: String
    let pixelFormat: UInt32
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
            "HDR 或 10-bit 输入不能用 H.264 保真输出，请选择“自动保真”或 HEVC。"
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
