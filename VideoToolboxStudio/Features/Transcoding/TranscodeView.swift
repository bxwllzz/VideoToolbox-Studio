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
                store.applyPreset(.fidelity)
            }
        }
    }

    private var presetSection: some View {
        Section("参数模板") {
            HStack {
                parameterTitle("模板", help: .preset)
                Spacer()
                Picker("", selection: Binding(
                    get: { store.selectedPreset },
                    set: { store.applyPreset($0) }
                )) {
                    ForEach(TranscodePreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .labelsHidden()
            }
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
        Section {
            HStack {
                parameterTitle("目标编码", help: .targetCodec)
                Spacer()
                Picker("", selection: settingBinding(\.targetCodec)) {
                    ForEach(TranscodeTargetCodec.allCases) { codec in
                        Text(codec.title).tag(codec)
                    }
                }
                .labelsHidden()
            }

            HStack {
                parameterTitle("编码质量", help: .encodingQuality)
                Spacer()
                Picker("", selection: encodingQualityBinding) {
                    ForEach(TranscodeEncodingQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .labelsHidden()
            }

            HStack {
                parameterTitle("码率控制", help: .rateControl)
                Spacer()
                Picker("", selection: settingBinding(\.rateControl)) {
                    ForEach(TranscodeRateControl.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
            }

            switch store.settings.rateControl {
            case .sourceRatio:
                LabeledContent(
                    content: {
                        Text("\(Int(store.settings.sourceBitRateRatio * 100))%")
                    },
                    label: {
                        parameterTitle("源码率比例", help: .sourceRatio)
                    }
                )
                Slider(
                    value: settingBinding(\.sourceBitRateRatio),
                    in: 0.10...1.50,
                    step: 0.05
                )
            case .fixedBitRate:
                LabeledContent(
                    content: {
                        Text(
                            String(
                                format: "%.1f Mbps",
                                Double(store.settings.fixedBitRate) / 1_000_000
                            )
                        )
                    },
                    label: {
                        parameterTitle("平均码率", help: .fixedBitRate)
                    }
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
            case .quality:
                LabeledContent(
                    content: {
                        Text(String(format: "%.2f", store.settings.quality))
                    },
                    label: {
                        parameterTitle("质量因子", help: .quality)
                    }
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
            }

            parameterToggle(
                "限制峰值码率",
                help: .peakLimit,
                isOn: Binding(
                    get: { store.settings.dataRateLimitMultiplier != nil },
                    set: {
                        store.settings.dataRateLimitMultiplier = $0 ? 1.5 : nil
                        store.markCustom()
                    }
                )
            )
            if store.settings.dataRateLimitMultiplier != nil {
                LabeledContent(
                    content: {
                        Text(
                            String(
                                format: "%.2f×",
                                store.settings.dataRateLimitMultiplier ?? 1.5
                            )
                        )
                    },
                    label: {
                        parameterTitle("峰值倍数", help: .peakMultiplier)
                    }
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
            }

            Stepper(
                value: settingBinding(\.maxKeyFrameInterval),
                in: 0...600,
                step: 10
            ) {
                HStack {
                    parameterTitle("关键帧帧数上限", help: .keyFrameInterval)
                    Spacer()
                    Text(
                        store.settings.maxKeyFrameInterval == 0
                            ? "关闭"
                            : "\(store.settings.maxKeyFrameInterval) 帧"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            LabeledContent(
                content: {
                    Text(
                        store.settings.maxKeyFrameIntervalDuration == 0
                            ? "关闭"
                            : String(
                                format: "%.1f s",
                                store.settings.maxKeyFrameIntervalDuration
                            )
                    )
                },
                label: {
                    parameterTitle("关键帧时间上限", help: .keyFrameDuration)
                }
            )
            Slider(
                value: settingBinding(\.maxKeyFrameIntervalDuration),
                in: 0...10,
                step: 0.5
            )
            parameterToggle(
                "允许帧重排序（B 帧）",
                help: .frameReordering,
                isOn: settingBinding(\.allowFrameReordering)
            )
            parameterToggle(
                "实时编码",
                help: .realTime,
                isOn: realTimeBinding
            )
            parameterToggle(
                "速度优先于质量",
                help: .speedPriority,
                isOn: speedPriorityBinding
            )
        } header: {
            Text("专业参数（已验证）")
        }
        .disabled(store.isRunning)
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
                store.applyPreset(.fidelity)
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
            return "精细编码已执行 \(report.metrics.videoEncodingPasses) 遍"
        }
        guard let write = report.propertyWrites.first(where: {
            $0.key == "MultiPassStorage"
        }) else {
            return "标准单遍编码"
        }
        if write.status.succeeded {
            return "设备接受多遍编码，但本片未请求追加遍次"
        }
        return "设备不支持当前多遍路径，已保真回退单遍"
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

    private var encodingQualityBinding: Binding<TranscodeEncodingQuality> {
        Binding(
            get: { store.settings.encodingQuality },
            set: {
                store.settings.encodingQuality = $0
                if $0 == .refined {
                    store.settings.realTime = false
                    store.settings.prioritizeEncodingSpeedOverQuality = false
                }
                store.markCustom()
            }
        )
    }

    private var realTimeBinding: Binding<Bool> {
        Binding(
            get: { store.settings.realTime },
            set: {
                store.settings.realTime = $0
                if $0 {
                    store.settings.encodingQuality = .standard
                }
                store.markCustom()
            }
        )
    }

    private var speedPriorityBinding: Binding<Bool> {
        Binding(
            get: { store.settings.prioritizeEncodingSpeedOverQuality },
            set: {
                store.settings.prioritizeEncodingSpeedOverQuality = $0
                if $0 {
                    store.settings.encodingQuality = .standard
                }
                store.markCustom()
            }
        )
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
    case preset
    case rememberSettings
    case targetCodec
    case encodingQuality
    case rateControl
    case sourceRatio
    case fixedBitRate
    case quality
    case peakLimit
    case peakMultiplier
    case keyFrameInterval
    case keyFrameDuration
    case frameReordering
    case realTime
    case speedPriority
    case sizeEstimate
    case automaticPhotoSave
    case deleteOriginal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .preset:
            "参数模板"
        case .rememberSettings:
            "记住上次参数"
        case .targetCodec:
            "目标编码"
        case .encodingQuality:
            "编码质量"
        case .rateControl:
            "码率控制"
        case .sourceRatio:
            "源码率比例"
        case .fixedBitRate:
            "固定平均码率"
        case .quality:
            "质量因子"
        case .peakLimit:
            "限制峰值码率"
        case .peakMultiplier:
            "峰值倍数"
        case .keyFrameInterval:
            "关键帧帧数上限"
        case .keyFrameDuration:
            "关键帧时间上限"
        case .frameReordering:
            "允许帧重排序（B 帧）"
        case .realTime:
            "实时编码"
        case .speedPriority:
            "速度优先于质量"
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
        case .preset:
            "保真优先使用精细编码和约 80% 源码率；均衡压缩约 60%；更小体积约 40%；H.264 兼容约 70%。选择专业自定义可逐项调整。"
        case .rememberSettings:
            "默认开启。下次打开压缩设置时恢复最近一次模板和全部编码参数；关闭后下次使用均衡压缩默认值。"
        case .targetCodec:
            "自动保真会使用 HEVC，并自动保持输入的色彩、动态范围和位深。若 H.264 无法保真承载输入，任务会直接拒绝，不会静默降级。"
        case .encodingQuality:
            "标准为一次硬件编码。精细会关闭实时与速度优先，并请求多遍分析；在相同目标平均码率下通常能改善复杂画面的码率分配，但处理更慢、临时空间更多。当前硬件不支持多遍时，报告会明确记录回退，绝不伪装生效。"
        case .rateControl:
            "源码率比例和固定平均码率适合控制相同体积；质量因子让编码器自行决定码率，体积不可预先固定。若要“同体积更高质量”，请选择前两者并配合精细编码。"
        case .sourceRatio:
            "目标平均视频码率＝原视频平均视频码率×比例。它不包含原音频、元数据和容器开销，因此最终文件比例会有少量偏差。"
        case .fixedBitRate:
            "直接指定长期目标平均视频码率。瞬时码率仍可波动，最终文件还包含原音频、元数据和容器开销。"
        case .quality:
            "0～1 是编码器的质量偏好，不是压缩率或保留百分比。同一数值会因画面复杂度和编码器不同产生不同体积；请用真实试编码估算。"
        case .peakLimit:
            "限制任意连续 1 秒内的压缩视频数据量，防止短时码率过高。它是视频码流硬上限，不是文件大小上限。"
        case .peakMultiplier:
            "源码率比例或固定平均码率模式下，倍数相对于目标平均视频码率；质量因子模式没有目标平均码率，因此相对于原视频平均视频码率。"
        case .keyFrameInterval:
            "按帧数限制两个关键帧之间最多相隔多少帧；0 表示关闭。数值越小越利于随机定位，但通常会降低压缩效率。"
        case .keyFrameDuration:
            "按秒数限制两个关键帧之间最多相隔多久；0 表示关闭，适合可变帧率视频。与帧数上限同时启用时，先达到者要求关键帧。"
        case .frameReordering:
            "允许双向预测帧，通常能在相同码率下提高画质。离线压缩建议开启；代价是增加编解码延迟。"
        case .realTime:
            "要求编码器及时输出，适合直播。离线压缩建议关闭；开启后会自动退出精细编码。"
        case .speedPriority:
            "允许编码器牺牲压缩效率或画质换速度。只求保真和质量时建议关闭；开启后会自动退出精细编码。"
        case .sizeEstimate:
            "对首个视频中段最多 5 秒执行与正式任务相同的硬件试编码，再按全片时长外推。画面复杂度变化仍会造成误差，质量因子无法靠公式精确换算。"
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
