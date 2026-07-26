import Combine
import Foundation

struct TranscodeQueueJob: Identifiable {
    enum State: Equatable {
        case queued
        case running(Double)
        case completed
        case cancelled
        case failed(String)
    }

    let id: UUID
    let sourceURL: URL
    var state: State
    var result: TranscodeResult?

    init(sourceURL: URL) {
        id = UUID()
        self.sourceURL = sourceURL
        state = .queued
        result = nil
    }
}

@MainActor
final class TranscodeQueueStore: ObservableObject {
    @Published var selectedPreset: TranscodePreset = .balanced
    @Published var settings = TranscodePreset.balanced.settings
    @Published private(set) var jobs: [TranscodeQueueJob] = []
    @Published private(set) var isRunning = false

    private var task: Task<Void, Never>?
    private var cancellationToken: EncodingCancellationToken?

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

    func applyPreset(_ preset: TranscodePreset) {
        selectedPreset = preset
        if preset != .custom {
            settings = preset.settings
        }
    }

    func markCustom() {
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
        let existing = Set(jobs.map(\.sourceURL))
        let additions = urls
            .filter { !existing.contains($0) }
            .map(TranscodeQueueJob.init(sourceURL:))
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
            case .queued, .running:
                false
            }
        }
    }

    func start(buildReport: BuildReport) {
        guard !isRunning, queuedCount > 0 else {
            return
        }
        isRunning = true
        let requestedSettings = settings

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
                guard let sourceURL = jobs.first(where: { $0.id == jobID })?.sourceURL else {
                    continue
                }

                let token = EncodingCancellationToken()
                cancellationToken = token
                setState(.running(0), for: jobID)

                do {
                    let worker = Task.detached(priority: .userInitiated) {
                        try await VideoTranscoder.transcode(
                            sourceURL: sourceURL,
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
        jobs[index].state = .completed
    }
}
