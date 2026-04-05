import SwiftUI

@main
struct QuickMemoApp: App {
    init() {
        WatchSessionManager.shared.activate()
        LocationManager.shared.startFetching()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
