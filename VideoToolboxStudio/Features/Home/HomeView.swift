import SwiftUI

struct HomeView: View {
    @ObservedObject var installationState: InstallationState

    @StateObject private var capabilityStore = CapabilityProbeStore()
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
                Label("只读能力探针", systemImage: "waveform.path.ecg.rectangle")
                    .font(.title2.bold())
                    .foregroundStyle(.tint)

                Text(
                    "枚举系统编码器，针对 H.264 1080p、HEVC 1080p 和 HEVC 4K 创建严格硬件会话，并导出原始属性。"
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
                        value: "\(capabilityReport.successfulHardwareSessionCount)/\(capabilityReport.configurationProbes.count)"
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
            ReportRow(title: "Commit", value: shortCommit(report.commitSHA), monospaced: true)
            ReportRow(title: "构建时间", value: report.builtAt, monospaced: true)
            ReportRow(title: "运行编号", value: report.buildRunID, monospaced: true)
        }
    }

    private var deviceSection: some View {
        Section("目标设备") {
            ReportRow(title: "设备标识", value: report.deviceIdentifier, monospaced: true)
            ReportRow(title: "设备类型", value: report.deviceModel)
            ReportRow(title: "系统", value: "\(report.systemName) \(report.systemVersion)")
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
}

private struct ReportRow: View {
    let title: String
    let value: String
    var monospaced = false

    var body: some View {
        LabeledContent(title) {
            Text(value)
                .font(monospaced ? .caption.monospaced() : .body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
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
