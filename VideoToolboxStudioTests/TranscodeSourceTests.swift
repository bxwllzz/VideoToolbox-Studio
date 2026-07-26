import AVFoundation
import XCTest
@testable import VideoToolboxStudio

final class TranscodeSourceTests: XCTestCase {
    func testLocalFileSourceRetainsFileIdentityWithoutCopying() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let sourceURL = directory.appendingPathComponent("输入视频.mov")
        let bytes = Data(repeating: 0x5A, count: 32)
        try bytes.write(to: sourceURL)

        let source = TranscodeSource.localFile(sourceURL)

        XCTAssertEqual(source.id, sourceURL.standardizedFileURL.absoluteString)
        XCTAssertEqual(source.fileName, "输入视频.mov")
        XCTAssertEqual(source.fileSize, Int64(bytes.count))
        XCTAssertEqual(source.securityScopedURL, sourceURL)
        XCTAssertNil(source.photoLibraryAssetIdentifier)
        XCTAssertEqual((source.asset as? AVURLAsset)?.url, sourceURL)
    }

    func testPhotoAssetSourceDoesNotRequireLocalURL() {
        let asset = AVMutableComposition()
        let source = TranscodeSource(
            id: "photo-library-id",
            asset: asset,
            fileName: "相册视频.mov",
            fileSize: 1024,
            creationDate: nil,
            modificationDate: nil,
            photoLibraryAssetIdentifier: "photo-library-id"
        )

        XCTAssertEqual(source.id, "photo-library-id")
        XCTAssertEqual(source.fileName, "相册视频.mov")
        XCTAssertEqual(source.fileSize, 1024)
        XCTAssertNil(source.securityScopedURL)
        XCTAssertEqual(
            source.photoLibraryAssetIdentifier,
            "photo-library-id"
        )
        XCTAssertTrue(source.asset === asset)
    }
}
