import Photos
import PhotosUI
import SwiftUI
import UIKit

struct VideoLibraryView: View {
    let buildReport: BuildReport

    @Environment(\.openURL) private var openURL
    @StateObject private var store = PhotoVideoLibraryStore()
    @State private var isSelecting = false
    @State private var selectedIDs: Set<String> = []
    @State private var preparedSelection: PreparedVideoSelection?
    @State private var preparationTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var showLimitedLibraryPicker = false

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    var body: some View {
        Group {
            if store.isLoading {
                ProgressView("正在读取视频")
            } else if !store.canReadLibrary {
                permissionView
            } else if store.items.isEmpty {
                ContentUnavailableView(
                    "没有可用视频",
                    systemImage: "video.slash",
                    description: Text(
                        store.authorizationStatus == .limited
                            ? "当前照片权限范围内没有视频，可到系统设置增加允许的项目。"
                            : "照片 App 中的视频会显示在这里。"
                    )
                )
            } else {
                videoGrid
            }
        }
        .navigationTitle(isSelecting ? "已选择 \(selectedIDs.count) 项" : "视频")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if store.canReadLibrary, !store.items.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSelecting ? "取消" : "选择") {
                        isSelecting.toggle()
                        if !isSelecting {
                            selectedIDs.removeAll()
                        }
                    }
                    .disabled(store.preparationProgress != nil)
                }
            }

            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selectedIDs.count == store.items.count ? "取消全选" : "全选") {
                        if selectedIDs.count == store.items.count {
                            selectedIDs.removeAll()
                        } else {
                            selectedIDs = Set(store.items.map(\.id))
                        }
                    }
                    .disabled(store.preparationProgress != nil)
                }
            } else if store.authorizationStatus == .limited {
                ToolbarItem(placement: .topBarLeading) {
                    Button("管理照片") {
                        showLimitedLibraryPicker = true
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                selectionBar
            }
        }
        .navigationDestination(item: $preparedSelection) { selection in
            TranscodeView(
                buildReport: buildReport,
                sources: selection.sources
            )
        }
        .overlay {
            if let progress = store.preparationProgress {
                preparationOverlay(progress: progress)
            } else if let cloudTestSeedError = store.cloudTestSeedError {
                Label(
                    cloudTestSeedError,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.red)
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("photo-library-seed-error")
            }
        }
        .background {
            LimitedLibraryPickerPresenter(
                isPresented: $showLimitedLibraryPicker
            )
            .frame(width: 0, height: 0)
        }
        .alert(
            "无法读取视频",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            await store.requestAccessAndLoad()
        }
        .onChange(of: store.items.map(\.id)) { _, currentIDs in
            selectedIDs.formIntersection(Set(currentIDs))
            if currentIDs.isEmpty {
                isSelecting = false
            }
        }
    }

    private var videoGrid: some View {
        let selectionIndices = selectionIndexMap

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(store.sections) { section in
                    Section {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(section.items) { item in
                                Button {
                                    select(item)
                                } label: {
                                    VideoLibraryCell(
                                        item: item,
                                        isSelecting: isSelecting,
                                        selectionIndex: selectionIndices[item.id]
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("video-library-item")
                                .accessibilityHint(
                                    isSelecting
                                        ? "双击切换选择状态"
                                        : "双击进入视频转换设置"
                                )
                            }
                        }
                    } header: {
                        Text(sectionTitle(section.day))
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(.bar)
                    }
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var selectionBar: some View {
        HStack {
            Text("已选择 \(selectedIDs.count) 项")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                prepare(Array(selectedIDs))
            } label: {
                Text("下一步")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedIDs.isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var permissionView: some View {
        ContentUnavailableView {
            Label("需要照片权限", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("用于在主界面显示相册视频，并在你选择后进行本地转换。")
        } actions: {
            if store.authorizationStatus == .notDetermined {
                Button("允许访问照片") {
                    Task {
                        await store.requestAccessAndLoad()
                    }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("打开系统设置") {
                    openAppSettings()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func preparationOverlay(progress: Double) -> some View {
        ZStack {
            Color.black.opacity(0.25)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                Text(store.preparationTitle ?? "正在准备视频")
                    .font(.headline)
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("取消", role: .cancel) {
                    preparationTask?.cancel()
                }
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private func select(_ item: PhotoVideoItem) {
        if isSelecting {
            if selectedIDs.contains(item.id) {
                selectedIDs.remove(item.id)
            } else {
                selectedIDs.insert(item.id)
            }
        } else {
            prepare([item.id])
        }
    }

    private func prepare(_ ids: [String]) {
        guard preparationTask == nil, !ids.isEmpty else {
            return
        }

        let selectedIDSet = Set(ids)
        let orderedIDs = store.items
            .filter { selectedIDSet.contains($0.id) }
            .map(\.id)
        preparationTask = Task {
            do {
                let sources = try await store.prepareVideos(ids: orderedIDs)
                try Task.checkCancellation()
                preparedSelection = PreparedVideoSelection(sources: sources)
                isSelecting = false
                selectedIDs.removeAll()
            } catch is CancellationError {
                // 用户主动取消，不显示错误。
            } catch {
                errorMessage = error.localizedDescription
            }
            preparationTask = nil
        }
    }

    private var selectionIndexMap: [String: Int] {
        var result: [String: Int] = [:]
        result.reserveCapacity(selectedIDs.count)
        var nextIndex = 1
        for item in store.items where selectedIDs.contains(item.id) {
            result[item.id] = nextIndex
            nextIndex += 1
        }
        return result
    }

    private func sectionTitle(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) {
            return "今天"
        }
        if calendar.isDateInYesterday(date) {
            return "昨天"
        }
        return date.formatted(
            Date.FormatStyle()
                .year()
                .month(.abbreviated)
                .day()
                .locale(Locale.autoupdatingCurrent)
        )
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        openURL(url)
    }
}

private struct PreparedVideoSelection: Identifiable, Hashable {
    let id = UUID()
    let sources: [TranscodeSource]

    static func == (
        lhs: PreparedVideoSelection,
        rhs: PreparedVideoSelection
    ) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private struct VideoLibraryCell: View {
    let item: PhotoVideoItem
    let isSelecting: Bool
    let selectionIndex: Int?

    @Environment(\.displayScale) private var displayScale
    @StateObject private var model: PhotoVideoCellModel

    init(
        item: PhotoVideoItem,
        isSelecting: Bool,
        selectionIndex: Int?
    ) {
        self.item = item
        self.isSelecting = isSelecting
        self.selectionIndex = selectionIndex
        _model = StateObject(
            wrappedValue: PhotoVideoCellModel(asset: item.asset)
        )
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(uiColor: .secondarySystemBackground))

            if let image = model.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView()
            }

            metadataOverlay

            if isSelecting {
                selectionIndicator
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .contentShape(Rectangle())
        .task(id: item.id) {
            model.load(
                targetSize: CGSize(
                    width: 180 * displayScale,
                    height: 180 * displayScale
                )
            )
        }
        .onDisappear {
            model.cancelThumbnailRequest()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selectionIndex == nil ? [] : .isSelected)
    }

    private var metadataOverlay: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    metadataText(fileSizeText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    metadataText(codecText)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                HStack(spacing: 4) {
                    metadataText("\(item.pixelWidth)×\(item.pixelHeight)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    metadataText(bitRateText)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 5)
            .padding(.top, 16)
            .padding(.bottom, 5)
            .background(
                LinearGradient(
                    colors: [.clear, .black.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var selectionIndicator: some View {
        ZStack {
            Circle()
                .fill(
                    selectionIndex == nil
                        ? Color.black.opacity(0.45)
                        : Color.accentColor
                )
            Circle()
                .stroke(.white, lineWidth: 1.5)
            if let selectionIndex {
                Text("\(selectionIndex)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 24, height: 24)
    }

    private func metadataText(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit().weight(.medium))
            .lineLimit(1)
            .allowsTightening(true)
            .minimumScaleFactor(0.65)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.8), radius: 1, y: 1)
    }

    private var fileSizeText: String {
        guard let size = model.metadata?.fileSize else {
            return model.metadataUnavailable ? "iCloud" : "…"
        }
        let formatted = ByteCountFormatter.string(
            fromByteCount: size,
            countStyle: .file
        )
        return model.metadata?.isFileSizeEstimated == true
            ? "≈\(formatted)"
            : formatted
    }

    private var codecText: String {
        model.metadata?.codec
            ?? (model.metadataUnavailable ? "云端" : "…")
    }

    private var bitRateText: String {
        guard let bitRate = model.metadata?.bitRate else {
            return model.metadataUnavailable ? "待下载" : "…"
        }
        if bitRate >= 1_000_000 {
            return String(format: "%.1f Mb/s", bitRate / 1_000_000)
        }
        return String(format: "%.0f kb/s", bitRate / 1_000)
    }

    private var accessibilityLabel: String {
        [
            "视频",
            fileSizeText,
            "\(item.pixelWidth)乘\(item.pixelHeight)",
            codecText,
            bitRateText,
        ].joined(separator: "，")
    }
}

private struct LimitedLibraryPickerPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(
        _ viewController: UIViewController,
        context: Context
    ) {
        guard isPresented,
              !context.coordinator.isPresenting,
              viewController.presentedViewController == nil
        else {
            return
        }
        context.coordinator.isPresenting = true

        DispatchQueue.main.async {
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(
                from: viewController
            ) { _ in
                isPresented = false
                context.coordinator.isPresenting = false
            }
        }
    }

    final class Coordinator {
        var isPresenting = false
    }
}
