import Foundation

enum BuildReportExportError: LocalizedError {
    case encodeFailed(Error)
    case writeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .encodeFailed(let error):
            return "无法生成构建报告：\(error.localizedDescription)"
        case .writeFailed(let error):
            return "无法保存构建报告：\(error.localizedDescription)"
        }
    }
}

enum BuildReportExporter {
    static func write(_ report: BuildReport) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let data: Data
        do {
            data = try encoder.encode(report)
        } catch {
            throw BuildReportExportError.encodeFailed(error)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoToolboxStudio", isDirectory: true)
        let fileURL = directory.appendingPathComponent("build-info.json")

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw BuildReportExportError.writeFailed(error)
        }

        return fileURL
    }
}
