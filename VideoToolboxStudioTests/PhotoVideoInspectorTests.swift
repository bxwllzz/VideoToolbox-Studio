import CoreMedia
import XCTest
@testable import VideoToolboxStudio

final class PhotoVideoInspectorTests: XCTestCase {
    func test常见视频编码显示为用户可读名称() {
        XCTAssertEqual(
            PhotoVideoInspector.codecName(kCMVideoCodecType_HEVC),
            "HEVC"
        )
        XCTAssertEqual(
            PhotoVideoInspector.codecName(kCMVideoCodecType_H264),
            "H.264"
        )
    }

    func test未知编码保留FourCC信息() {
        XCTAssertEqual(
            PhotoVideoInspector.codecName(0x76703039),
            "VP09"
        )
    }
}
