import AVFoundation
import CoreMedia
import XCTest

final class VideoWriterInputTests: XCTestCase {
    func testCompressedVideoInputAcceptsTrackConfigurationWithFormatHint() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        var formatHint: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_HEVC,
            width: 320,
            height: 180,
            extensions: nil,
            formatDescriptionOut: &formatHint
        )
        XCTAssertEqual(status, noErr)
        let unwrappedHint = try XCTUnwrap(formatHint)

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: nil,
            sourceFormatHint: unwrappedHint
        )
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)

        input.transform = .identity
        input.metadata = []

        XCTAssertFalse(input.expectsMediaDataInRealTime)
        XCTAssertEqual(input.transform, .identity)
    }
}
