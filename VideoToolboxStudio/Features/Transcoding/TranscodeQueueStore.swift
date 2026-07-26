import Combine
import Foundation

enum TranscodePhotoSaveState: Equatable {
    case notRequested
    case saving
    case saved(String)
    case failed(String)
}

enum TranscodeSourceDeletionState: Equatable {
    case available
    case deleting
    case deleted
    case failed(String)
}

enum TranscodeEstimateState: Equatable {
    case idle
    case running(Double)
    case ready(TranscodeSizeEstimate)
    case failed(String)
}

struct TranscodeQueueJob: Identifiable {
    enum State: Equatable {
        case queued
        case running(Double)
        case savingToPhotos
        case completed
        case cancelled
        case failed(String)
    }

    let id: UUID
    let source: TranscodeSource
    var state: State
    var result: TranscodeResult?
    var photoSaveState: TranscodePhotoSaveState
    var sourceDeletionState: TranscodeSourceDeletionState

    init(source: TranscodeSource) {
        id = UUID()
        self.source = source
        state = .queued
        result = nil
        photoSaveState = .notRequested
        sourceDeletionState = source.photoLibraryAssetIdentifier == nil
            ? .deleted
            : .available
    }
}

@MainActor
final class TranscodeQueueStore: ObservableObject {
    @Published var selectedPreset: TranscodePreset = .balanced
    @Published var settings = TranscodePreset.balanced.settings
    @Published var automaticallySaveToPhotoLibrary = true
    @Published private(set) var jobs: [TranscodeQueueJob] = []
    @Published private(set) var isRunning = false
    @Published private(set) var estimateState: TranscodeEstimateState = .idle

    private var task: Task<Void, Never>?
    private var cancellationToken: EncodingCancellationToken?
    private var estimateTask: Task<Void, Never>?
    private var estimateCancellationToken: EncodingCancellationToken?

    init(initialSources: [TranscodeSource] = []) {
        jobs = initialSources.map(TranscodeQueueJob.init(source:))
    }

    convenience init(initialURLs: [URL]) {
        self.init(initialSources: initialURLs.map(TranscodeSource.localFile))
    }

    var queuedCount: Int {
        jobs.filter {
            if case .queued = $0.state {
                return true
            }
            return false
        }.count
    }

    var completedCount: Int {
        jobs.filter {
            if case .completed = $0.state {
                return true
            }
            return false
        }.count
    }

    var isEstimating: Bool {
        if case .running = estimateState {
            return true
        }
        return false
    }

    func applyPreset(_ preset: TranscodePreset) {
        cancelEstimate()
        selectedPreset = preset
        if preset != .custom {
            settings = preset.settings
        }
    }

    func markCustom() {
        cancelEstimate()
        if selectedPreset != .custom {
            selectedPreset = .custom
        }
    }

    func add(_ urls: [URL], replaceQueue: Bool) {
        guard !isRunning else {
            return
        }
        if replaceQueue {
            jobs.removeAll()
        }
        let existing = Set(jobs.map(\.source.id))
        let additions = urls
            .map(TranscodeSource.localFile)
            .filter { !existing.contains($0.id) }
            .map(TranscodeQueueJob.init(source:))
        jobs.append(contentsOf: additions)
    }

    func remove(_ id: UUID) {
        guard !isRunning else {
            return
        }
        jobs.removeAll { $0.id == id }
    }

    func clearFinished() {
        guard !isRunning else {
            return
        }
        jobs.removeAll {
            switch $0.state {
            case .completed, .cancelled, .failed:
                true
            case .queued, .running, .savingToPhotos:
                false
            }
        }
    }

    func start(buildReport: BuildReport) {
        guard !isRunning, !isEstimating, queuedCount > 0 else {
            return
        }
        estimateTask?.cancel()
        estimateCancellationToken?.cancel()
        estimateState = .idle
        isRunning = true
        let requestedSettings = settings
        let shouldAutomaticallySave = automaticallySaveToPhotoLibrary

        task = Task {
            for jobID in jobs.compactMap({
                if case .queued = $0.state {
                    return $0.id
                }
                return nil
            }) {
                if Task.isCancelled {
                    setState(.cancelled, for: jobID)
                    break
                }
                guard let source = jobs.first(where: { $0.id == jobID })?.source else {
                    continue
                }

                let token = EncodingCancellationToken()
                cancellationToken = token
                setState(.running(0), for: jobID)

                do {
                    let worker = Task.detached(priority: .userInitiated) {
                        try await VideoTranscoder.transcode(
                            source: source,
                            settings: requestedSettings,
                            buildReport: buildReport,
                            cancellationToken: token
                        ) { [weak self] value in
                            Task { @MainActor in
                                self?.setProgress(value, for: jobID)
                            }
                        }
                    }
                    let result = try await withTaskCancellationHandler {
                        try await worker.value
                    } onCancel: {
                        token.cancel()
                        worker.cancel()
                    }
                    guard !Task.isCancelled else {
                        token.cancel()
                        setState(.cancelled, for: jobID)
                        break
                    }
                    setResult(result, for: jobID)
                    if shouldAutomaticallySave {
                        setState(.savingToPhotos, for: jobID)
                        await saveResultToPhotoLibrary(for: jobID)
                    }
                    setState(.completed, for: jobID)
                } catch is CancellationError {
                    setState(.cancelled, for: jobID)
                    break
                } catch let error as TranscodeError where error == .cancelled {
                    setState(.cancelled, for: jobID)
                    break
                } catch {
                    setState(.failed(error.localizedDescription), for: jobID)
                }
                cancellationToken = nil
            }

            cancellationToken = nil
            isRunning = false
            task = nil
        }
    }

