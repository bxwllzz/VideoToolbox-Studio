import AVFoundation
import Combine
import Foundation
import Photos
import UIKit

struct PhotoVideoItem: Identifiable {
    let asset: PHAsset

    var id: String {
        asset.localIdentifier
    }

    var creationDate: Date {
        asset.creationDate ?? .distantPast
    }

    var pixelWidth: Int {
        asset.pixelWidth
    }

    var pixelHeight: Int {
        asset.pixelHeight
    }
}

struct PhotoVideoSection: Identifiable {
    let day: Date
    let items: [PhotoVideoItem]

    var id: Date {
        day
    }
}

struct PhotoVideoMetadata: Equatable, Sendable {
    let fileSize: Int64?
    let isFileSizeEstimated: Bool
    let bitRate: Double?
    let codec: String?
}

@MainActor
final class PhotoVideoLibraryStore: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus =
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var items: [PhotoVideoItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var preparationProgress: Double?
    @Published private(set) var preparationTitle: String?
    @Published private(set) var cloudTestSeedError: String?

    private var hasRegisteredForChanges = false

    var sections: [PhotoVideoSection] {
        let calendar = Calendar.autoupdatingCurrent
        let grouped = Dictionary(grouping: items) {
            calendar.startOfDay(for: $0.creationDate)
        }
        return grouped
            .map { PhotoVideoSection(day: $0.key, items: $0.value) }
            .sorted { $0.day > $1.day }
    }

    var canReadLibrary: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    func requestAccessAndLoad() async {
        isLoading = true

        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if currentStatus == .notDetermined {
            authorizationStatus = await Self.requestAuthorization()
        } else {
            authorizationStatus = currentStatus
        }

        guard canReadLibrary else {
            items = []
            isLoading = false
            return
        }

        registerForChangesIfNeeded()
        do {
            try await PhotoLibraryCloudTestSeeder.seedIfRequested()
            cloudTestSeedError = nil
        } catch {
            cloudTestSeedError = error.localizedDescription
        }
        reloadAssets()
        isLoading = false
    }

    func reloadAssets() {
        guard canReadLibrary else {
            items = []
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: false),
        ]
        let result = PHAsset.fetchAssets(with: .video, options: options)
        var fetchedItems: [PhotoVideoItem] = []
        fetchedItems.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            fetchedItems.append(PhotoVideoItem(asset: asset))
        }
        items = fetchedItems
    }

    func prepareVideos(ids: [String]) async throws -> [TranscodeSource] {
        let itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let selectedItems = ids.compactMap { itemByID[$0] }
        guard selectedItems.count == ids.count, !selectedItems.isEmpty else {
            throw PhotoVideoImportError.selectionUnavailable
        }

        preparationProgress = 0
        defer {
            preparationProgress = nil
            preparationTitle = nil
        }

        var sources: [TranscodeSource] = []
        let totalCount = selectedItems.count
        for (index, item) in selectedItems.enumerated() {
            try Task.checkCancellation()
            preparationTitle = totalCount == 1
                ? "正在读取视频"
                : "正在读取第 \(index + 1)/\(totalCount) 个视频"
            let source = try await PhotoVideoSourceProvider.loadCurrentVersion(
                of: item.asset,
                sequence: index
            ) { [weak self] itemProgress in
                Task { @MainActor in
                    let completed = Double(index)
                    self?.preparationProgress =
                        (completed + itemProgress) / Double(totalCount)
                }
            }
            try Task.checkCancellation()
            sources.append(source)
            preparationProgress = Double(index + 1) / Double(totalCount)
        }
        return sources
    }

    private func registerForChangesIfNeeded() {
        guard !hasRegisteredForChanges else {
            return
        }
        PHPhotoLibrary.shared().register(self)
        hasRegisteredForChanges = true
    }

    private static func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }
}

@MainActor
private enum PhotoLibraryCloudTestSeeder {
    private static var hasSeeded = false

