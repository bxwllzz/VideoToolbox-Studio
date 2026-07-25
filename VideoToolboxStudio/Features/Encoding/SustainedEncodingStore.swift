import Combine
import Foundation

@MainActor
final class SustainedEncodingStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case completed
        case cancelled
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var report: SustainedEncodingReport?
    @Published private(set) var exportURL: URL?

    private var task: Task<Void, Never>?
    private var cancellationToken: EncodingCancellationToken?

    func run(buildReport: BuildReport) {
        guard phase != .running else {
            return
        }

        let token = EncodingCancellationToken()
        cancellationToken = token
        phase = .running
        report = nil
        exportURL = nil

        task = Task {
            let report = await Task.detached(priority: .userInitiated) {
                SustainedEncodingProbe.run(
                    buildReport: buildReport,
                    cancellationToken: token
                )
            }.value

            guard !Task.isCancelled else {
                return
            }

            do {
                exportURL = try SustainedEncodingReportExporter.write(report)
                self.report = report
                phase = report.cancelled ? .cancelled : .completed
            } catch {
                phase = .failed(error.localizedDescription)
            }
            task = nil
            cancellationToken = nil
        }
    }

    func cancel() {
        cancellationToken?.cancel()
    }
}
