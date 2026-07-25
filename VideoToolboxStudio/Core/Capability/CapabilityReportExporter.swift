import Foundation

enum CapabilityReportExporter {
    static func write(_ report: CapabilityReport) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("capability-report.json", isDirectory: false)
        try encoder.encode(report).write(to: outputURL, options: .atomic)
        return outputURL
    }
}
