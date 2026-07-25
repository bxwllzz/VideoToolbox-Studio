import Foundation

struct TranscodeMetrics: Codable, Equatable, Sendable {
    let decodedVideoFrames: Int
    let submittedVideoFrames: Int
    let encodedVideoFrames: Int
    let droppedVideoFrames: Int
    let copiedNonVideoSamples: Int
    let wallClockSeconds: Double
    let sourceDurationSeconds: Double
    let processingFramesPerSecond: Double
    let inputBytes: Int64
    let outputBytes: Int64
    let outputToInputSizeRatio: Double
}

struct TranscodeReport: Encodable, Sendable {
    let schemaVersion: String
    let generatedAt: String
    let app: AppIdentity
    let device: DeviceIdentity
    let sourceFileName: String
    let outputFileName: String
    let requestedSettings: TranscodeSettings
    let resolvedSettings: ResolvedTranscodeSettings
    let input: MediaAssetSummary
    let output: MediaAssetSummary
    let propertyWrites: [PropertyWriteResult]
    let hardwarePropertyQuery: APICallResult
    let usesHardwareEncoder: Bool
    let metrics: TranscodeMetrics
    let preservationChecks: [PreservationCheck]
    let thermalStateBefore: String
    let thermalStateAfter: String

    var preservationPassed: Bool {
        preservationChecks.allSatisfy(\.passed)
    }
}

struct TranscodeResult: Sendable {
    let outputURL: URL
    let reportURL: URL
    let report: TranscodeReport
}

enum TranscodeReportExporter {
    static func write(
        _ report: TranscodeReport,
        beside outputURL: URL
    ) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let reportName = outputURL.deletingPathExtension().lastPathComponent
            + "-report.json"
        let reportURL = outputURL
            .deletingLastPathComponent()
            .appendingPathComponent(reportName)
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        return reportURL
    }
}
