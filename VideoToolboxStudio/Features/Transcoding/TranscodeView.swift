import SwiftUI
import UIKit

struct TranscodeView: View {
    let buildReport: BuildReport

    @StateObject private var store: TranscodeQueueStore
    @State private var importError: String?
    @State private var activityItem: TranscodeActivityItem?
    @State private var activeHelp: TranscodeParameterHelp?
    @State private var appliedCloudTestSettings = false

    init(buildReport: BuildReport, sourceURLs: [URL] = []) {
        self.buildReport = buildReport
        _store = StateObject(
            wrappedValue: TranscodeQueueStore(initialURLs: sourceURLs)
        )
    }

    init(buildReport: BuildReport, sources: [TranscodeSource]) {
        self.buildReport = buildReport
        _store = StateObject(
            wrappedValue: TranscodeQueueStore(initialSources: sources)
        )
    }

    private var isCloudTesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--cloud-testing")
    }

    var body: some View {
        Form {
            appSettingsSection
            professionalSection
            estimateSection
            outputSection
            queueSection
            actionSection
            if isCloudTesting {
                cloudTestingSection
            }
        }
        .navigationTitle("压缩设置")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $activityItem) { item in
            TranscodeActivityView(items: [item.url])
        }
        .alert(item: $activeHelp) { help in
            Alert(
                title: Text(help.title),
                message: Text(help.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .onDisappear {
            store.cancelEstimate()
        }
        .onAppear {
            if isCloudTesting, !appliedCloudTestSettings {
                appliedCloudTestSettings = true
                store.applyCloudTestSettings()
            }
        }
    }

    private var appSettingsSection: some View {
        Section("App 设置") {
            parameterToggle(
                "记住上次参数",
                help: .rememberSettings,
                isOn: $store.rememberLastSettings
            )
            Button("恢复默认参数") {
                store.restoreDefaultSettings()
            }
            .disabled(store.isRunning)
        }
    }

    private var professionalSection: some View {
        NativeCompressionSettingsView(
            settings: $store.settings,
            capabilityState: store.nativeCapabilityState,
            isDisabled: store.isRunning,
            onCodecChange: store.selectCodec
        )
    }

    private var estimateSection: some View {
        Section {
            switch store.estimateState {
            case .idle:
                Button {
                    store.estimateFirstOutput()
                } label: {
                    Label("试编码估算首个视频", systemImage: "gauge.with.dots.needle.50percent")
                }
                .disabled(store.jobs.isEmpty || store.isRunning)
            case .running(let progress):
                ProgressView(value: progress) {
                    Text("正在试编码中段样片")
                } currentValueLabel: {
                    Text("\(Int(progress * 100))%")
                }
                Button("取消估算", role: .cancel) {
                    store.cancelEstimate()
                }
            case .ready(let estimate):
                LabeledContent(
                    "预计输出",
                    value: formattedBytes(estimate.estimatedOutputBytes)
                )
                LabeledContent(
                    "合理范围",
                    value: "\(formattedBytes(estimate.lowerBoundBytes))～\(formattedBytes(estimate.upperBoundBytes))"
                )
                if let ratio = estimate.estimatedOutputToInputRatio {
                    LabeledContent(
                        "预计体积",
                        value: estimatedSizeChange(ratio)
                    )
                }
                Button("重新估算") {
                    store.estimateFirstOutput()
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button("重新估算") {
                    store.estimateFirstOutput()
                }
            }
        } header: {
            parameterTitle("输出大小估算", help: .sizeEstimate)
        }
    }

    private var outputSection: some View {
        Section("输出处理") {
            parameterToggle(
                "完成后自动存入相册",
                help: .automaticPhotoSave,
                isOn: $store.automaticallySaveToPhotoLibrary
            )
            .disabled(store.isRunning)
        }
    }

    @ViewBuilder
    private var queueSection: some View {
        Section("任务队列") {
            if store.jobs.isEmpty {
                ContentUnavailableView(
                    "尚未选择视频",
                    systemImage: "film.stack",
                    description: Text("返回视频库选择一个或多个视频。")
                )
            } else {
                ForEach(store.jobs) { job in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(job.source.fileName)
                            .lineLimit(2)
                        jobState(job)

                        if let result = job.result {
                            HStack(spacing: 18) {
                                Button {
                                    activityItem = TranscodeActivityItem(
                                        url: result.outputURL
                                    )
                                } label: {
                                    Label("导出文件", systemImage: "square.and.arrow.up")
                                }
                                Spacer()
                                NavigationLink {
                                    TranscodeReportView(result: result)
                                } label: {
                                    Label("查看报告", systemImage: "doc.text.magnifyingglass")
                                }
                            }
                            .font(.subheadline)
                            .buttonStyle(.bordered)

                            Text(
                                "\(formattedBytes(result.report.metrics.inputBytes)) → "
                                    + "\(formattedBytes(result.report.metrics.outputBytes)) · "
                                    + actualSizeChange(
                                        result.report.metrics.outputToInputSizeRatio
                                    )
                            )
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)

                            if let diagnostics = job.runtimeDiagnostics {
                                runtimeDiagnosticsSummary(
                                    diagnostics,
                                    title: "结束时只读状态与诊断"
                                )
                            }
                            photoSaveControls(job)
                            sourceDeletionControls(job)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            store.remove(job.id)
                        } label: {
                            Label("移除", systemImage: "trash")
                        }
                        .disabled(store.isRunning)
                    }
                }
            }
        }
    }

    private var actionSection: some View {
        Section {
            if store.isRunning {
                Button(role: .destructive) {
                    store.cancel()
                } label: {
                    Label("取消当前任务与队列", systemImage: "stop.fill")
                }
                .accessibilityIdentifier("transcode-cancel")
            } else {
                Button {
                    store.start(buildReport: buildReport)
                } label: {
                    Label(
                        store.jobs.count > 1 ? "开始批量转换" : "开始转换",
                        systemImage: "play.fill"
                    )
                }
                .disabled(store.queuedCount == 0 || store.isEstimating)
                .accessibilityIdentifier("transcode-start")

                if store.jobs.contains(where: {
                    if case .completed = $0.state { return true }
                    if case .failed = $0.state { return true }
                    if case .cancelled = $0.state { return true }
                    return false
                }) {
                    Button("清理已完成记录") {
                        store.clearFinished()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var cloudTestingSection: some View {
        Section("云端回归") {
            Button {
                guard let sampleURL = Bundle.main.url(
                    forResource: "CloudTranscodeSample",
                    withExtension: "mov"
                ) else {
                    importError = "测试素材没有进入 App Bundle。"
                    return
                }
                store.add([sampleURL], replaceQueue: true)
                store.applyCloudTestSettings()
                store.start(buildReport: buildReport)
            } label: {
                Label("运行真实转码自检", systemImage: "checkmark.seal")
            }
            .disabled(store.isRunning)
            .accessibilityIdentifier("cloud-transcode-run")

            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("transcode-import-error")
            }

            if let firstJob = store.jobs.first {
                switch firstJob.state {
                case .running(let progress):
                    Text("真实转码进度 \(Int(progress * 100))%")
                        .accessibilityIdentifier("cloud-transcode-progress")
                case .failed(let message):
                    Text(message)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("cloud-transcode-error")
                case .queued, .savingToPhotos, .completed, .cancelled:
                    EmptyView()
                }
            }

            if store.completedCount == 1,
               let result = store.jobs.first?.result
            {
                Text("1/1 · \(result.report.resolvedSettings.codecFourCC) · 保真核验通过")
                    .accessibilityIdentifier("cloud-transcode-summary")
                Text(
                    "\(result.report.metrics.encodedVideoFrames) 帧 · "
                        + "\(result.report.metrics.videoEncodingPasses) 遍 · "
                        + "\(result.report.metrics.copiedNonVideoSamples) 个非视频样本 · "
                        + String(
                            format: "写入起点 %.6f 秒 · ",
                            result.report.metrics.writerSessionStartSeconds
                        )
                        + formattedBytes(result.report.metrics.outputBytes)
                )
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("cloud-transcode-metrics")
                Text(multiPassEvidence(result.report))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("cloud-transcode-multipass")
            }
        }
    }

    private func multiPassEvidence(_ report: TranscodeReport) -> String {
        if report.metrics.videoEncodingPasses > 1 {
            return "多遍编码实际执行 \(report.metrics.videoEncodingPasses) 遍"
        }
        guard report.requestedSettings.multiPassStorageEnabled else {
            return "MultiPassStorage 未设置，实际单遍"
        }
        guard let write = report.propertyWrites.first(where: {
            $0.key == "MultiPassStorage"
        }) else {
            return "MultiPassStorage 未执行，实际单遍"
        }
        if write.status.succeeded {
            return "设备接受多遍编码，但本片未请求追加遍次"
        }
        return "设备不支持当前多遍路径，自动回退单遍"
    }

    @ViewBuilder
    private func jobState(_ job: TranscodeQueueJob) -> some View {
        switch job.state {
        case .queued:
            Label("等待转换", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .running(let progress):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress) {
                    Text("正在转换")
                } currentValueLabel: {
                    Text("\(Int(progress * 100))%")
                }
                if let diagnostics = job.runtimeDiagnostics {
                    runtimeDiagnosticsSummary(
                        diagnostics,
                        title: "编码中只读状态与诊断"
                    )
                }
            }
        case .savingToPhotos:
            ProgressView("转换完成，正在存入相册")
        case .completed:
            Label("完成并通过保真核验", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .cancelled:
            Label("已取消，残缺文件已清理", systemImage: "stop.circle")
                .foregroundStyle(.orange)
        case .failed(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private func runtimeDiagnosticsSummary(
        _ snapshot: TranscodeRuntimeDiagnosticsSnapshot,
        title: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LabeledContent("阶段", value: snapshot.stageTitle)
            ForEach(
                [
                    "UsingHardwareAcceleratedVideoEncoder",
                    "NumberOfPendingFrames",
                    "EstimatedAverageBytesPerFrame",
                    "UsingGPURegistryID",
                ],
                id: \.self
            ) { key in
                if let readback = snapshot.readback(for: key) {
                    LabeledContent(key, value: readback.displayText)
                }
            }
        }
        .font(.caption.monospaced())
        .padding(8)
        .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("transcode-runtime-diagnostics")
    }

    private func formattedBytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private func parameterTitle(
        _ title: String,
        help: TranscodeParameterHelp
    ) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Button {
                activeHelp = help
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title)说明")
        }
    }

    private func parameterToggle(
        _ title: String,
        help: TranscodeParameterHelp,
        isOn: Binding<Bool>
    ) -> some View {
        HStack {
            parameterTitle(title, help: help)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }

    @ViewBuilder
    private func photoSaveControls(_ job: TranscodeQueueJob) -> some View {
        switch job.photoSaveState {
        case .notRequested:
            Button {
                store.saveToPhotoLibrary(job.id)
            } label: {
                Label("保存到相册", systemImage: "photo.badge.plus")
            }
        case .saving:
            ProgressView("正在保存到相册")
        case .saved:
            Label("已存入相册", systemImage: "photo.badge.checkmark")
                .font(.subheadline)
                .foregroundStyle(.green)
                .accessibilityIdentifier("photo-save-success")
        case .failed(let message):
            Label(
                "转换成功，但保存相册失败：\(message)",
                systemImage: "exclamationmark.triangle.fill"
            )
                .font(.caption)
                .foregroundStyle(.red)
            Button("重试保存到相册") {
                store.saveToPhotoLibrary(job.id)
            }
        }
    }

    @ViewBuilder
    private func sourceDeletionControls(_ job: TranscodeQueueJob) -> some View {
        if job.source.photoLibraryAssetIdentifier != nil {
            switch job.sourceDeletionState {
            case .available:
                if case .saved = job.photoSaveState {
                    HStack {
                        Button(role: .destructive) {
                            store.deleteOriginal(job.id)
                        } label: {
                            Label("删除原视频", systemImage: "trash")
                        }
                        Spacer()
                        Button {
                            activeHelp = .deleteOriginal
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除原视频说明")
                    }
                }
            case .deleting:
                ProgressView("等待系统确认删除")
            case .deleted:
                Label("原视频已移至“最近删除”", systemImage: "trash.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("重试删除原视频", role: .destructive) {
                    store.deleteOriginal(job.id)
                }
            }
        }
    }

    private func actualSizeChange(_ ratio: Double) -> String {
        guard ratio.isFinite, ratio > 0 else {
            return "体积变化未知"
        }
        if ratio < 1 {
            return String(format: "缩小 %.1f%%", (1 - ratio) * 100)
        }
        return String(format: "增大 %.1f%%", (ratio - 1) * 100)
    }

    private func estimatedSizeChange(_ ratio: Double) -> String {
        guard ratio.isFinite, ratio > 0 else {
            return "无法计算"
        }
        if ratio < 1 {
            return String(format: "约缩小 %.1f%%", (1 - ratio) * 100)
        }
        return String(format: "约增大 %.1f%%", (ratio - 1) * 100)
    }
}

private enum TranscodeParameterHelp: String, Identifiable {
    case rememberSettings
    case sizeEstimate
    case automaticPhotoSave
    case deleteOriginal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rememberSettings:
            "记住上次参数"
        case .sizeEstimate:
            "输出大小估算"
        case .automaticPhotoSave:
            "完成后自动存入相册"
        case .deleteOriginal:
            "删除原视频"
        }
    }

    var message: String {
        switch self {
        case .rememberSettings:
            "这是 App 设置，不是编码器参数。默认开启；下次打开时恢复最近一次原生参数。关闭后不再保存，并在下次使用原生字段默认值。"
        case .sizeEstimate:
            "这是 App 工具，不是编码器参数。对首个视频中段最多 5 秒执行相同的硬件试编码，再按全片时长外推；画面复杂度变化仍会造成误差。"
        case .automaticPhotoSave:
            "输出通过硬件编码和全部保真核验后才写入系统照片库，原视频不会被覆盖。保存失败时仍保留可导出的压缩文件。"
        case .deleteOriginal:
            "仅在压缩视频已确认存入照片库后可用。删除仍需通过 iOS 系统确认，并会同步到 iCloud 和其他设备；可从“最近删除”恢复。"
        }
    }
}

private struct TranscodeActivityItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct TranscodeActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(
        context: Context
    ) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}
