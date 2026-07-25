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

        let summaryLabel = summary.label
        let expectedSummary = "3/3"
        let hardwareSessions = summaryLabel.contains(expectedSummary)
            ? expectedSummary
            : summaryLabel

        let report: [String: String] = [
            "schema_version": "1.0",
            "hardware_sessions": hardwareSessions,
            "expected_hardware_sessions": expectedSummary,
            "runner_device_model": UIDevice.current.model,
            "runner_system_name": UIDevice.current.systemName,
            "runner_system_version": UIDevice.current.systemVersion,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        let reportData = try JSONSerialization.data(
            withJSONObject: report,
            options: [.sortedKeys]
        )
        print("VT_CLOUD_CAPABILITY_REPORT_BASE64=\(reportData.base64EncodedString())")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "VideoToolbox 只读能力探针结果"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertTrue(
            summaryLabel.contains(expectedSummary),
            "严格硬件会话未全部通过；请检查 BrowserStack 真机日志。"
        )
    }

    @MainActor
    func test持续硬编在云端真机达到目标证据() throws {
        let app = XCUIApplication()
        app.launch()

        let runButton = app.buttons["sustained-run-button"]
        XCTAssertTrue(
            runButton.waitForExistence(timeout: 30),
            "未找到持续硬编按钮，App 可能没有成功启动。"
        )
        makeHittable(runButton, in: app)
        runButton.tap()

        let summary = app.staticTexts["sustained-summary"]
        XCTAssertTrue(
            summary.waitForExistence(timeout: 240),
            "多帧持续硬编未在 240 秒内完成。"
        )

        let h264Evidence = app.staticTexts["sustained-h264-1080p-evidence"]
        let hevc1080Evidence = app.staticTexts["sustained-hevc-1080p-evidence"]
        let hevc4KEvidence = app.staticTexts["sustained-hevc-4k-evidence"]
        XCTAssertTrue(h264Evidence.waitForExistence(timeout: 30))
        XCTAssertTrue(hevc1080Evidence.waitForExistence(timeout: 30))
        XCTAssertTrue(hevc4KEvidence.waitForExistence(timeout: 30))

        let report: [String: String] = [
            "schema_version": "1.0",
            "summary": normalizedSummary(summary.label, expected: "3/3"),
            "h264_1080p30_evidence": h264Evidence.label,
            "hevc_1080p30_evidence": hevc1080Evidence.label,
            "hevc_4k30_evidence": hevc4KEvidence.label,
            "runner_device_model": UIDevice.current.model,
            "runner_system_name": UIDevice.current.systemName,
            "runner_system_version": UIDevice.current.systemVersion,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        let reportData = try JSONSerialization.data(
            withJSONObject: report,
            options: [.sortedKeys]
        )
        print("VT_CLOUD_SUSTAINED_REPORT_BASE64=\(reportData.base64EncodedString())")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "VideoToolbox 持续硬编结果"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        XCTAssertTrue(
            h264Evidence.label.contains("E6"),
            "H.264 1080p30 未达到 E6。"
        )
        XCTAssertTrue(
            hevc1080Evidence.label.contains("E6"),
            "HEVC 1080p30 未达到 E6。"
        )
        XCTAssertTrue(
            hevc4KEvidence.label.contains("E5"),
            "HEVC 4K30 未达到 E5。"
        )
    }

    @MainActor
    private func makeHittable(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable {
            app.swipeUp()
        }
    }

    private func normalizedSummary(_ label: String, expected: String) -> String {
        label.contains(expected) ? expected : label
    }
}
