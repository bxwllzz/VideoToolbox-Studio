import SwiftUI

struct NativeCompressionSettingsView: View {
    @Binding var settings: TranscodeSettings
    let capabilityState: NativeCompressionCapabilityState
    let isDisabled: Bool
    let onCodecChange: (TranscodeTargetCodec) -> Void

    @State private var activeHelp: NativeCompressionHelp?
    @State private var jsonEditor: NativeCompressionJSONEditorItem?
    @State private var jsonDraft = ""
    @State private var jsonError: String?
    @State private var expandedCategories:
        Set<NativeCompressionPropertyCategory> = []

    var body: some View {
        Group {
            encoderSection
            rateControlSection
            ForEach(editableCategories) { category in
                categorySection(category)
            }
            diagnosticsSection
        }
        .sheet(item: $activeHelp) { help in
            NativeCompressionHelpView(help: help)
        }
        .sheet(item: $jsonEditor) { item in
            jsonEditorView(item)
        }
    }

    private var editableCategories: [NativeCompressionPropertyCategory] {
        NativeCompressionPropertyCategory.allCases.filter {
            $0 != .rateControl && $0 != .diagnostics
        }
    }

    private var encoderSection: some View {
        Section {
            HStack {
                helpTitle(
                    "codecType",
                    title: "codecType",
                    message: "原生创建参数：VTCompressionSessionCreate 的 codecType。"
                        + "H.264 对应 kCMVideoCodecType_H264；HEVC 对应 "
                        + "kCMVideoCodecType_HEVC。\n\n"
                        + "影响：H.264 兼容性更广；HEVC 通常压缩效率更高，"
                        + "并承载 10-bit、HDR、Alpha 和多视角等高级能力。",
                    documentationURL: URL(
                        string:
                            "https://developer.apple.com/documentation/"
                            + "videotoolbox/vtcompressionsessioncreate"
                    )
                )
                Spacer()
                Picker("", selection: codecBinding) {
                    ForEach(TranscodeTargetCodec.allCases) { codec in
                        Text(codec.title).tag(codec)
                    }
                }
                .labelsHidden()
            }

            capabilityStatus
        } header: {
            Text("编码器")
        }
        .disabled(isDisabled)
    }

