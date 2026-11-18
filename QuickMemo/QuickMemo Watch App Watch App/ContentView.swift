import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var text = ""
    @State private var saved = false
    @State private var sending = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var pendingCount = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                TextField("タップして入力", text: $text, axis: .vertical)
                    .lineLimit(3...10)

                // Save buttons
                HStack(spacing: 16) {
                    ForEach(MemoCategory.allCases) { category in
                        Button {
                            Task { await save(category: category) }
                        } label: {
                            Text(category.emoji)
                                .font(.system(size: 28))
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(text.isEmpty || sending)
                    }
                }

                if !WatchWebDAVService.shared.isConfigured {
                    Text("iPhoneで設定してください")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                if pendingCount > 0 {
                    Button {
                        Task { await flushPending(userInitiated: true) }
                    } label: {
                        Label("未送信 \(pendingCount)件", systemImage: "arrow.up.circle")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .disabled(sending)
                }

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption2)
                        .foregroundStyle(statusIsError ? .red : .secondary)
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
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                // Warm the GPS for as long as the app is on screen
                WatchLocationManager.shared.startTracking()
                Task { await flushPending() }
            } else {
                WatchLocationManager.shared.stopTracking()
            }
        }
    }

    private func save(category: MemoCategory) async {
        sending = true
        defer { sending = false }

        // Capture when and where the memo was taken, before any network work
        let createdAt = Date()
        let location = await WatchLocationManager.shared.getLocation()
        let memo = PendingMemo(text: text, category: category, createdAt: createdAt, location: location)

        // The server has already refused us: queue it without touching the
        // network, since another attempt would only extend the throttle
        if let block = await PendingMemoStore.shared.currentBlock() {
            await PendingMemoStore.shared.enqueue(memo)
            text = ""
            pendingCount = await PendingMemoStore.shared.count
            statusMessage = blockMessage(block)
            statusIsError = true
            WKInterfaceDevice.current().play(.failure)
            return
        }

        do {
            try await WatchWebDAVService.shared.upload(memo)
            text = ""
            statusMessage = nil
            statusIsError = false
            saved = true
            WKInterfaceDevice.current().play(.success)
            try? await Task.sleep(for: .seconds(1.5))
            saved = false
            // Network is up — drain anything that failed earlier
            await flushPending()
        } catch {
            // Queue it with its original timestamp and location, and clear the
            // field so the user does not re-send a duplicate by hand
            await PendingMemoStore.shared.enqueue(memo)
            let block = await PendingMemoStore.shared.recordFailure(error)
            text = ""
            pendingCount = await PendingMemoStore.shared.count
            statusMessage = block.map(blockMessage) ?? "送信失敗 - 後で送信します"
            statusIsError = true
            WKInterfaceDevice.current().play(.failure)
        }
    }

    private func flushPending(userInitiated: Bool = false) async {
        pendingCount = await PendingMemoStore.shared.count
        guard pendingCount > 0 else { return }

        if userInitiated { sending = true }
        let sent = await PendingMemoStore.shared.flush(userInitiated: userInitiated)
        if userInitiated { sending = false }

        pendingCount = await PendingMemoStore.shared.count

        if sent > 0 {
            statusMessage = "未送信\(sent)件を送信しました"
            statusIsError = false
            WKInterfaceDevice.current().play(.success)
        } else if userInitiated {
            statusMessage = "まだ送信できません"
            statusIsError = true
            WKInterfaceDevice.current().play(.failure)
        }

        // While memos are stuck behind a block, keep saying why
        if pendingCount > 0, let block = await PendingMemoStore.shared.currentBlock() {
            statusMessage = blockMessage(block)
            statusIsError = true
        }
    }

    private func blockMessage(_ block: UploadBlock) -> String {
        switch block {
        case .unauthorized:
            return "認証エラー\niPhoneの設定でパスワードを確認してください"
        case .throttled:
            return "サーバ制限中 (429)\n30分ほど待って再送します"
        }
    }
}
