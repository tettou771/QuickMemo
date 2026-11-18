import SwiftUI
import UIKit

struct RecordingView: View {
    @StateObject private var recognizer = SpeechRecognizer()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var text = ""
    @State private var saved = false
    @State private var saveError: String?
    @State private var saving = false
    @State private var pendingCount = 0
    @State private var statusMessage: String?
    @State private var saveAlertTitle = "保存しました"
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Editable text area (voice input goes here too)
            TextEditor(text: $text)
                .focused($textFocused)
                .padding(8)
                .frame(maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.top, 8)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("話すか、入力してください...")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 24)
                            .padding(.top, 20)
                            .allowsHitTesting(false)
                    }
                }

            // Recording indicator + mic button
            HStack(spacing: 16) {
                if recognizer.isRecording {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                    Text("録音中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    toggleRecording()
                } label: {
                    Image(systemName: recognizer.isRecording ? "mic.fill" : "mic")
                        .font(.title2)
                        .foregroundStyle(recognizer.isRecording ? .red : .blue)
                        .padding(10)
                        .background(
                            recognizer.isRecording ? Color.red.opacity(0.15) : Color.blue.opacity(0.1),
                            in: Circle()
                        )
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Pending upload queue
            if pendingCount > 0 {
                Button {
                    Task { await flushPending(userInitiated: true) }
                } label: {
                    Label("未送信 \(pendingCount)件", systemImage: "arrow.up.circle")
                        .font(.caption)
                }
                .disabled(saving)
                .padding(.bottom, 4)
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            // Error display
            if let error = recognizer.errorMessage ?? saveError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            // Save buttons — emoji only, no background
            HStack(spacing: 40) {
                ForEach(MemoCategory.allCases) { category in
                    Button {
                        Task { await save(category: category) }
                    } label: {
                        Text(category.emoji)
                            .font(.system(size: 40))
                    }
                    .disabled(text.isEmpty || saving)
                    .opacity(text.isEmpty || saving ? 0.3 : 1)
                }
            }
            .padding(.bottom, 24)
        }
        .navigationTitle("QuickMemo")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Retry anything left over from a previous session
            await flushPending()
            // Auto-start voice recording on launch
            let granted = await recognizer.requestPermissions()
            if granted {
                recognizer.startRecording()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickMemoSettingsSaved)) { _ in
            saveError = nil
            Task { await flushPending() }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                // Keep the GPS warm for as long as the app is on screen
                LocationManager.shared.startTracking()
                Task { await flushPending() }
            } else {
                LocationManager.shared.stopTracking()
            }
        }
        .onChange(of: recognizer.transcript) { _, newValue in
            if !newValue.isEmpty {
                text = newValue
            }
        }
        .alert(saveAlertTitle, isPresented: $saved) {
            Button("OK") {
                text = ""
                recognizer.reset()
            }
        }
    }

    private func toggleRecording() {
        if recognizer.isRecording {
            recognizer.stopRecording()
        } else {
            textFocused = false
            Task {
                let granted = await recognizer.requestPermissions()
                if granted {
                    recognizer.transcript = ""
                    recognizer.startRecording()
                }
            }
        }
    }

    private func save(category: MemoCategory) async {
        recognizer.stopRecording()
        saving = true
        defer { saving = false }

        // Capture when and where the memo was taken, before any network work
        let createdAt = Date()
        // Normally the tracked fix is ready; waits briefly only right after launch
        let location = await LocationManager.shared.getLocation()
        let memo = PendingMemo(text: text, category: category, createdAt: createdAt, location: location)

        // The server has already refused us: queue it without touching the
        // network, since another attempt would only extend the throttle
        if let block = await PendingMemoStore.shared.currentBlock() {
            await PendingMemoStore.shared.enqueue(memo)
            pendingCount = await PendingMemoStore.shared.count
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            saveError = blockMessage(block)
            saveAlertTitle = "後で送信します"
            saved = true
            return
        }

        do {
            try await WebDAVService.shared.upload(memo)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            saveAlertTitle = "保存しました"
            saved = true
            saveError = nil
            statusMessage = nil
            // Network is up — drain anything that failed earlier
            await flushPending()
        } catch {
            // Queue it with its original timestamp and location so it is not lost
            await PendingMemoStore.shared.enqueue(memo)
            let block = await PendingMemoStore.shared.recordFailure(error)
            pendingCount = await PendingMemoStore.shared.count
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            saveError = block.map(blockMessage) ?? "送信失敗: \(error.localizedDescription)"
            // Clear the field like a successful save would, so the user does not
            // re-send the same memo by hand and create a duplicate
            saveAlertTitle = "後で送信します"
            saved = true
        }
    }

    private func flushPending(userInitiated: Bool = false) async {
        pendingCount = await PendingMemoStore.shared.count
        guard pendingCount > 0 else { return }

        if userInitiated { saving = true }
        let sent = await PendingMemoStore.shared.flush(userInitiated: userInitiated)
        if userInitiated { saving = false }

        pendingCount = await PendingMemoStore.shared.count

        if sent > 0 {
            statusMessage = "未送信\(sent)件を送信しました"
            saveError = nil
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else if userInitiated {
            statusMessage = nil
            saveError = "まだ送信できません"
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }

        // While memos are stuck behind a block, keep saying why
        if pendingCount > 0, let block = await PendingMemoStore.shared.currentBlock() {
            saveError = blockMessage(block)
        }
    }

    private func blockMessage(_ block: UploadBlock) -> String {
        switch block {
        case .unauthorized:
            return "認証エラー: 設定でアプリパスワードを確認してください。直すまで自動では再送しません"
        case .throttled:
            return "サーバが一時的に受け付けていません (HTTP 429)。30分ほど待ってから再送します"
        }
    }
}
