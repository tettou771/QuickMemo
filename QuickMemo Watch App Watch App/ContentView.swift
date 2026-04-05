import SwiftUI
import WatchConnectivity

struct ContentView: View {
    @State private var text = ""
    @State private var saved = false
    @State private var sending = false
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // Tap to open system dictation/input
                TextField("タップして入力", text: $text, axis: .vertical)
                    .lineLimit(3...10)

                // Save buttons — always visible
                HStack(spacing: 16) {
                    ForEach(MemoCategory.allCases) { category in
                        Button {
                            send(category: category)
                        } label: {
                            Text(category.emoji)
                                .font(.system(size: 28))
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(text.isEmpty || sending)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .overlay {
            if saved {
                VStack {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.green)
                    Text("保存完了")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.8))
                .transition(.opacity)
            }
        }
        .animation(.default, value: saved)
    }

    private func send(category: MemoCategory) {
        print("[Watch] send tapped, category: \(category.rawValue)")
        print("[Watch] session activated: \(WCSession.default.activationState.rawValue)")
        print("[Watch] isReachable: \(WCSession.default.isReachable)")

        guard WCSession.default.isReachable else {
            errorMessage = "iPhoneに接続できません"
            WKInterfaceDevice.current().play(.failure)
            return
        }

        sending = true
        let message: [String: Any] = [
            "text": text,
            "category": category.rawValue,
            "timestamp": Date().timeIntervalSince1970
        ]

        print("[Watch] sending message...")
        WCSession.default.sendMessage(message, replyHandler: { reply in
            print("[Watch] got reply: \(reply)")
            DispatchQueue.main.async {
                sending = false
                if let success = reply["success"] as? Bool, success {
                    saved = true
                    WKInterfaceDevice.current().play(.success)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        saved = false
                        text = ""
                    }
                } else {
                    errorMessage = reply["error"] as? String ?? "保存に失敗しました"
                    WKInterfaceDevice.current().play(.failure)
                }
            }
        }, errorHandler: { error in
            print("[Watch] send error: \(error)")
            DispatchQueue.main.async {
                sending = false
                errorMessage = "送信エラー: \(error.localizedDescription)"
                WKInterfaceDevice.current().play(.failure)
            }
        })
    }
}