    @ViewBuilder
    private var capabilityStatus: some View {
        switch capabilityState {
        case .loading:
            HStack {
                ProgressView()
                Text("正在读取本机支持字典")
            }
            .accessibilityIdentifier("native-capability-status")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("native-capability-status")
        case .ready(let capabilities):
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent(
                    "当前硬件编码器",
                    value: capabilities.encoderID ?? "系统未返回 EncoderID"
                )
                LabeledContent(
                    "检测配置",
                    value: "\(capabilities.width)×\(capabilities.height)"
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("native-capability-status")
        }
    }

    private var rateControlSection: some View {
        Section {
            HStack {
                helpTitle(
                    "原生码率字段（互斥）",
                    title: "原生码率字段（互斥）",
                    message:
                        "此选择器本身不写入 VideoToolbox，只保证以下原生字段"
                        + "任一时刻仅显示并写入一个："
                        + "kVTCompressionPropertyKey_AverageBitRate、"
                        + "kVTCompressionPropertyKey_ConstantBitRate、"
                        + "kVTCompressionPropertyKey_VariableBitRate、"
                        + "kVTCompressionPropertyKey_Quality、"
                        + "kVTCompressionPropertyKey_ConstantQualityFactor。\n\n"
                        + "影响：一次只选一种主控制目标，避免编码器同时收到"
                        + "互相矛盾的码率或质量约束。",
                    documentationURL: URL(
                        string:
                            "https://developer.apple.com/documentation/"
                            + "videotoolbox/compression-properties"
                    )
                )
                Spacer()
                rateControlMenu
            }

            if let selectedKey = settings.selectedRateControlKey,
               let descriptor = NativeCompressionPropertyCatalog.byKey[selectedKey] {
                nativePropertyRow(descriptor)
            }

            if settings.selectedRateControlKey == "AverageBitRate",
               let descriptor =
                   NativeCompressionPropertyCatalog.byKey["DataRateLimits"] {
                nativePropertyRow(descriptor)
            }

            if settings.selectedRateControlKey == "ConstantBitRate" {
                vbvRows(includeMaximumBitRate: false)
            } else if settings.selectedRateControlKey == "VariableBitRate" {
                vbvRows(includeMaximumBitRate: true)
            }
        } header: {
            Text(NativeCompressionPropertyCategory.rateControl.title)
        }
        .disabled(isDisabled)
    }

    private var rateControlMenu: some View {
        Menu {
            Button("不设置") {
                settings.selectRateControlProperty(nil)
            }
            ForEach(
                NativeCompressionPropertyCatalog.rateControlKeys,
                id: \.self
            ) { key in
                if let descriptor =
                    NativeCompressionPropertyCatalog.byKey[key],
                   descriptor.applies(to: settings.targetCodec) {
                    Button(descriptor.title) {
                        settings.selectRateControlProperty(key)
                    }
                    .disabled(!isWritable(descriptor))
                }
            }
        } label: {
            Text(settings.selectedRateControlKey ?? "不设置")
        }
        .disabled(capabilityState.capabilities == nil)
        .accessibilityIdentifier("native-rate-control-menu")
    }

    @ViewBuilder
    private func vbvRows(includeMaximumBitRate: Bool) -> some View {
        if includeMaximumBitRate,
           let descriptor =
               NativeCompressionPropertyCatalog.byKey["VBVMaxBitRate"] {
            nativePropertyRow(descriptor)
        }
        if let descriptor =
            NativeCompressionPropertyCatalog.byKey["VBVBufferDuration"] {
            nativePropertyRow(descriptor)
        }
        if let descriptor =
            NativeCompressionPropertyCatalog
                .byKey["VBVInitialDelayPercentage"] {
            nativePropertyRow(descriptor)
        }
    }

    @ViewBuilder
    private func categorySection(
        _ category: NativeCompressionPropertyCategory
    ) -> some View {
        if category.isCollapsedByDefault {
            Section {
                DisclosureGroup(
                    isExpanded: categoryExpansionBinding(category)
                ) {
                    categoryRows(category)
                } label: {
                    Text(category.title)
                }
                .accessibilityIdentifier(
                    "native-category-\(category.rawValue)"
                )
            }
            .disabled(isDisabled)
        } else {
            Section {
                categoryRows(category)
            } header: {
                Text(category.title)
            }
            .disabled(isDisabled)
        }
    }

    @ViewBuilder
    private func categoryRows(
        _ category: NativeCompressionPropertyCategory
    ) -> some View {
        let descriptors = visibleDescriptors(in: category)
        if descriptors.isEmpty {
            Text("当前编码类型没有此类公开字段")
                .foregroundStyle(.secondary)
        } else {
            ForEach(descriptors) { descriptor in
                nativePropertyRow(descriptor)
            }
        }
    }

    private func categoryExpansionBinding(
        _ category: NativeCompressionPropertyCategory
    ) -> Binding<Bool> {
        Binding(
            get: { expandedCategories.contains(category) },
            set: { isExpanded in
                if isExpanded {
                    expandedCategories.insert(category)
                } else {
                    expandedCategories.remove(category)
                }
            }
        )
    }

    private var diagnosticsSection: some View {
        Section {
            ForEach(
                visibleDescriptors(in: .diagnostics)
            ) { descriptor in
                nativePropertyRow(descriptor)
            }
        } header: {
            Text(NativeCompressionPropertyCategory.diagnostics.title)
        }
    }

    private func visibleDescriptors(
        in category: NativeCompressionPropertyCategory
    ) -> [NativeCompressionPropertyDescriptor] {
        NativeCompressionPropertyCatalog.descriptors.filter {
            $0.category == category
                && $0.applies(to: settings.targetCodec)
                && !NativeCompressionPropertyCatalog.rateControlKeys
                    .contains($0.key)
                && $0.key != "DataRateLimits"
                && !NativeCompressionPropertyCatalog.vbvKeys.contains($0.key)
                && settings.isVisibleInNativeEditor($0)
        }
    }

    @ViewBuilder
    private func nativePropertyRow(
        _ descriptor: NativeCompressionPropertyDescriptor
    ) -> some View {
        let availability = availability(for: descriptor)
        switch availability {
        case .writable(let capability):
            writablePropertyRow(descriptor, capability: capability)
                .accessibilityIdentifier("native-property-\(descriptor.key)")
        case .loading:
            unavailableRow(descriptor, reason: "检测中")
        case .unsupported:
            unavailableRow(descriptor, reason: "本机不支持")
        case .readOnly(let capability):
            unavailableRow(
                descriptor,
                reason: "本机只读",
                capability: capability
            )
        case .notPubliclySettable(let capability):
            unavailableRow(
                descriptor,
                reason: "原生只读",
                capability: capability
            )
        }
    }

    private func unavailableRow(
        _ descriptor: NativeCompressionPropertyDescriptor,
        reason: String,
        capability: NativeCompressionPropertyCapability? = nil
    ) -> some View {
        HStack {
            descriptorTitle(
                descriptor,
                reason: reason,
                capability: capability
            )
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let readback = capability?.readback {
                    Text(readback.displayText)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                Text(reason)
                    .font(.caption2)
            }
            .disabled(true)
            .accessibilityLabel(
                "\(descriptor.key)，"
                    + "\(capability?.readback?.displayText ?? "未返回值")，"
                    + reason
            )
            .accessibilityIdentifier(
                "native-property-\(descriptor.key)"
            )
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func writablePropertyRow(
        _ descriptor: NativeCompressionPropertyDescriptor,
        capability: NativeCompressionPropertyCapability
    ) -> some View {
        switch descriptor.kind {
        case .boolean:
            HStack {
                descriptorTitle(descriptor, capability: capability)
                Spacer()
                optionalBooleanMenu(descriptor)
            }
        case .integer, .number:
            HStack {
                descriptorTitle(descriptor, capability: capability)
                Spacer()
                NativeCompressionNumberEditor(
                    value: settings.nativeProperties[descriptor.key]?.numberValue,
                    isInteger: {
                        if case .integer = descriptor.kind {
                            return true
                        }
                        return false
                    }(),
                    unit: descriptor.unit,
                    onChange: {
                        updateNumber($0, descriptor: descriptor)
                    }
                )
            }
        case .enumeration(let fallbackValues):
            HStack {
                descriptorTitle(descriptor, capability: capability)
                Spacer()
                let values = capability.supportedValues.isEmpty
                    ? fallbackValues
                    : capability.supportedValues
                if values.isEmpty {
                    NativeCompressionStringEditor(
                        value: settings.nativeProperties[descriptor.key]?.stringValue,
                        onChange: {
                            updateString($0, descriptor: descriptor)
                        }
                    )
                } else {
                    enumerationMenu(
                        descriptor,
                        values: effectiveEnumerationValues(
                            descriptor,
                            values: values
                        )
                    )
                }
            }
        case .dataRateLimits:
            dataRateLimitsEditor(descriptor)
        case .multiPassStorage:
            HStack {
                descriptorTitle(descriptor, capability: capability)
                Spacer()
                Menu {
                    Button("不设置") {
                        settings.multiPassStorageEnabled = false
                    }
                    Button("设置") {
                        settings.multiPassStorageEnabled = true
                        settings.setNativeValue(nil, forKey: "RealTime")
                        settings.setNativeValue(
                            nil,
                            forKey: "PrioritizeEncodingSpeedOverQuality"
                        )
                    }
                } label: {
                    Text(
                        settings.multiPassStorageEnabled ? "设置" : "不设置"
                    )
                }
            }
        case .base64Data:
            HStack {
                descriptorTitle(descriptor, capability: capability)
                Spacer()
                Button(
                    settings.nativeProperties[descriptor.key] == nil
                        ? "设置 Base64"
                        : "编辑 Base64"
                ) {
                    openBase64Editor(descriptor)
                }
            }
        case .json:
            HStack {
                descriptorTitle(descriptor, capability: capability)
                Spacer()
                Button(
                    settings.nativeProperties[descriptor.key] == nil
                        ? "设置 JSON"
                        : "编辑 JSON"
                ) {
                    openJSONEditor(descriptor)
                }
            }
        }
    }

    private func optionalBooleanMenu(
        _ descriptor: NativeCompressionPropertyDescriptor
    ) -> some View {
        Menu {
            Button("不设置") {
                updateBoolean(nil, descriptor: descriptor)
            }
            Button("开") {
                updateBoolean(true, descriptor: descriptor)
            }
            Button("关") {
                updateBoolean(false, descriptor: descriptor)
            }
        } label: {
            let value = settings.nativeProperties[descriptor.key]?.boolValue
            Text(value.map { $0 ? "开" : "关" } ?? "不设置")
        }
    }

    private func updateBoolean(
        _ value: Bool?,
        descriptor: NativeCompressionPropertyDescriptor
    ) {
        settings.setNativeValue(
            value.map(NativeCompressionValue.bool),
            forKey: descriptor.key
        )
        if descriptor.key == "AllowTemporalCompression", value == false {
            settings.setNativeValue(nil, forKey: "AllowFrameReordering")
            settings.setNativeValue(nil, forKey: "AllowOpenGOP")
        }
        if descriptor.key == "RealTime" && value == true
            || descriptor.key == "PrioritizeEncodingSpeedOverQuality"
                && value == true {
            settings.multiPassStorageEnabled = false
        }
        if descriptor.key == "RealTime", value != true {
            settings.setNativeValue(
                nil,
                forKey: "MaximumRealTimeFrameRate"
            )
        }
        if descriptor.key == "PreserveAlphaChannel", value == false {
            settings.setNativeValue(nil, forKey: "TargetQualityForAlpha")
            settings.setNativeValue(nil, forKey: "AlphaChannelMode")
        }
    }

    private func updateNumber(
        _ value: Double?,
        descriptor: NativeCompressionPropertyDescriptor
    ) {
        settings.setNativeValue(
            value.map(NativeCompressionValue.number),
            forKey: descriptor.key
        )
        if descriptor.key == "FieldCount", value != 2 {
            settings.setNativeValue(nil, forKey: "FieldDetail")
        }
    }

    private func enumerationMenu(
        _ descriptor: NativeCompressionPropertyDescriptor,
        values: [String]
    ) -> some View {
        Menu {
            Button("不设置") {
                settings.setNativeValue(nil, forKey: descriptor.key)
                resolveEnumerationDependencies(
                    descriptor: descriptor,
                    value: nil
                )
            }
            ForEach(values, id: \.self) { value in
                Button(value) {
                    settings.setNativeValue(.string(value), forKey: descriptor.key)
                    resolveEnumerationDependencies(
                        descriptor: descriptor,
                        value: value
                    )
                }
            }
        } label: {
            Text(
                settings.nativeProperties[descriptor.key]?.stringValue
                    ?? "不设置"
            )
            .lineLimit(1)
        }
    }

    private func effectiveEnumerationValues(
        _ descriptor: NativeCompressionPropertyDescriptor,
        values: [String]
    ) -> [String] {
        if descriptor.key == "H264EntropyMode",
           (
               settings.nativeProperties["ProfileLevel"]?.stringValue ?? ""
           ).localizedCaseInsensitiveContains("Baseline") {
            return values.filter { $0 != "CABAC" }
        }
        return values
    }

    private func updateString(
        _ value: String?,
        descriptor: NativeCompressionPropertyDescriptor
    ) {
        settings.setNativeValue(
            value.map(NativeCompressionValue.string),
            forKey: descriptor.key
        )
        resolveEnumerationDependencies(
            descriptor: descriptor,
            value: value
        )
    }

    private func resolveEnumerationDependencies(
        descriptor: NativeCompressionPropertyDescriptor,
        value: String?
    ) {
        if descriptor.key == "TransferFunction", value != "UseGamma" {
            settings.setNativeValue(nil, forKey: "GammaLevel")
        }
        if descriptor.key == "ProfileLevel",
           value?.localizedCaseInsensitiveContains("Baseline") == true,
           settings.nativeProperties["H264EntropyMode"]?.stringValue
               == "CABAC" {
            settings.setNativeValue(.string("CAVLC"), forKey: "H264EntropyMode")
        }
    }

    private func dataRateLimitsEditor(
        _ descriptor: NativeCompressionPropertyDescriptor
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                descriptorTitle(descriptor)
                Spacer()
                if settings.dataRateLimits == nil {
                    Button("设置") {
                        settings.dataRateLimits = [1_500_000, 1]
                    }
                } else {
                    Button("清除") {
                        settings.dataRateLimits = nil
                    }
                }
            }
            if let values = settings.dataRateLimits, values.count >= 2 {
                HStack {
                    Text("数据量")
                    Spacer()
                    NativeCompressionNumberEditor(
                        value: values[0],
                        isInteger: true,
                        unit: "byte",
                        onChange: { value in
                            guard let value else {
                                settings.dataRateLimits = nil
                                return
                            }
                            settings.dataRateLimits = [value, values[1]]
                        }
                    )
                }
                HStack {
                    Text("时间窗口")
                    Spacer()
                    NativeCompressionNumberEditor(
                        value: values[1],
                        isInteger: false,
                        unit: "s",
                        onChange: { value in
                            guard let value else {
                                settings.dataRateLimits = nil
                                return
                            }
                            settings.dataRateLimits = [values[0], value]
                        }
                    )
                }
                Button("编辑完整原生数组") {
                    openJSONEditor(descriptor)
                }
                .font(.caption)
            }
        }
    }

    private func descriptorTitle(
        _ descriptor: NativeCompressionPropertyDescriptor,
        reason: String? = nil,
        capability: NativeCompressionPropertyCapability? = nil
    ) -> some View {
        let supportText = reason.map { " 当前状态：\($0)。" } ?? ""
        let rangeText = supportedRangeDescription(capability)
        return helpTitle(
            descriptor.title,
            title: descriptor.title,
            message: descriptor.helpMessage + rangeText + supportText,
            documentationURL: descriptor.documentationURL
        )
    }

    private func supportedRangeDescription(
        _ capability: NativeCompressionPropertyCapability?
    ) -> String {
        guard let capability else {
            return ""
        }
        switch (capability.supportedMinimum, capability.supportedMaximum) {
        case (.some(let minimum), .some(let maximum)):
            return " 本机原生范围：\(minimum)～\(maximum)。"
        case (.some(let minimum), .none):
            return " 本机原生最小值：\(minimum)。"
        case (.none, .some(let maximum)):
            return " 本机原生最大值：\(maximum)。"
        case (.none, .none):
            return ""
        }
    }

    private func helpTitle(
        _ text: String,
        title: String,
        message: String,
        documentationURL: URL? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Text(text)
            Button {
                activeHelp = NativeCompressionHelp(
                    id: title,
                    title: title,
                    message: message,
                    documentationURL: documentationURL
                )
            } label: {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title)说明")
        }
    }

