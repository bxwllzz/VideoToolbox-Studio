import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

enum MediaInspector {
    static func inspect(_ url: URL) async throws -> MediaAssetSummary {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)
        let metadataItems = try await asset.load(.metadata)

        var trackSummaries: [MediaTrackSummary] = []
        for track in tracks {
            trackSummaries.append(try await inspect(track))
        }

        var metadata: [MetadataFieldSummary] = []
        for item in metadataItems {
            metadata.append(await inspect(item))
        }

        let resourceValues = try? url.resourceValues(
            forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
        )
        let fileSize = Int64(resourceValues?.fileSize ?? 0)

        return MediaAssetSummary(
            fileName: url.lastPathComponent,
            fileSize: fileSize,
            durationSeconds: seconds(duration),
            tracks: trackSummaries.sorted {
                ($0.mediaType, $0.trackID) < ($1.mediaType, $1.trackID)
            },
            metadata: metadata.sorted {
                ($0.identifier, $0.valueFingerprint)
                    < ($1.identifier, $1.valueFingerprint)
            },
            creationDate: resourceValues?.creationDate.map(iso8601),
            modificationDate: resourceValues?.contentModificationDate.map(iso8601)
        )
    }

    static func firstVideoFormatDescription(
        from track: AVAssetTrack
    ) async throws -> CMFormatDescription {
        let formatDescriptions = try await track.load(.formatDescriptions)
        guard let formatDescription = formatDescriptions.first else {
            throw TranscodeError.unsupportedInput("视频轨道没有格式描述。")
        }
        return formatDescription
    }

    static func colorSummary(
        from formatDescription: CMFormatDescription
    ) -> MediaColorSummary {
        let extensions = (
            CMFormatDescriptionGetExtensions(formatDescription) as NSDictionary?
        ) ?? NSDictionary()
        return MediaColorSummary(
            colorPrimaries: stringValue(
                extensions.object(forKey: kCMFormatDescriptionExtension_ColorPrimaries)
            ),
            transferFunction: stringValue(
                extensions.object(forKey: kCMFormatDescriptionExtension_TransferFunction)
            ),
            yCbCrMatrix: stringValue(
                extensions.object(forKey: kCMFormatDescriptionExtension_YCbCrMatrix)
            ),
            bitsPerComponent: (
                extensions.object(forKey: kCMFormatDescriptionExtension_BitsPerComponent)
                    as? NSNumber
            )?.intValue,
            masteringDisplayColorVolume: fingerprint(
                extensions.object(forKey: kCMFormatDescriptionExtension_MasteringDisplayColorVolume)
            ),
            contentLightLevelInfo: fingerprint(
                extensions.object(forKey: kCMFormatDescriptionExtension_ContentLightLevelInfo)
            )
        )
    }

    private static func inspect(_ track: AVAssetTrack) async throws -> MediaTrackSummary {
        let formatDescriptions = try await track.load(.formatDescriptions)
        let timeRange = try await track.load(.timeRange)
        let estimatedDataRate = try await track.load(.estimatedDataRate)
        let naturalTimeScale = try await track.load(.naturalTimeScale)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let languageCode = try? await track.load(.languageCode)
        let extendedLanguageTag = try? await track.load(.extendedLanguageTag)
        let metadataItems = try await track.load(.metadata)
        var metadata: [MetadataFieldSummary] = []
        for item in metadataItems {
            metadata.append(await inspect(item))
        }
        let firstFormat = formatDescriptions.first
        let codecType = firstFormat.map(CMFormatDescriptionGetMediaSubType) ?? 0

        let naturalSize: CGSize?
        let preferredTransform: CGAffineTransform?
        let color: MediaColorSummary?
        if track.mediaType == .video {
            naturalSize = try await track.load(.naturalSize)
            preferredTransform = try await track.load(.preferredTransform)
            color = firstFormat.map(colorSummary)
        } else {
            naturalSize = nil
            preferredTransform = nil
            color = nil
        }

        return MediaTrackSummary(
            trackID: track.trackID,
            mediaType: track.mediaType.rawValue,
            codecType: codecType,
            codecFourCC: mediaFourCC(codecType),
            naturalWidth: naturalSize.map { Double($0.width) },
            naturalHeight: naturalSize.map { Double($0.height) },
            nominalFrameRate: Double(nominalFrameRate),
            estimatedDataRate: Double(estimatedDataRate),
            timeRangeStartSeconds: seconds(timeRange.start),
            timeRangeDurationSeconds: seconds(timeRange.duration),
            naturalTimeScale: naturalTimeScale,
            preferredTransform: preferredTransform.map {
                MatrixSummary(
                    a: Double($0.a),
                    b: Double($0.b),
                    c: Double($0.c),
                    d: Double($0.d),
                    tx: Double($0.tx),
                    ty: Double($0.ty)
                )
            },
            languageCode: languageCode,
            extendedLanguageTag: extendedLanguageTag,
            color: color,
            metadata: metadata.sorted {
                ($0.identifier, $0.valueFingerprint)
                    < ($1.identifier, $1.valueFingerprint)
            }
        )
    }

    private static func inspect(_ item: AVMetadataItem) async -> MetadataFieldSummary {
        let value = try? await item.load(.value)
        return MetadataFieldSummary(
            identifier: item.identifier?.rawValue ?? "unknown",
            keySpace: item.keySpace?.rawValue ?? "unknown",
            commonKey: item.commonKey?.rawValue ?? "unknown",
            valueFingerprint: fingerprint(value) ?? "nil"
        )
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            value
        case let value as NSString:
            value as String
        case .none:
            nil
        default:
            String(describing: value)
        }
    }

    private static func fingerprint(_ value: Any?) -> String? {
        guard let value else {
            return nil
        }
        if let data = value as? Data {
            return "sha256:" + SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(
               withJSONObject: value,
               options: [.sortedKeys]
           )
        {
            return "sha256:" + SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        }
        return String(describing: value)
    }

    private static func seconds(_ time: CMTime) -> Double {
        guard time.isNumeric else {
            return 0
        }
        return CMTimeGetSeconds(time)
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
