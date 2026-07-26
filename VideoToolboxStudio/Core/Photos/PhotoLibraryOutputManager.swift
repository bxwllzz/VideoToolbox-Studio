import Foundation
import Photos

enum PhotoLibraryOutputError: LocalizedError {
    case outputMissing
    case saveFailed
    case savedAssetUnavailable
    case sourceAssetUnavailable
    case deleteFailed

    var errorDescription: String? {
        switch self {
        case .outputMissing:
            "压缩文件已不存在，无法保存到相册。"
        case .saveFailed:
            "视频转换成功，但系统照片库没有完成保存。"
        case .savedAssetUnavailable:
            "系统照片库已返回成功，但没有给出新视频标识。"
        case .sourceAssetUnavailable:
            "原视频已不在当前照片库权限范围内。"
        case .deleteFailed:
            "系统照片库没有删除原视频。"
        }
    }
}

enum PhotoLibraryOutputManager {
    nonisolated static func saveVideo(
        at outputURL: URL,
        creationDate: Date?
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw PhotoLibraryOutputError.outputMissing
        }

        let identifierBox = PhotoLibraryIdentifierBox()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                guard let request =
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(
                        atFileURL: outputURL
                    )
                else {
                    return
                }
                request.creationDate = creationDate
                identifierBox.value = request.placeholderForCreatedAsset?
                    .localIdentifier
            }, completionHandler: { success, error in
                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(
                        throwing: error ?? PhotoLibraryOutputError.saveFailed
                    )
                }
            })
        }

        guard let identifier = identifierBox.value else {
            throw PhotoLibraryOutputError.savedAssetUnavailable
        }
        return identifier
    }

    nonisolated static func deleteAsset(
        localIdentifier: String
    ) async throws {
        let result = PHAsset.fetchAssets(
            withLocalIdentifiers: [localIdentifier],
            options: nil
        )
        guard let asset = result.firstObject else {
            throw PhotoLibraryOutputError.sourceAssetUnavailable
        }
        let assetBox = PhotoLibraryAssetBox(asset)

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.deleteAssets(
                    [assetBox.asset] as NSArray
                )
            }, completionHandler: { success, error in
                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(
                        throwing: error ?? PhotoLibraryOutputError.deleteFailed
                    )
                }
            })
        }
    }
}

private final class PhotoLibraryIdentifierBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    var value: String? {
        get {
            lock.withLock { storedValue }
        }
        set {
            lock.withLock { storedValue = newValue }
        }
    }
}

private final class PhotoLibraryAssetBox: @unchecked Sendable {
    let asset: PHAsset

    init(_ asset: PHAsset) {
        self.asset = asset
    }
}
