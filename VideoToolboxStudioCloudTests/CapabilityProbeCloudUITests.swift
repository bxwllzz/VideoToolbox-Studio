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
        var runs: [[String: String]] = []

        for runNumber in 1...3 {
            XCTAssertTrue(
                summary.waitForExistence(timeout: 240),
                "第 \(runNumber) 轮多帧持续硬编未在 240 秒内完成。"
            )

            let result = try sustainedResult(in: app, runNumber: runNumber)
            runs.append(result)

            if runNumber < 3 {
                let rerunButton = app.buttons["sustained-rerun-button"]
                makeHittable(rerunButton, in: app)
                XCTAssertTrue(rerunButton.waitForExistence(timeout: 30))
                rerunButton.tap()

                let disappeared = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == false"),
                    object: summary
                )
                XCTAssertEqual(
                    XCTWaiter.wait(for: [disappeared], timeout: 30),
                    .completed,
                    "第 \(runNumber + 1) 轮没有进入运行状态。"
                )
            }
        }

        let report: [String: Any] = [
            "schema_version": "1.0",
            "summary": normalizedSummary(summary.label, expected: "3/3"),
            "run_count": runs.count,
            "runs": runs,
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
    }

    @MainActor
    func test取消后可重新创建硬编会话() throws {
        let app = XCUIApplication()
        app.launch()

        let runButton = app.buttons["sustained-run-button"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 30))
        makeHittable(runButton, in: app)
        runButton.tap()

        let cancelButton = app.buttons["sustained-cancel-button"]
        XCTAssertTrue(
            cancelButton.waitForExistence(timeout: 30),
            "持续硬编运行时没有出现取消按钮。"
        )
        cancelButton.tap()

        let cancelledStatus = app.descendants(matching: .any)["sustained-cancelled-status"]
        XCTAssertTrue(
            cancelledStatus.waitForExistence(timeout: 120),
            "取消后没有完成编码会话收尾。"
        )

        let rerunButton = app.buttons["sustained-rerun-button"]
        makeHittable(rerunButton, in: app)
        XCTAssertTrue(rerunButton.waitForExistence(timeout: 30))
        rerunButton.tap()

        let summary = app.staticTexts["sustained-summary"]
        XCTAssertTrue(
            summary.waitForExistence(timeout: 240),
            "取消后的新编码会话未能完成。"
        )
        XCTAssertTrue(
            summary.label.contains("3/3"),
            "取消后重新创建的编码会话未全部达标。"
        )
    }

    @MainActor
    func test真实视频转码与保真复核通过() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--cloud-testing")
        app.launch()

        let openTranscode = app.buttons["open-transcode"]
        XCTAssertTrue(
            openTranscode.waitForExistence(timeout: 30),
            "未找到视频转换入口。"
        )
        openTranscode.tap()

        let runButton = app.buttons["cloud-transcode-run"]
        makeHittable(runButton, in: app)
        XCTAssertTrue(
            runButton.waitForExistence(timeout: 30),
            "未找到云端真实转码入口。"
        )
        runButton.tap()

        let summary = app.staticTexts["cloud-transcode-summary"]
        let error = app.staticTexts["cloud-transcode-error"]
        let progress = app.staticTexts["cloud-transcode-progress"]
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline, !summary.exists, !error.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        if error.exists {
            XCTFail("真实视频转码失败：\(error.label)")
            return
        }
        XCTAssertTrue(
            summary.exists,
            "真实视频转码没有在 180 秒内完成；"
                + (progress.exists ? progress.label : "未回收到进度")
        )
        let metrics = app.staticTexts["cloud-transcode-metrics"]
        makeHittable(metrics, in: app)
        XCTAssertTrue(metrics.waitForExistence(timeout: 30))
        XCTAssertTrue(
            summary.label.contains("1/1")
                && summary.label.contains("保真核验通过"),
            "真实转码或输出复核没有通过：\(summary.label)"
        )
        XCTAssertTrue(
            metrics.label.contains("300 帧"),
            "10 秒 30 fps 素材没有完整输出 300 帧：\(metrics.label)"
        )

        let report: [String: String] = [
            "schema_version": "1.0",
            "summary": summary.label,
            "metrics": metrics.label,
            "runner_device_model": UIDevice.current.model,
            "runner_system_name": UIDevice.current.systemName,
            "runner_system_version": UIDevice.current.systemVersion,
            "generated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        let reportData = try JSONSerialization.data(
            withJSONObject: report,
            options: [.sortedKeys]
        )
        print("VT_CLOUD_TRANSCODE_REPORT_BASE64=\(reportData.base64EncodedString())")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "VideoToolbox 真实视频转码结果"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    @MainActor
    private func sustainedResult(
        in app: XCUIApplication,
        runNumber: Int
    ) throws -> [String: String] {
        let h264Evidence = app.staticTexts["sustained-h264-1080p-evidence"]
        let hevc1080Evidence = app.staticTexts["sustained-hevc-1080p-evidence"]
        let hevc4KEvidence = app.staticTexts["sustained-hevc-4k-evidence"]
        let h264Metrics = app.staticTexts["sustained-h264-1080p-metrics"]
        let hevc1080Metrics = app.staticTexts["sustained-hevc-1080p-metrics"]
        let hevc4KMetrics = app.staticTexts["sustained-hevc-4k-metrics"]

        for element in [
            h264Evidence,
            hevc1080Evidence,
            hevc4KEvidence,
            h264Metrics,
            hevc1080Metrics,
            hevc4KMetrics,
        ] {
            XCTAssertTrue(element.waitForExistence(timeout: 30))
        }

        XCTAssertTrue(
            h264Evidence.label.contains("E6"),
            "第 \(runNumber) 轮 H.264 1080p30 未达到 E6。"
        )
        XCTAssertTrue(
            hevc1080Evidence.label.contains("E6"),
            "第 \(runNumber) 轮 HEVC 1080p30 未达到 E6。"
        )
        XCTAssertTrue(
            hevc4KEvidence.label.contains("E5"),
            "第 \(runNumber) 轮 HEVC 4K30 未达到 E5。"
        )

        return [
            "run": String(runNumber),
            "h264_1080p30_evidence": h264Evidence.label,
            "h264_1080p30_metrics": h264Metrics.label,
            "hevc_1080p30_evidence": hevc1080Evidence.label,
            "hevc_1080p30_metrics": hevc1080Metrics.label,
            "hevc_4k30_evidence": hevc4KEvidence.label,
            "hevc_4k30_metrics": hevc4KMetrics.label,
        ]
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
