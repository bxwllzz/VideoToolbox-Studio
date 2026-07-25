import Combine
import Foundation

@MainActor
final class InstallationState: ObservableObject {
    @Published private(set) var installationIdentifier: String
    @Published private(set) var launchCount: Int

    private enum Keys {
        static let installationIdentifier = "installation.identifier"
        static let launchCount = "installation.launchCount"
    }

    init(defaults: UserDefaults = .standard) {
        if let existingIdentifier = defaults.string(forKey: Keys.installationIdentifier) {
            installationIdentifier = existingIdentifier
        } else {
            let newIdentifier = UUID().uuidString
            defaults.set(newIdentifier, forKey: Keys.installationIdentifier)
            installationIdentifier = newIdentifier
        }

        let nextLaunchCount = defaults.integer(forKey: Keys.launchCount) + 1
        defaults.set(nextLaunchCount, forKey: Keys.launchCount)
        launchCount = nextLaunchCount
    }
}
