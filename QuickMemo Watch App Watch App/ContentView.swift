import SwiftUI
import WatchConnectivity

struct ContentView: View {
    @State private var text = ""
    @State private var showDictation = false
    @State private var saved = false
    @State private var sending = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            if text.isEmpty {
                Button {
                    showDictation = true
                } label: {
                    Label("話す", systemImage: "mic.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderedProminent)
            } else {
                ScrollView {
                    Text(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)

                // Save buttons
                HStack(spacing: 20) {
                    ForEach(MemoCategory.allCases) { category in
                        Button {
                            send(category: category)
                        } label: {
                            Text(category.emoji)
                                .font(.system(size: 32))
                        }
                        .buttonStyle(.plain)
                        .disabled(sending)
                    }
                }

                Button("やり直す") {
                    text = ""
                    errorMessage = nil
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .sheet(isPresented: $showDictation) {
            DictationView(text: $text)
        }
        .overlay {
            if saved {
                VStack {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("保存しました")
                        .font(.caption)
                }
                .transition(.opacity)
            }
        }
        .animation(.default, value: saved)
    }

    private func send(category: MemoCategory) {
        guard WCSession.default.isReachable else {
            errorMessage = "iPhoneに接続できません"
            return
        }

        sending = true
        let message: [String: Any] = [
            "text": text,
            "category": category.rawValue,
            "timestamp": Date().timeIntervalSince1970
        ]

        WCSession.default.sendMessage(message, replyHandler: { reply in
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
            DispatchQueue.main.async {
                sending = false
                errorMessage = "送信エラー: \(error.localizedDescription)"
                WKInterfaceDevice.current().play(.failure)
            }
        })
    }
}