    static func seedIfRequested() async throws {
        guard ProcessInfo.processInfo.arguments.contains(
            "--seed-photo-library"
        ), !hasSeeded else {
            return
        }
        guard let sourceURL = Bundle.main.url(
            forResource: "CloudTranscodeSample",
            withExtension: "mov"
        ) else {
            throw PhotoVideoImportError.cloudTestSeedUnavailable
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(
                    atFileURL: sourceURL
                )
            }, completionHandler: { success, error in
                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(
                        throwing: error
                            ?? PhotoVideoImportError.cloudTestSeedFailed
                    )
                }
            })
        }
        hasSeeded = true
    }
}

extension PhotoVideoLibraryStore: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            reloadAssets()
        }
    }
}

@MainActor
final class PhotoVideoCellModel: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var metadata: PhotoVideoMetadata?
    @Published private(set) var metadataUnavailable = false

    private let asset: PHAsset
    private var imageRequestID: PHImageRequestID?
    private var metadataTask: Task<Void, Never>?

    init(asset: PHAsset) {
        self.asset = asset
    }

    func load(targetSize: CGSize) {
        if image == nil, imageRequestID == nil {
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            imageRequestID = PHCachingImageManager.shared.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { [weak self] image, info in
                guard let self, let image else {
                    return
                }
                let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
                guard !cancelled else {
                    return
                }
                Task { @MainActor in
                    self.image = image
                }
            }
        }

        if metadata == nil, metadataTask == nil, !metadataUnavailable {
            metadataTask = Task { [weak self] in
                guard let self else {
                    return
                }
                do {
                    metadata = try await PhotoVideoInspector.inspect(asset)
                } catch {
                    metadataUnavailable = true
                }
                metadataTask = nil
            }
        }
    }

    func cancelThumbnailRequest() {
        if let imageRequestID {
            PHCachingImageManager.shared.cancelImageRequest(imageRequestID)
            self.imageRequestID = nil
        }
    }
}

@MainActor
private extension PHCachingImageManager {
    static let shared = PHCachingImageManager()
}

@MainActor
enum PhotoVideoInspector {
    static func inspect(_ asset: PHAsset) async throws -> PhotoVideoMetadata {
        let avAsset = try await requestAVAsset(for: asset, networkAccessAllowed: false)
        let tracks = try await avAsset.load(.tracks).filter { $0.mediaType == .video }
        guard let firstTrack = tracks.first else {
            throw PhotoVideoImportError.videoTrackUnavailable
        }

        var totalBitRate = 0.0
        for track in tracks {
            totalBitRate += Double(try await track.load(.estimatedDataRate))
        }

        let formatDescriptions = try await firstTrack.load(.formatDescriptions)
        let codec = formatDescriptions.first.map {
            codecName(CMFormatDescriptionGetMediaSubType($0))
        }

        var fileSize: Int64?
        if let urlAsset = avAsset as? AVURLAsset {
            let values = try? urlAsset.url.resourceValues(
                forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]
            )
            if let exactSize = values?.fileSize ?? values?.totalFileAllocatedSize {
                fileSize = Int64(exactSize)
            }
        }

        let hasExactFileSize = fileSize != nil
        if fileSize == nil, totalBitRate > 0, asset.duration > 0 {
            fileSize = Int64(totalBitRate * asset.duration / 8)
        }

