import SwiftUI

struct HomeView: View {
    @ObservedObject var installationState: InstallationState

    @StateObject private var capabilityStore = CapabilityProbeStore()
    @StateObject private var sustainedEncodingStore = SustainedEncodingStore()
    @State private var exportURL: URL?
    @State private var exportError: String?

    private var report: BuildReport {
        BuildReport.current(
            installationIdentifier: installationState.installationIdentifier,
            launchCount: installationState.launchCount
        )
    }

    var body: some View {
        NavigationStack {
            List {
                statusSection
                transcodeSection
                sustainedEncodingSection
                capabilitySection
                buildSection
                deviceSection
                persistenceSection
                exportSection
            }
            .navigationTitle("VideoToolbox Studio")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                prepareExport()
            }
        }
    }

    private var statusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label("专业视频编码", systemImage: "slider.horizontal.3")
                    .font(.title2.bold())
                    .foregroundStyle(.tint)

                Text(
                    "单个或批量转换视频；只改变视频编码与文件体积，其他媒体信息通过直通和输出复核尽量无损保留。"
                )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    PrivacyBadge(title: "纯本地", systemImage: "iphone")
                    PrivacyBadge(title: "无账号", systemImage: "person.crop.circle.badge.xmark")
                    PrivacyBadge(title: "无埋点", systemImage: "chart.bar.xaxis")
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var transcodeSection: some View {
        Section("视频转换") {
            NavigationLink {
                TranscodeView(buildReport: report)
            } label: {
                Label("单个与批量转换", systemImage: "film.stack")
            }
            .accessibilityIdentifier("open-transcode")

            Text("提供保真、均衡、紧凑模板，也可直接控制码率、质量、GOP、B 帧和速度优先级。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sustainedEncodingSection: some View {
        Section("持续硬编验证") {
            switch sustainedEncodingStore.phase {
            case .idle:
                Button {
                    sustainedEncodingStore.run(buildReport: report)
                } label: {
                    Label("运行 2 秒持续编码", systemImage: "film.stack")
                }
                .accessibilityIdentifier("sustained-run-button")

                Text("依次编码 H.264 1080p30、HEVC 1080p30 和 HEVC 4K30，共生成 180 帧纯本地合成画面。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .running:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在生成并编码合成帧…")
                }

                Button(role: .destructive) {
                    sustainedEncodingStore.cancel()
                } label: {
                    Label("取消测试", systemImage: "stop.fill")
                }
                .accessibilityIdentifier("sustained-cancel-button")
            case .completed, .cancelled:
                if let encodingReport = sustainedEncodingStore.report {
                    ReportRow(
                        title: "验收目标通过",
                        value: "\(encodingReport.passedConfigurationCount)/\(encodingReport.configurations.count)",
                        accessibilityIdentifier: "sustained-summary"
                    )

                    ForEach(encodingReport.configurations) { result in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(result.configuration.label)
                                Spacer()
                                Image(systemName: result.meetsAcceptanceTarget
                                    ? "checkmark.circle.fill"
                                    : "xmark.circle.fill")
                                    .foregroundStyle(result.meetsAcceptanceTarget ? .green : .red)
                            }
                            Text(result.evidenceSummary.isEmpty ? "无有效证据" : result.evidenceSummary)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier(
                                    sustainedEvidenceIdentifier(for: result.configuration.label)
                                )
                            Text(
                                "\(result.metrics.outputSampleBuffers)/\(result.metrics.requestedFrames) 帧 · "
                                    + String(format: "%.1f fps", result.metrics.throughputFramesPerSecond)
                                    + " · \(formattedBytes(result.metrics.totalEncodedBytes))"
                            )
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier(
                                    sustainedMetricsIdentifier(for: result.configuration.label)
                                )
                        }
                    }
                }

                if sustainedEncodingStore.phase == .cancelled {
                    Label("测试已取消，已安全收尾当前编码会话。", systemImage: "stop.circle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("sustained-cancelled-status")
                }

                if let encodingURL = sustainedEncodingStore.exportURL {
                    ShareLink(item: encodingURL) {
                        Label("导出 sustained-encoding-report.json", systemImage: "square.and.arrow.up")
                    }
                }

                Button {
                    sustainedEncodingStore.run(buildReport: report)
                } label: {
                    Label("重新运行", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("sustained-rerun-button")
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Button("重试") {
                    sustainedEncodingStore.run(buildReport: report)
                }
            }
        }
    }

    @ViewBuilder
    private var capabilitySection: some View {
        Section("VideoToolbox 能力") {
            switch capabilityStore.phase {
            case .idle:
                Button {
                    capabilityStore.run(buildReport: report)
                } label: {
                    Label("运行只读探针", systemImage: "play.fill")
                }
                .accessibilityIdentifier("capability-run-button")

                Text("探针不会读取照片或写入编码参数，通常数秒内完成。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            case .running:
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在查询编码器和硬件会话…")
                }
            case .completed:
                if let capabilityReport = capabilityStore.report {
                    ReportRow(title: "枚举到编码器", value: "\(capabilityReport.encoders.count)")
                    ReportRow(
                        title: "硬件会话通过",
                        value: "\(capabilityReport.successfulHardwareSessionCount)/\(capabilityReport.configurationProbes.count)",
                        accessibilityIdentifier: "capability-summary"
                    )

                    ForEach(capabilityReport.configurationProbes) { probe in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(probe.configuration.label)
                                Spacer()
                                Image(systemName: probe.usesHardwareEncoder == true
                                    ? "checkmark.circle.fill"
                                    : "xmark.circle.fill")
                                    .foregroundStyle(probe.usesHardwareEncoder == true ? .green : .red)
                            }
                            Text(probe.evidenceSummary.isEmpty ? "无有效证据" : probe.evidenceSummary)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let capabilityURL = capabilityStore.exportURL {
                    ShareLink(item: capabilityURL) {
                        Label("导出 capability-report.json", systemImage: "square.and.arrow.up")
                    }
                }

                Button {
                    capabilityStore.run(buildReport: report)
                } label: {
                    Label("重新运行", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("capability-rerun-button")
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Button("重试") {
                    capabilityStore.run(buildReport: report)
                }
            }
        }
    }

    private var buildSection: some View {
        Section("构建身份") {
            ReportRow(title: "版本", value: "\(report.appVersion) (\(report.buildNumber))")
            ReportRow(
                title: "Commit",
                value: shortCommit(report.commitSHA),
                monospaced: true,
                accessibilityIdentifier: "build-commit"
            )
            ReportRow(title: "构建时间", value: report.builtAt, monospaced: true)
            ReportRow(title: "运行编号", value: report.buildRunID, monospaced: true)
        }
    }

    private var deviceSection: some View {
        Section("目标设备") {
            ReportRow(
                title: "设备标识",
                value: report.deviceIdentifier,
                monospaced: true,
                accessibilityIdentifier: "device-identifier"
            )
            ReportRow(title: "设备类型", value: report.deviceModel)
            ReportRow(
                title: "系统",
                value: "\(report.systemName) \(report.systemVersion)",
                accessibilityIdentifier: "device-system"
            )
        }
    }

    private var persistenceSection: some View {
        Section("覆盖更新验证") {
            ReportRow(
                title: "安装标识",
                value: String(report.installationIdentifier.prefix(8)),
                monospaced: true
            )
            ReportRow(title: "启动次数", value: "\(report.launchCount)")
            Text("覆盖安装后，安装标识应保持不变，启动次数应继续增加。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var exportSection: some View {
        Section("回传验证") {
            if let exportURL {
                ShareLink(item: exportURL) {
                    Label("导出 build-info.json", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Button(action: prepareExport) {
                    Label("重新生成构建报告", systemImage: "arrow.clockwise")
                }
            }

            if let exportError {
                Text(exportError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            } else {
                Text("报告只包含构建、设备、系统与覆盖更新验证信息，不包含 Apple Account 或媒体内容。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @MainActor
    private func prepareExport() {
        do {
            exportURL = try BuildReportExporter.write(report)
            exportError = nil
        } catch {
            exportURL = nil
            exportError = error.localizedDescription
        }
    }

    private func shortCommit(_ commit: String) -> String {
        guard commit != "local" else {
            return commit
        }
        return String(commit.prefix(12))
    }

    private func sustainedEvidenceIdentifier(for label: String) -> String {
        switch label {
        case "H.264 1080p30":
            "sustained-h264-1080p-evidence"
        case "HEVC 1080p30":
            "sustained-hevc-1080p-evidence"
        case "HEVC 4K30":
            "sustained-hevc-4k-evidence"
        default:
            "sustained-unknown-evidence"
        }
    }

    private func formattedBytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private func sustainedMetricsIdentifier(for label: String) -> String {
        switch label {
        case "H.264 1080p30":
            "sustained-h264-1080p-metrics"
        case "HEVC 1080p30":
            "sustained-hevc-1080p-metrics"
        case "HEVC 4K30":
            "sustained-hevc-4k-metrics"
        default:
            "sustained-unknown-metrics"
        }
    }
}

private struct ReportRow: View {
    let title: String
    let value: String
    var monospaced = false
    var accessibilityIdentifier: String?

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .font(monospaced ? .caption.monospaced() : .body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .accessibilityIdentifier(accessibilityIdentifier ?? "")
        }
    }
}

private struct PrivacyBadge: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.tint.opacity(0.12), in: Capsule())
            .foregroundStyle(.tint)
    }
}