    private var codecBinding: Binding<TranscodeTargetCodec> {
        Binding(
            get: { settings.targetCodec },
            set: onCodecChange
        )
    }

    private func isWritable(
        _ descriptor: NativeCompressionPropertyDescriptor
    ) -> Bool {
        guard descriptor.isPubliclySettable,
              let capabilities = capabilityState.capabilities
        else {
            return false
        }
        return capabilities.isWritable(descriptor)
    }

    private func availability(
        for descriptor: NativeCompressionPropertyDescriptor
    ) -> NativeCompressionAvailability {
        switch capabilityState {
        case .loading:
            return .loading
        case .failed:
            return descriptor.isPubliclySettable
                ? .unsupported
                : .notPubliclySettable(nil)
        case .ready(let capabilities):
            let capability = capabilities.capability(for: descriptor)
            guard descriptor.isPubliclySettable else {
                return .notPubliclySettable(capability)
            }
            guard let capability else {
                return .unsupported
            }
            if capability.isWritable {
                return .writable(capability)
            }
            if capability.isReadOnly {
                return .readOnly(capability)
            }
            return .unsupported
        }
    }

    private func openJSONEditor(
        _ descriptor: NativeCompressionPropertyDescriptor
    ) {
        jsonDraft =
            settings.nativeProperties[descriptor.key]?.jsonText
                ?? descriptor.suggestedValue?.jsonText
                ?? "{}"
        jsonError = nil
        jsonEditor = NativeCompressionJSONEditorItem(
            descriptor: descriptor,
            format: .json
        )
    }

