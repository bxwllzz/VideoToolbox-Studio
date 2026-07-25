import Foundation

enum SustainedEncodingReportExporter {
    static func write(_ report: SustainedEncodingReport) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sustained-encoding-report.json", isDirectory: false)
        try encoder.encode(report).write(to: outputURL, options: .atomic)
        return outputURL
    }
}
