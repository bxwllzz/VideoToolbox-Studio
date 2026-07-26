import SwiftUI

struct TranscodeReportView: View {
    let result: TranscodeResult

    private var report: TranscodeReport {
        result.report
    }

    var body: some View {
        List {
            Section("结果摘要") {
                LabeledContent("原视频", value: formattedBytes(report.metrics.inputBytes))
                LabeledContent("压缩视频", value: formattedBytes(report.metrics.outputBytes))
                LabeledContent("体积变化", value: sizeChangeDescription)
                LabeledContent(
                    "硬件编码",
                    value: report.usesHardwareEncoder ? "已确认" : "未确认"
                )
                LabeledContent(
                    "保真核验",
                    value: failedChecks.isEmpty ? "全部通过" : "\(failedChecks.count) 项失败"
                )
            }

            Section("媒体对比") {
                mediaRows(title: "输入", asset: report.input)
                mediaRows(title: "输出", asset: report.output)
            }

            Section("编码设置") {
                LabeledContent(
                    "目标编码",
                    value: report.requestedSettings.targetCodec.title
                )
                LabeledContent(
                    "码率控制",
                    value: report.requestedSettings.rateControl.title
                )
                if let averageBitRate = report.resolvedSettings.averageBitRate {
                    LabeledContent(
                        "目标平均码率",
                        value: formattedBitRate(Double(averageBitRate))
                    )
                }
                if let quality = report.resolvedSettings.quality {
                    LabeledContent(
                        "质量因子",
                        value: String(format: "%.2f", quality)
                    )
                }
                if let limits = report.resolvedSettings.dataRateLimits,
                   limits.count >= 2
                {
                    LabeledContent(
                        "码率硬上限",
                        value: "\(formattedBitRate(limits[0] * 8)) / "
                            + String(format: "%.1f 秒", limits[1])
                    )
                }
                LabeledContent(
                    "配置档次",
                    value: report.resolvedSettings.profileLevel
                )
                LabeledContent(
                    "关键帧帧数上限",
                    value: report.resolvedSettings.maxKeyFrameInterval == 0
                        ? "关闭"
                        : "\(report.resolvedSettings.maxKeyFrameInterval) 帧"
                )
                LabeledContent(
                    "关键帧时间上限",
                    value: report.resolvedSettings.maxKeyFrameIntervalDuration == 0
                        ? "关闭"
                        : String(
                            format: "%.1f 秒",
                            report.resolvedSettings.maxKeyFrameIntervalDuration
                        )
                )
                LabeledContent(
                    "帧重排序",
                    value: report.resolvedSettings.allowFrameReordering ? "允许" : "禁止"
                )
                LabeledContent(
                    "实时编码",
                    value: report.resolvedSettings.realTime ? "开启" : "关闭"
                )
                LabeledContent(
                    "速度优先",
                    value: report.resolvedSettings.prioritizeEncodingSpeedOverQuality
                        ? "开启"
                        : "关闭"
                )
            }

            Section("性能") {
                LabeledContent(
                    "处理耗时",
                    value: String(format: "%.2f 秒", report.metrics.wallClockSeconds)
                )
                LabeledContent(
                    "处理速度",
                    value: String(
                        format: "%.1f 帧/秒",
                        report.metrics.processingFramesPerSecond
                    )
                )
                LabeledContent(
                    "编码帧",
                    value: "\(report.metrics.encodedVideoFrames)"
                )
                LabeledContent(
                    "丢帧",
                    value: "\(report.metrics.droppedVideoFrames)"
                )
                LabeledContent(
                    "直通非视频样本",
                    value: "\(report.metrics.copiedNonVideoSamples)"
                )
            }

            Section("保真核验") {
                ForEach(
                    Array(report.preservationChecks.enumerated()),
                    id: \.offset
                ) { _, check in
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            check.name,
                            systemImage: check.passed
                                ? "checkmark.circle.fill"
                                : "xmark.octagon.fill"
                        )
                        .foregroundStyle(check.passed ? .green : .red)
                        Text(check.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("高级") {
                DisclosureGroup("原始 JSON 报告") {
                    Text("用于自动化分析、问题复现和开发调试；日常查看以上渲染报告即可。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ShareLink(item: result.reportURL) {
                        Label("导出 JSON 文件", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle("压缩报告")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func mediaRows(
        title: String,
        asset: MediaAssetSummary
    ) -> some View {
        let video = asset.videoTracks.first
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            LabeledContent("文件大小", value: formattedBytes(asset.fileSize))
            LabeledContent(
                "视频编码",
                value: video.map {
                    PhotoVideoInspector.codecName($0.codecType)
                } ?? "未知"
            )
            LabeledContent(
                "分辨率",
                value: dimensions(video)
            )
            LabeledContent(
                "平均视频码率",
                value: formattedBitRate(video?.estimatedDataRate ?? 0)
            )
            LabeledContent(
                "帧率",
                value: String(format: "%.2f fps", video?.nominalFrameRate ?? 0)
            )
            LabeledContent(
                "时长",
                value: String(format: "%.2f 秒", asset.durationSeconds)
            )
        }
    }

    private var failedChecks: [PreservationCheck] {
        report.preservationChecks.filter { !$0.passed }
    }

    private var sizeChangeDescription: String {
        let ratio = report.metrics.outputToInputSizeRatio
        guard ratio.isFinite, ratio > 0 else {
            return "无法计算"
        }
        if abs(ratio - 1) < 0.005 {
            return "基本不变"
        }
        if ratio < 1 {
            return String(format: "缩小 %.1f%%", (1 - ratio) * 100)
        }
        return String(format: "增大 %.1f%%", (ratio - 1) * 100)
    }

    private func dimensions(_ video: MediaTrackSummary?) -> String {
        guard let width = video?.naturalWidth,
              let height = video?.naturalHeight
        else {
            return "未知"
        }
        return "\(Int(abs(width.rounded())))×\(Int(abs(height.rounded())))"
    }

    private func formattedBitRate(_ bitRate: Double) -> String {
        if bitRate >= 1_000_000 {
            return String(format: "%.2f Mb/s", bitRate / 1_000_000)
        }
        return String(format: "%.0f kb/s", bitRate / 1_000)
    }

    private func formattedBytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