    private func openBase64Editor(
        _ descriptor: NativeCompressionPropertyDescriptor
    ) {
        jsonDraft =
            settings.nativeProperties[descriptor.key]?.stringValue ?? ""
        jsonError = nil
        jsonEditor = NativeCompressionJSONEditorItem(
            descriptor: descriptor,
            format: .base64
        )
    }

    private func jsonEditorView(
        _ item: NativeCompressionJSONEditorItem
    ) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.descriptor.nativeName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if item.format == .base64 {
                    Text("此处填写原生 CFData 的 Base64 文本。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextEditor(text: $jsonDraft)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .border(Color.secondary.opacity(0.3))
                if let jsonError {
                    Text(jsonError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .padding()
            .navigationTitle(item.descriptor.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        jsonEditor = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("写入") {
                        do {
                            let value: NativeCompressionValue
                            switch item.format {
                            case .json:
                                value = try NativeCompressionValue.parseJSON(
                                    jsonDraft
                                )
                            case .base64:
                                let trimmed = jsonDraft.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                )
                                guard Data(base64Encoded: trimmed) != nil else {
                                    throw NativeCompressionEditorError
                                        .invalidBase64
                                }
                                value = .string(trimmed)
                            }
                            settings.setNativeValue(
                                value,
                                forKey: item.descriptor.key
                            )
                            jsonEditor = nil
                        } catch {
                            let formatName =
                                item.format == .json ? "JSON" : "Base64"
                            jsonError =
                                "\(formatName) 无效：\(error.localizedDescription)"
                        }
                    }
                }
            }
        }
    }
}

