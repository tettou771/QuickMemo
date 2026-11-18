import SwiftUI

@main
struct QuickMemoApp: App {
    init() {
        WatchSessionManager.shared.activate()
        LocationManager.shared.startTracking()
        // Retry anything that failed to upload in a previous session
        Task { await PendingMemoStore.shared.flush() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
