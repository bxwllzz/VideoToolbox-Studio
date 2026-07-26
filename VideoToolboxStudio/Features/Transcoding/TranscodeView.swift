import SwiftUI
import UIKit

struct TranscodeView: View {
    let buildReport: BuildReport

    @StateObject private var store: TranscodeQueueStore
    @State private var importError: String?
    @State private var activityItem: TranscodeActivityItem?

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
            presetSection
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
        .onDisappear {
            store.cancelEstimate()
        }
    }

    private var presetSection: some View {
        Section("参数模板") {
            Picker("模板", selection: Binding(
                get: { store.selectedPreset },
                set: { store.applyPreset($0) }
            )) {
                ForEach(TranscodePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            Text(store.selectedPreset.summary)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var professionalSection: some View {
        Section {
            Picker("目标编码", selection: settingBinding(\.targetCodec)) {
                ForEach(TranscodeTargetCodec.allCases) { codec in
                    Text(codec.title).tag(codec)
                }
            }
            parameterNote(
                "自动保真和 HEVC 优先使用 HEVC；H.264 兼容性更广，但 HDR 或 10-bit 输入会被拒绝，避免静默丢失动态范围。"
            )

            Picker("码率控制", selection: settingBinding(\.rateControl)) {
                ForEach(TranscodeRateControl.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            parameterNote(
                "三种模式互斥：源码率比例和固定平均码率可预测体积；质量因子让编码器按画面复杂度自行分配码率。"
            )

            switch store.settings.rateControl {
            case .sourceRatio:
                LabeledContent(
                    "源码率比例",
                    value: "\(Int(store.settings.sourceBitRateRatio * 100))%"
                )
                Slider(
                    value: settingBinding(\.sourceBitRateRatio),
                    in: 0.10...1.50,
                    step: 0.05
                )
                parameterNote(
                    "目标平均视频码率 = 原视频平均视频码率 × 此比例；不包含音频和容器开销。"
                )
            case .fixedBitRate:
                LabeledContent(
                    "平均码率",
                    value: String(
                        format: "%.1f Mbps",
                        Double(store.settings.fixedBitRate) / 1_000_000
                    )
                )
                Slider(
                    value: Binding(
                        get: { Double(store.settings.fixedBitRate) / 1_000_000 },
                        set: {
                            store.settings.fixedBitRate = Int($0 * 1_000_000)
                            store.markCustom()
                        }
                    ),
                    in: 0.5...100,
                    step: 0.5
                )
                parameterNote(
                    "直接指定长期目标平均视频码率。实际短时码率可上下波动，最终文件还包含原音频、元数据和容器开销。"
                )
            case .quality:
                LabeledContent(
                    "质量因子",
                    value: String(format: "%.2f", store.settings.quality)
                )
                Slider(
                    value: settingBinding(\.quality),
                    in: 0...1,
                    step: 0.01
                )
                LabeledContent(
                    "当前质量偏好",
                    value: qualityPreferenceDescription
                )
                parameterNote(
                    "0～1 是编码器质量偏好，不是压缩率或保留百分比。Apple 的参考锚点是 0.25 低、0.50 正常、0.75 高；1.0 也只有在编码器支持时才可能无损。"
                )
            }

            Toggle("限制峰值码率", isOn: Binding(
                get: { store.settings.dataRateLimitMultiplier != nil },
                set: {
                    store.settings.dataRateLimitMultiplier = $0 ? 1.5 : nil
                    store.markCustom()
                }
            ))
            if store.settings.dataRateLimitMultiplier != nil {
                LabeledContent(
                    "峰值倍数",
                    value: String(
                        format: "%.2f×",
                        store.settings.dataRateLimitMultiplier ?? 1.5
                    )
                )
                Slider(
                    value: Binding(
                        get: { store.settings.dataRateLimitMultiplier ?? 1.5 },
                        set: {
                            store.settings.dataRateLimitMultiplier = $0
                            store.markCustom()
                        }
                    ),
                    in: 1...4,
                    step: 0.25
                )
                parameterNote(peakLimitDescription)
            }

            Stepper(
                store.settings.maxKeyFrameInterval == 0
                    ? "最大关键帧间隔 关闭"
                    : "最大关键帧间隔 \(store.settings.maxKeyFrameInterval) 帧",
                value: settingBinding(\.maxKeyFrameInterval),
                in: 0...600,
                step: 10
            )
            parameterNote(
                "按帧数限制两个关键帧之间最多经过多少帧；0 表示关闭此约束。数值越小，随机定位和容错更好，但文件通常更大。"
            )
            LabeledContent(
                "最大关键帧时长",
                value: String(
                    format: "%.1f s",
                    store.settings.maxKeyFrameIntervalDuration
                )
            )
            Slider(
                value: settingBinding(\.maxKeyFrameIntervalDuration),
                in: 0...10,
                step: 0.5
            )
            parameterNote(
                "按时间限制两个关键帧之间最多相隔多少秒；0 表示关闭。它适合可变帧率视频。若帧数与时间同时启用，先达到的条件生效。"
            )
            Toggle(
                "允许帧重排序（B 帧）",
                isOn: settingBinding(\.allowFrameReordering)
            )
            parameterNote(
                "允许编码器使用双向预测帧，通常能提高压缩效率，但会增加编解码延迟。"
            )
            Toggle("实时编码", isOn: settingBinding(\.realTime))
            parameterNote(
                "要求编码器及时输出，适合直播和实时链路；离线压缩关闭后，编码器可用更多时间优化结果。"
            )
            Toggle(
                "速度优先于质量",
                isOn: settingBinding(\.prioritizeEncodingSpeedOverQuality)
            )
            parameterNote(
                "允许硬件编码器牺牲部分压缩效率或画质换取更快处理；与实时编码是两个独立提示。"
            )

            Text(
                "设置值、VideoToolbox 返回状态、实际硬编标记和重新读取的输出格式都会写入报告。"
            )
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("专业参数（已验证）")
        } footer: {
            Text(
                "这里不是设备公开属性的全部集合，只显示已接入真实转码、可回读并有保真核验的参数。其他设备相关属性将在动态能力浏览器中按支持情况显示。"
            )
        }
        .disabled(store.isRunning)
    }

    private var estimateSection: some View {
        Section("输出大小估算") {
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
                Text(
                    "对“\(estimate.sourceFileName)”中段约 \(estimate.sampledDurationSeconds, specifier: "%.1f") 秒执行与正式任务相同的硬件试编码，再按全片 \(estimate.sourceDurationSeconds, specifier: "%.1f") 秒外推。画面复杂度变化会造成误差，质量因子不能靠公式直接换算。"
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button("重新估算") {
                    store.estimateFirstOutput()
                }
            }
        }
    }

    private var outputSection: some View {
        Section("输出处理") {
            Toggle(
                "完成后自动存入相册",
                isOn: $store.automaticallySaveToPhotoLibrary
            )
            .disabled(store.isRunning)
            Text(
                "输出通过硬件编码与保真核验后才写入照片库；原视频不会被覆盖。关闭后仍可在单个结果中手动保存。"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
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
                store.applyPreset(.balanced)
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
                        + "\(result.report.metrics.copiedNonVideoSamples) 个非视频样本 · "
                        + formattedBytes(result.report.metrics.outputBytes)
                )
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("cloud-transcode-metrics")
            }
        }
    }

    @ViewBuilder
    private func jobState(_ job: TranscodeQueueJob) -> some View {
        switch job.state {
        case .queued:
            Label("等待转换", systemImage: "clock")
                .foregroundStyle(.secondary)
        case .running(let progress):
            ProgressView(value: progress) {
                Text("正在转换")
            } currentValueLabel: {
                Text("\(Int(progress * 100))%")
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

    private func settingBinding<Value>(
        _ keyPath: WritableKeyPath<TranscodeSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { store.settings[keyPath: keyPath] },
            set: {
                store.settings[keyPath: keyPath] = $0
                store.markCustom()
            }
        )
    }

    private func formattedBytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    private var peakLimitDescription: String {
        switch store.settings.rateControl {
        case .sourceRatio, .fixedBitRate:
            "限制任意连续 1 秒内的压缩视频数据量。倍数相对于目标平均视频码率，不是相对于文件大小。"
        case .quality:
            "质量模式没有目标平均码率，因此倍数相对于原视频平均视频码率。当前实现会真实写入 1 秒窗口硬上限。"
        }
    }

    private var qualityPreferenceDescription: String {
        switch store.settings.quality {
        case ..<0.25:
            "低"
        case 0.25..<0.50:
            "较低"
        case 0.50..<0.75:
            "正常"
        case 0.75..<1:
            "高"
        default:
            "最高"
        }
    }

    private func parameterNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
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
                    Button(role: .destructive) {
                        store.deleteOriginal(job.id)
                    } label: {
                        Label("删除原视频", systemImage: "trash")
                    }
                    Text(
                        "将调用系统照片删除确认；删除会同步到 iCloud 和其他设备，原视频可在“最近删除”中恢复。"
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
