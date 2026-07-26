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
        app.launchArguments.append("--internal-testing")
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
            "严格硬件会话未全部通过；请检查 AWS Device Farm 真机日志。"
        )
    }

    @MainActor
    func test持续硬编在云端真机达到目标证据() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--internal-testing")
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
        var lastSummaryLabel = ""

        for runNumber in 1...3 {
            let rerunButton = app.buttons["sustained-rerun-button"]
            XCTAssertTrue(
                waitForSustainedCompletion(
                    rerunButton: rerunButton,
                    in: app,
                    timeout: 90
                ),
                "第 \(runNumber) 轮多帧持续硬编未在 90 秒内完成。"
            )
            makeHittableFromBelow(summary, in: app)
            XCTAssertTrue(summary.waitForExistence(timeout: 30))
            lastSummaryLabel = summary.label

            let result = try sustainedResult(in: app, runNumber: runNumber)
            runs.append(result)

            if runNumber < 3 {
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
            "summary": normalizedSummary(lastSummaryLabel, expected: "3/3"),
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
        app.launchArguments.append("--internal-testing")
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
        let disappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: summary
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [disappeared], timeout: 30),
            .completed,
            "取消后的重新运行没有进入编码状态。"
        )
        XCTAssertTrue(
            waitForSustainedCompletion(
                rerunButton: rerunButton,
                in: app,
                timeout: 90
            ),
            "取消后的新编码会话未在 90 秒内完成。"
        )
        makeHittableFromBelow(summary, in: app)
        XCTAssertTrue(summary.waitForExistence(timeout: 30))
        XCTAssertTrue(
            summary.label.contains("3/3"),
            "取消后重新创建的编码会话未全部达标。"
        )
    }

    @MainActor
    func testCloudTranscodePreservesMediaContract() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--cloud-testing")
        app.launchArguments.append("--seed-photo-library")
        app.launch()

        allowPhotoLibraryAccess(in: app)

        let seedError = app.staticTexts["photo-library-seed-error"]
        if seedError.waitForExistence(timeout: 2) {
            XCTFail("系统照片库测试素材写入失败：\(seedError.label)")
            return
        }

        let video = app.buttons.matching(
            identifier: "video-library-item"
        ).firstMatch
        XCTAssertTrue(
            waitForExistenceWhileAppRuns(
                video,
                in: app,
                timeout: 60
            ),
            "内置视频没有写入系统照片库，或相册主界面没有读取到 PHAsset；"
                + "App 状态：\(app.state.rawValue)。"
        )
        let metadataReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label CONTAINS %@ AND label CONTAINS %@ "
                    + "AND label CONTAINS %@ AND label CONTAINS %@",
                "KB",
                "320乘180",
                "H.264",
                "kb/s"
            ),
            object: video
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [metadataReady], timeout: 30),
            .completed,
            "相册缩略图没有完整显示大小、分辨率、编码类型与码率：\(video.label)"
        )
        let sourceLabel = video.label

        let selectButton = app.buttons["选择"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 10))
        selectButton.tap()
        video.tap()
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "selected == true"),
            object: video
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [selected], timeout: 10),
            .completed,
            "进入多选后，缩略图没有暴露已选择状态。"
        )
        XCTAssertTrue(
            app.navigationBars["已选择 1 项"].waitForExistence(timeout: 10),
            "多选标题没有更新选择数量。"
        )

        let selectionScreenshot = XCTAttachment(screenshot: app.screenshot())
        selectionScreenshot.name = "相册缩略图参数与多选标记"
        selectionScreenshot.lifetime = .keepAlways
        add(selectionScreenshot)

        let nextButton = app.buttons["下一步"]
        XCTAssertTrue(nextButton.waitForExistence(timeout: 10))
        nextButton.tap()

        let capabilityStatus = app.descendants(
            matching: .any
        )["native-capability-status"]
        XCTAssertTrue(
            capabilityStatus.waitForExistence(timeout: 60),
            "压缩设置页没有完成本机编码器支持字典检测。"
        )
        let nativeCapabilityLabel = capabilityStatus.label

        let averageBitRateProperty = app.textFields[
            "native-property-AverageBitRate"
        ]
        XCTAssertTrue(
            averageBitRateProperty.waitForExistence(timeout: 30),
            "默认互斥码率字段没有显示 AverageBitRate。"
        )
        let nativeAverageBitRateLabel =
            averageBitRateProperty.value as? String
            ?? averageBitRateProperty.label
        XCTAssertFalse(
            app.descendants(
                matching: .any
            )["native-property-ConstantBitRate"].exists,
            "AverageBitRate 生效时不应同时显示 ConstantBitRate 输入行。"
        )
        let readOnlyProperty = app.descendants(
            matching: .any
        )["native-property-MaxFrameDelayCount"]
        makeHittable(readOnlyProperty, in: app)
        XCTAssertTrue(
            readOnlyProperty.waitForExistence(timeout: 30),
            "没有显示本机只读或不支持的 MaxFrameDelayCount。"
        )
        XCTAssertFalse(
            app.textFields["native-property-MaxFrameDelayCount"].exists
                || app.switches["native-property-MaxFrameDelayCount"].exists
                || app.buttons["native-property-MaxFrameDelayCount"].exists,
            "本机不可写的 MaxFrameDelayCount 被暴露成了可编辑控件。"
        )
        let nativeReadOnlyPropertyLabel = readOnlyProperty.label
        XCTAssertTrue(
            nativeReadOnlyPropertyLabel.contains("本机只读")
                && !nativeReadOnlyPropertyLabel.contains("未返回值"),
            "本机只读字段没有同时提供当前值或查询状态："
                + nativeReadOnlyPropertyLabel
        )

        let runButton = app.buttons["transcode-start"]
        makeHittable(runButton, in: app)
        XCTAssertTrue(
            runButton.waitForExistence(timeout: 60),
            "从系统照片库取得 AVAsset 后没有进入压缩设置页。"
        )
        runButton.tap()

        let runtimeDiagnostics = app.descendants(
            matching: .any
        ).matching(
            identifier: "transcode-runtime-diagnostics"
        ).firstMatch
        makeHittableFromBelow(runtimeDiagnostics, in: app)
        XCTAssertTrue(
            waitForExistenceWhileAppRuns(
                runtimeDiagnostics,
                in: app,
                timeout: 30
            ),
            "编码过程没有显示只读状态与诊断数据。"
        )
        let runtimeDiagnosticsLabel = runtimeDiagnostics.label

        let summary = app.staticTexts["cloud-transcode-summary"]
        let error = app.staticTexts["cloud-transcode-error"]
        let progress = app.staticTexts["cloud-transcode-progress"]
        // SwiftUI Form 会虚拟化屏幕外的行；转码完成后内容高度变化，
        // 云端结果区可能移出无障碍树。先滚到底部，让状态与结果行实例化。
        makeHittable(summary, in: app)
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, !summary.exists, !error.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        if error.exists {
            XCTFail("真实视频转码失败：\(error.label)")
            return
        }
        XCTAssertTrue(
            summary.exists,
            "真实视频转码没有在 90 秒内完成；"
                + (progress.exists ? progress.label : "未回收到进度")
        )
        let metrics = app.staticTexts["cloud-transcode-metrics"]
        makeHittable(metrics, in: app)
        XCTAssertTrue(metrics.waitForExistence(timeout: 30))
        let multiPass = app.staticTexts["cloud-transcode-multipass"]
        makeHittable(multiPass, in: app)
        XCTAssertTrue(
            multiPass.waitForExistence(timeout: 30),
            "没有回收到 MultiPassStorage 实际执行或回退证据。"
        )
        XCTAssertTrue(
            summary.label.contains("1/1")
                && summary.label.contains("保真核验通过"),
            "真实转码或输出复核没有通过：\(summary.label)"
        )
        let hasNonPositiveWriterStart =
            metrics.label.contains("写入起点 -")
                || metrics.label.contains("写入起点 0.")
        XCTAssertTrue(
            metrics.label.contains("300 帧")
                && metrics.label.contains("遍")
                && hasNonPositiveWriterStart,
            "10 秒 30 fps 素材没有完整输出 300 帧、编码遍次或不晚于"
                + "视频起点的写入会话证据：\(metrics.label)"
        )
        let summaryLabel = summary.label
        let metricsLabel = metrics.label
        let multiPassLabel = multiPass.label
        let photoSaveSuccess = app.staticTexts["photo-save-success"]
        makeHittable(photoSaveSuccess, in: app)
        XCTAssertTrue(
            photoSaveSuccess.waitForExistence(timeout: 30),
            "转换完成后没有默认保存到系统照片库。"
        )
        let finalDiagnostics = app.staticTexts.matching(
            identifier: "transcode-runtime-diagnostics"
        ).matching(
            NSPredicate(
                format: "label CONTAINS %@",
                "输出容器写入完成"
            )
        ).firstMatch
        makeHittable(finalDiagnostics, in: app)
        XCTAssertTrue(
            finalDiagnostics.waitForExistence(timeout: 30),
            "转码结束后没有保留最终写入阶段的只读状态与诊断数据。"
        )
        let finalDiagnosticsLabel = finalDiagnostics.label

        let settingsNavigationBar = app.navigationBars["压缩设置"]
        let backButton = settingsNavigationBar.buttons.firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 10))
        backButton.tap()
        let preparationOverlay = app.otherElements["video-preparation-overlay"]
        XCTAssertFalse(
            preparationOverlay.waitForExistence(timeout: 3),
            "返回视频首页后，准备进度遮罩仍然停留。"
        )

        let report: [String: String] = [
            "schema_version": "1.0",
            "source": "system-photo-library",
            "source_metadata": sourceLabel,
            "native_capability": nativeCapabilityLabel,
            "native_average_bit_rate": nativeAverageBitRateLabel,
            "native_read_only_property": nativeReadOnlyPropertyLabel,
            "runtime_diagnostics_during_encoding": runtimeDiagnosticsLabel,
            "runtime_diagnostics_after_encoding": finalDiagnosticsLabel,
            "summary": summaryLabel,
            "metrics": metricsLabel,
            "multi_pass": multiPassLabel,
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
    private func allowPhotoLibraryAccess(in app: XCUIApplication) {
        let springboard = XCUIApplication(
            bundleIdentifier: "com.apple.springboard"
        )
        let labels = [
            "Allow Full Access",
            "Allow Access to All Photos",
            "允许完全访问",
            "允许访问所有照片",
        ]
        for application in [app, springboard] {
            for label in labels {
                let button = application.buttons[label]
                if button.waitForExistence(timeout: 3) {
                    button.tap()
                    return
                }
            }
        }
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
            h264Metrics,
            hevc1080Evidence,
            hevc1080Metrics,
            hevc4KEvidence,
            hevc4KMetrics,
        ] {
            makeHittable(element, in: app)
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

    @MainActor
    private func makeHittableFromBelow(
        _ element: XCUIElement,
        in app: XCUIApplication
    ) {
        for _ in 0..<8 where !element.isHittable {
            app.swipeDown()
        }
    }

    @MainActor
    private func waitForSustainedCompletion(
        rerunButton: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            makeHittable(rerunButton, in: app)
            if rerunButton.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        return false
    }

    @MainActor
    private func waitForExistenceWhileAppRuns(
        _ element: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists {
                return true
            }
            if app.state == .notRunning {
                return false
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        return false
    }

    private func normalizedSummary(_ label: String, expected: String) -> String {
        label.contains(expected) ? expected : label
    }
}
