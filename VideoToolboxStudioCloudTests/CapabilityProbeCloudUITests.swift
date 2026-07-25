import Foundation
import UIKit
import XCTest

final class CapabilityProbeCloudUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func test只读硬件探针在云端真机通过() throws {
        let app = XCUIApplication()
        app.launch()

        let runButton = app.buttons["capability-run-button"]
        XCTAssertTrue(
            runButton.waitForExistence(timeout: 30),
            "未找到只读探针按钮，App 可能没有成功启动。"
        )
        runButton.tap()

        let summary = app.staticTexts["capability-summary"]
        XCTAssertTrue(
            summary.waitForExistence(timeout: 120),
            "VideoToolbox 只读探针未在 120 秒内完成。"
        )

        let report: [String: String] = [
            "schema_version": "1.0",
            "hardware_sessions": summary.label,
            "expected_hardware_sessions": "3/3",
            "runner_device_model": UIDevice.current.model,
            "runner_system_name": UIDevice.current.systemName,
            "runner_system_version": UIDevice.current.systemVersion,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        let reportData = try JSONSerialization.data(
            withJSONObject: report,
            options: [.sortedKeys]
        )
        print("VT_CLOUD_REPORT_BASE64=\(reportData.base64EncodedString())")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "VideoToolbox 只读能力探针结果"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertEqual(
            summary.label,
            "3/3",
            "严格硬件会话未全部通过；请检查 BrowserStack 真机日志。"
        )
    }
}