        return PhotoVideoMetadata(
            fileSize: fileSize,
            isFileSizeEstimated: !hasExactFileSize && fileSize != nil,
            bitRate: totalBitRate > 0 ? totalBitRate : nil,
            codec: codec
        )
    }

    static func requestAVAsset(
        for asset: PHAsset,
        networkAccessAllowed: Bool,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> AVAsset {
        let box = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<PhotoVideoAssetBox, Error>) in
            let options = PHVideoRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.version = .current
            options.isNetworkAccessAllowed = networkAccessAllowed
            options.progressHandler = { value, _, _, _ in
                progress?(value)
            }
            PHImageManager.default().requestAVAsset(
                forVideo: asset,
                options: options
            ) { avAsset, _, info in
                if let avAsset {
                    continuation.resume(
                        returning: PhotoVideoAssetBox(avAsset)
                    )
                    return
                }
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(
                    throwing: networkAccessAllowed
                        ? PhotoVideoImportError.videoDataUnavailable
                        : PhotoVideoImportError.metadataUnavailable
                )
            }
        }
        return box.asset
    }

    nonisolated static func codecName(_ codecType: FourCharCode) -> String {
        switch codecType {
        case kCMVideoCodecType_HEVC:
            "HEVC"
        case kCMVideoCodecType_H264:
            "H.264"
        case kCMVideoCodecType_AppleProRes422:
            "ProRes"
        default:
            mediaFourCC(codecType).uppercased()
        }
    }
}

private final class PhotoVideoAssetBox: @unchecked Sendable {
    let asset: AVAsset

    init(_ asset: AVAsset) {
        self.asset = asset
    }
}

@MainActor
private enum PhotoVideoSourceProvider {
    static func loadCurrentVersion(
        of asset: PHAsset,
        sequence: Int,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> TranscodeSource {
        let avAsset = try await PhotoVideoInspector.requestAVAsset(
            for: asset,
            networkAccessAllowed: true,
            progress: progress
        )
        try Task.checkCancellation()

        let resource = preferredVideoResource(for: asset)
        let originalName = resource?.originalFilename ?? "视频-\(sequence + 1).mov"
        let safeName = sanitizedFileName(originalName)
        let fileSize = await fileSize(of: avAsset)
        progress(1)
        return TranscodeSource(
            id: asset.localIdentifier,
            asset: avAsset,
            fileName: safeName,
            fileSize: fileSize,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate
        )
    }

    private static func preferredVideoResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first { $0.type == .video }
            ?? resources.first { $0.type == .fullSizeVideo }
            ?? resources.first { $0.type == .pairedVideo }
    }

    private static func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let components = name.components(separatedBy: invalid)
        let value = components.filter { !$0.isEmpty }.joined(separator: "_")
        return value.isEmpty ? "视频.mov" : value
    }

    private static func fileSize(of asset: AVAsset) async -> Int64? {
        if let url = (asset as? AVURLAsset)?.url,
           let values = try? url.resourceValues(
               forKeys: [.fileSizeKey, .totalFileAllocatedSizeKey]
           ),
           let exactSize = values.fileSize ?? values.totalFileAllocatedSize
        {
            return Int64(exactSize)
        }

        guard let duration = try? await asset.load(.duration),
              duration.isNumeric,
              let tracks = try? await asset.load(.tracks)
        else {
            return nil
        }
        var totalBitRate = 0.0
        for track in tracks {
            totalBitRate += Double((try? await track.load(.estimatedDataRate)) ?? 0)
        }
        let seconds = CMTimeGetSeconds(duration)
        guard totalBitRate > 0, seconds.isFinite, seconds > 0 else {
            return nil
        }
        return Int64(totalBitRate * seconds / 8)
    }
}

enum PhotoVideoImportError: LocalizedError, Sendable {
    case selectionUnavailable
    case metadataUnavailable
    case videoDataUnavailable
    case videoTrackUnavailable
    case cloudTestSeedUnavailable
    case cloudTestSeedFailed

    var errorDescription: String? {
        switch self {
        case .selectionUnavailable:
            "所选视频已不在当前照片库权限范围内，请重新选择。"
        case .metadataUnavailable:
            "视频位于 iCloud，点选后下载时会读取完整信息。"
        case .videoDataUnavailable:
            "无法从照片库读取视频，请检查 iCloud 网络和照片权限。"
        case .videoTrackUnavailable:
            "所选项目不包含可读取的视频轨道。"
        case .cloudTestSeedUnavailable:
            "云端真机测试素材没有进入 App Bundle。"
        case .cloudTestSeedFailed:
            "无法把云端真机测试素材写入系统照片库。"
        }
    }
}
