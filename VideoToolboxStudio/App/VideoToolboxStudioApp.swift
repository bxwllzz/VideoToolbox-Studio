import SwiftUI

@main
struct VideoToolboxStudioApp: App {
    @StateObject private var installationState = InstallationState()

    var body: some Scene {
        WindowGroup {
            HomeView(installationState: installationState)
        }
    }
}
