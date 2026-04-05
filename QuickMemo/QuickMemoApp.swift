import SwiftUI

@main
struct QuickMemoApp: App {
    init() {
        WatchSessionManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
