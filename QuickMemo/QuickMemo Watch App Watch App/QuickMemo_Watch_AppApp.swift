import SwiftUI

@main
struct QuickMemo_Watch_App_Watch_AppApp: App {
    init() {
        WatchSessionManager.shared.activate()
        WatchLocationManager.shared.startTracking()
        // Retry anything that failed to upload in a previous session
        Task { await PendingMemoStore.shared.flush() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