private enum NativeCompressionAvailability {
    case loading
    case writable(NativeCompressionPropertyCapability)
    case readOnly(NativeCompressionPropertyCapability)
    case unsupported
    case notPubliclySettable(NativeCompressionPropertyCapability?)
}

private struct NativeCompressionHelp: Identifiable {
    let id: String
    let title: String
    let message: String
    let documentationURL: URL?
}

private struct NativeCompressionHelpView: View {
    @Environment(\.dismiss) private var dismiss
    let help: NativeCompressionHelp

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(help.message)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    if let documentationURL = help.documentationURL {
                        Link(destination: documentationURL) {
                            Label(
                                "查看 Apple 官方文档",
                                systemImage: "safari"
                            )
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(help.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct NativeCompressionJSONEditorItem: Identifiable {
    let descriptor: NativeCompressionPropertyDescriptor
    let format: NativeCompressionTextFormat

    var id: String { descriptor.key }
}

private enum NativeCompressionTextFormat: Equatable {
    case json
    case base64
}

private enum NativeCompressionEditorError: LocalizedError {
    case invalidBase64

    var errorDescription: String? {
        "Base64 无效。"
    }
}

private struct NativeCompressionNumberEditor: View {
    let value: Double?
    let isInteger: Bool
    let unit: String?
    let onChange: (Double?) -> Void

    @State private var text: String

    init(
        value: Double?,
        isInteger: Bool,
        unit: String?,
        onChange: @escaping (Double?) -> Void
    ) {
        self.value = value
        self.isInteger = isInteger
        self.unit = unit
        self.onChange = onChange
        _text = State(initialValue: Self.format(value, isInteger: isInteger))
    }

    var body: some View {
        HStack(spacing: 5) {
            TextField("不设置", text: $text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .frame(minWidth: 88, idealWidth: 118, maxWidth: 150)
                .onChange(of: text) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    if trimmed.isEmpty {
                        onChange(nil)
                    } else if let number = Double(
                        trimmed.replacingOccurrences(of: ",", with: "")
                    ) {
                        onChange(isInteger ? number.rounded() : number)
                    }
                }
            if let unit {
                Text(unit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: value) { _, newValue in
            let formatted = Self.format(newValue, isInteger: isInteger)
            if formatted != text,
               Double(text.replacingOccurrences(of: ",", with: ""))
                   != newValue {
                text = formatted
            }
        }
    }

    private static func format(_ value: Double?, isInteger: Bool) -> String {
        guard let value else {
            return ""
        }
        if isInteger {
            return String(format: "%.0f", value)
        }
        return String(format: "%.4g", value)
    }
}

private struct NativeCompressionStringEditor: View {
    let value: String?
    let onChange: (String?) -> Void

    @State private var text: String

    init(
        value: String?,
        onChange: @escaping (String?) -> Void
    ) {
        self.value = value
        self.onChange = onChange
        _text = State(initialValue: value ?? "")
    }

    var body: some View {
        TextField("不设置", text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .multilineTextAlignment(.trailing)
            .frame(minWidth: 120, idealWidth: 180, maxWidth: 220)
            .onChange(of: text) { _, newValue in
                let trimmed = newValue.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                onChange(trimmed.isEmpty ? nil : trimmed)
            }
            .onChange(of: value) { _, newValue in
                let updated = newValue ?? ""
                if updated != text {
                    text = updated
                }
            }
    }
}
