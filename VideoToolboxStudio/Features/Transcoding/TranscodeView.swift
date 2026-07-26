import SwiftUI
import UniformTypeIdentifiers

struct TranscodeView: View {
    let buildReport: BuildReport

    @StateObject private var store = TranscodeQueueStore()
    @State private var showSingleImporter = false
    @State private var showBatchImporter = false
    @State private var importError: String?

    private var isCloudTesting: Bool {
        ProcessInfo.processInfo.arguments.contains("--cloud-testing")
    }

    var body: some View {
        Form {
            importSection
            presetSection
            professionalSection
            queueSection
            actionSection
            if isCloudTesting {
                cloudTestingSection
            }
        }
        .navigationTitle("视频转换")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(
            isPresented: $showSingleImporter,
            allowedContentTypes: [.movie],
            allowsMultipleSelection: false,
            onCompletion: { handleImport($0, replaceQueue: true) }
        )
        .fileImporter(
            isPresented: $showBatchImporter,
            allowedContentTypes: [.movie],
            allowsMultipleSelection: true,
            onCompletion: { handleImport($0, replaceQueue: false) }
        )
    }

    private var importSection: some View {
        Section("输入") {
            Button {
                showSingleImporter = true
            } label: {
                Label("选择单个视频", systemImage: "film")
            }
            .disabled(store.isRunning)
            .accessibilityIdentifier("transcode-single-import")

            Button {
                showBatchImporter = true
            } label: {
                Label("添加多个视频", systemImage: "square.stack.3d.up")
            }
            .disabled(store.isRunning)
            .accessibilityIdentifier("transcode-batch-import")

            Text("支持 Files 中的 MOV、MP4 等系统可读视频；原文件永不覆盖。")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("transcode-import-error")
            }
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
        Section("专业参数") {
            Picker("目标编码", selection: settingBinding(\.targetCodec)) {
                ForEach(TranscodeTargetCodec.allCases) { codec in
                    Text(codec.title).tag(codec)
                }
            }

            Picker("码率控制", selection: settingBinding(\.rateControl)) {
                ForEach(TranscodeRateControl.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

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
            }

            Stepper(
                "最大关键帧间隔 \(store.settings.maxKeyFrameInterval) 帧",
                value: settingBinding(\.maxKeyFrameInterval),
                in: 0...600,
                step: 10
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
                in: 0.5...10,
                step: 0.5
            )
            Toggle(
                "允许帧重排序（B 帧）",
                isOn: settingBinding(\.allowFrameReordering)
            )
            Toggle("实时编码", isOn: settingBinding(\.realTime))
            Toggle(
                "速度优先于质量",
                isOn: settingBinding(\.prioritizeEncodingSpeedOverQuality)
            )

            Text(
                "设置值、VideoToolbox 返回状态、实际硬编标记和重新读取的输出格式都会写入报告。"
            )
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .disabled(store.isRunning)
    }

    @ViewBuilder
    private var queueSection: some View {
        Section("任务队列") {
            if store.jobs.isEmpty {
                ContentUnavailableView(
                    "尚未选择视频",
                    systemImage: "film.stack",
                    description: Text("选择一个视频，或批量添加多个视频。")
                )
            } else {
                ForEach(store.jobs) { job in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(job.sourceURL.lastPathComponent)
                            .lineLimit(2)
                        jobState(job)

                        if let result = job.result {
                            HStack {
                                ShareLink(item: result.outputURL) {
                                    Label("视频", systemImage: "square.and.arrow.up")
                                }
                                Spacer()
                                ShareLink(item: result.reportURL) {
                                    Label("报告", systemImage: "doc.text")
                                }
                            }
                            .font(.subheadline)

                            Text(
                                "输出 \(formattedBytes(result.report.metrics.outputBytes)) · "
                                    + String(
                                        format: "%.1f%%",
                                        result.report.metrics.outputToInputSizeRatio * 100
                                    )
                                    + " · 保真核验通过"
                            )
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
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
                .disabled(store.queuedCount == 0)
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

            if let firstJob = store.jobs.first {
                switch firstJob.state {
                case .running(let progress):
                    Text("真实转码进度 \(Int(progress * 100))%")
                        .accessibilityIdentifier("cloud-transcode-progress")
                case .failed(let message):
                    Text(message)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("cloud-transcode-error")
                case .queued, .completed, .cancelled:
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

    private func handleImport(
        _ result: Result<[URL], Error>,
        replaceQueue: Bool
    ) {
        switch result {
        case .success(let urls):
            store.add(urls, replaceQueue: replaceQueue)
            importError = nil
        case .failure(let error):
            importError = error.localizedDescription
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
}