    func cancel() {
        cancellationToken?.cancel()
        task?.cancel()
    }

    func estimateFirstOutput() {
        guard !isRunning,
              !isEstimating,
              let source = jobs.first?.source
        else {
            return
        }

        let requestedSettings = settings
        let token = EncodingCancellationToken()
        estimateCancellationToken = token
        estimateState = .running(0)
        estimateTask = Task {
            do {
                let worker = Task.detached(priority: .userInitiated) {
                    try await VideoTranscoder.estimateOutputSize(
                        source: source,
                        settings: requestedSettings,
                        cancellationToken: token
                    ) { [weak self] value in
                        Task { @MainActor in
                            guard case .running = self?.estimateState else {
                                return
                            }
                            self?.estimateState = .running(
                                min(1, max(0, value))
                            )
                        }
                    }
                }
                let estimate = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    token.cancel()
                    worker.cancel()
                }
                guard !Task.isCancelled else {
                    estimateState = .idle
                    return
                }
                estimateState = .ready(estimate)
            } catch is CancellationError {
                estimateState = .idle
            } catch let error as TranscodeError where error == .cancelled {
                estimateState = .idle
            } catch {
                estimateState = .failed(error.localizedDescription)
            }
            estimateCancellationToken = nil
            estimateTask = nil
        }
    }

    func cancelEstimate() {
        estimateCancellationToken?.cancel()
        estimateTask?.cancel()
        estimateCancellationToken = nil
        estimateTask = nil
        estimateState = .idle
    }

    func saveToPhotoLibrary(_ id: UUID) {
        guard !isRunning,
              let job = jobs.first(where: { $0.id == id }),
              job.result != nil
        else {
            return
        }
        switch job.photoSaveState {
        case .saving, .saved:
            return
        case .notRequested, .failed:
            break
        }

        Task {
            await saveResultToPhotoLibrary(for: id)
        }
    }

    func deleteOriginal(_ id: UUID) {
        guard !isRunning,
              let index = jobs.firstIndex(where: { $0.id == id }),
              let sourceIdentifier =
                jobs[index].source.photoLibraryAssetIdentifier,
              case .saved = jobs[index].photoSaveState
        else {
            return
        }
        switch jobs[index].sourceDeletionState {
        case .deleting, .deleted:
            return
        case .available, .failed:
            break
        }

        jobs[index].sourceDeletionState = .deleting
        Task {
            do {
                try await PhotoLibraryOutputManager.deleteAsset(
                    localIdentifier: sourceIdentifier
                )
                setSourceDeletionState(.deleted, for: id)
            } catch {
                setSourceDeletionState(
                    .failed(error.localizedDescription),
                    for: id
                )
            }
        }
    }

    private func setProgress(_ value: Double, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              case .running = jobs[index].state
        else {
            return
        }
        jobs[index].state = .running(min(1, max(0, value)))
    }

    private func setState(_ state: TranscodeQueueJob.State, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        jobs[index].state = state
    }

    private func setResult(_ result: TranscodeResult, for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        jobs[index].result = result
    }

    private func saveResultToPhotoLibrary(for id: UUID) async {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              let result = jobs[index].result
        else {
            return
        }
        let creationDate = jobs[index].source.creationDate
        jobs[index].photoSaveState = .saving
        do {
            let savedIdentifier = try await PhotoLibraryOutputManager.saveVideo(
                at: result.outputURL,
                creationDate: creationDate
            )
            setPhotoSaveState(.saved(savedIdentifier), for: id)
        } catch {
            setPhotoSaveState(.failed(error.localizedDescription), for: id)
        }
    }

    private func setPhotoSaveState(
        _ state: TranscodePhotoSaveState,
        for id: UUID
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        jobs[index].photoSaveState = state
    }

    private func setSourceDeletionState(
        _ state: TranscodeSourceDeletionState,
        for id: UUID
    ) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            return
        }
        jobs[index].sourceDeletionState = state
    }
}
