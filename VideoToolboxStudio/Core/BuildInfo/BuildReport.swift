import Foundation
import UIKit

struct BuildReport: Codable, Equatable {
    let schemaVersion: String
    let appName: String
    let appVersion: String
    let buildNumber: String
    let commitSHA: String
    let builtAt: String
    let buildRunID: String
    let deviceIdentifier: String
    let deviceModel: String
    let systemName: String
    let systemVersion: String
    let installationIdentifier: String
    let launchCount: Int
    let exportedAt: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case appName = "app_name"
        case appVersion = "app_version"
        case buildNumber = "build_number"
        case commitSHA = "commit_sha"
        case builtAt = "built_at"
        case buildRunID = "build_run_id"
        case deviceIdentifier = "device_identifier"
        case deviceModel = "device_model"
        case systemName = "system_name"
        case systemVersion = "system_version"
        case installationIdentifier = "installation_identifier"
        case launchCount = "launch_count"
        case exportedAt = "exported_at"
    }

    @MainActor
    static func current(
        installationIdentifier: String,
        launchCount: Int,
        bundle: Bundle = .main,
        device: UIDevice = .current,
        now: Date = Date()
    ) -> BuildReport {
        BuildReport(
            schemaVersion: "1.0",
            appName: bundleString("CFBundleDisplayName", bundle: bundle, fallback: "VideoToolbox Studio"),
            appVersion: bundleString("CFBundleShortVersionString", bundle: bundle),
            buildNumber: bundleString("CFBundleVersion", bundle: bundle),
            commitSHA: bundleString("BuildCommit", bundle: bundle, fallback: "local"),
            builtAt: bundleString("BuildTimestamp", bundle: bundle),
            buildRunID: bundleString("BuildRunID", bundle: bundle, fallback: "local"),
            deviceIdentifier: DeviceInfo.identifier,
            deviceModel: device.model,
            systemName: device.systemName,
            systemVersion: device.systemVersion,
            installationIdentifier: installationIdentifier,
            launchCount: launchCount,
            exportedAt: ISO8601DateFormatter().string(from: now)
        )
    }

    private static func bundleString(
        _ key: String,
        bundle: Bundle,
        fallback: String = "unknown"
    ) -> String {
        guard
            let value = bundle.object(forInfoDictionaryKey: key) as? String,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return fallback
        }
        return value
    }
}
