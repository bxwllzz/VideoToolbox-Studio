import Combine
import Foundation

@MainActor
final class CapabilityProbeStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case running
        case completed
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var report: CapabilityReport?
    @Published private(set) var exportURL: URL?

    func run(buildReport: BuildReport) {
        guard phase != .running else {
            return
        }

        phase = .running
        report = nil
        exportURL = nil

        Task {
            let report = await Task.detached(priority: .userInitiated) {
                VideoToolboxProbe.run(buildReport: buildReport)
            }.value

            do {
                exportURL = try CapabilityReportExporter.write(report)
                self.report = report
                phase = .completed
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
