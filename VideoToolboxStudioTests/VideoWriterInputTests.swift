import AVFoundation
import CoreMedia
import XCTest

final class VideoWriterInputTests: XCTestCase {
    func testCompressedVideoInputAcceptsTrackConfigurationWithFormatHint() throws {
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
        input.expectsMediaDataInRealTime = false
        input.transform = .identity
        input.mediaTimeScale = 600

        XCTAssertFalse(input.expectsMediaDataInRealTime)
        XCTAssertEqual(input.mediaTimeScale, 600)
    }
}
