import Foundation
import XCTest
@testable import VideoToolboxStudio

final class BuildReportTests: XCTestCase {
    func testBuildReportCanRoundTripJSON() throws {
        let report = makeReport()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(report)
        let decoded = try JSONDecoder().decode(BuildReport.self, from: data)
        XCTAssertEqual(decoded, report)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object["schema_version"] as? String, "1.0")
        XCTAssertEqual(object["commit_sha"] as? String, "0123456789abcdef")
        XCTAssertNil(object["apple_account"])
        XCTAssertNil(object["media_path"])
    }

    func testBuildReportExporterWritesExpectedFile() throws {
        let fileURL = try BuildReportExporter.write(makeReport())
        defer {
            XCTAssertNoThrow(try FileManager.default.removeItem(at: fileURL))
        }

        XCTAssertEqual(fileURL.lastPathComponent, "build-info.json")
        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(BuildReport.self, from: data)
        XCTAssertEqual(decoded.commitSHA, "0123456789abcdef")
    }

    private func makeReport() -> BuildReport {
        BuildReport(
            schemaVersion: "1.0",
            appName: "VideoToolbox Studio",
            appVersion: "1.0.0",
            buildNumber: "42",
            commitSHA: "0123456789abcdef",
            builtAt: "2026-07-25T12:00:00Z",
            buildRunID: "123456",
            deviceIdentifier: "iPhone18,1",
            deviceModel: "iPhone",
            systemName: "iOS",
            systemVersion: "26.5.2",
            installationIdentifier: "test-installation",
            launchCount: 2,
            exportedAt: "2026-07-25T12:01:00Z"
        )
    }
}
