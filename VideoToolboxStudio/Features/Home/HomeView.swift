import SwiftUI

struct HomeView: View {
    @ObservedObject var installationState: InstallationState

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
                Label("安装闭环验证版", systemImage: "checkmark.seal.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.tint)

                Text("当前版本只验证 GitHub 云端构建、SideStore 安装、覆盖更新与报告回传，不包含视频编码功能。")
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
