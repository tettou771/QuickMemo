import WatchConnectivity

class WatchSessionManager: NSObject, WCSessionDelegate {
    static let shared = WatchSessionManager()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    // Receive config from iPhone
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        if userInfo["type"] as? String == "webdav_config" {
            WatchWebDAVService.shared.applyConfig(userInfo)
            print("[Watch] WebDAV config received from iPhone")
            // Config may have been the reason uploads were failing
            Task {
                await PendingMemoStore.shared.clearBlock()
                await PendingMemoStore.shared.flush()
            }
        }
    }
}
