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

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }

    // MARK: - Receive from Watch

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard
            let text = message["text"] as? String,
            let categoryRaw = message["category"] as? String,
            let category = MemoCategory(rawValue: categoryRaw)
        else {
            replyHandler(["success": false, "error": "不正なデータ"])
            return
        }

        Task {
            do {
                try await WebDAVService.shared.saveMemo(text: text, category: category)
                replyHandler(["success": true])
            } catch {
                replyHandler(["success": false, "error": error.localizedDescription])
            }
        }
    }
}
