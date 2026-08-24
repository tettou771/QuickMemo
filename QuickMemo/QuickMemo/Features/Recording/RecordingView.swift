import SwiftUI
import UIKit

struct RecordingView: View {
    @StateObject private var recognizer = SpeechRecognizer()
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var saved = false
    @State private var saveError: String?
    @State private var saving = false
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
            // Start location fetch early
            LocationManager.shared.startFetching()
            // Auto-start voice recording on launch
            let granted = await recognizer.requestPermissions()
            if granted {
                recognizer.startRecording()
            }
        }
        .onChange(of: recognizer.transcript) { _, newValue in
            if !newValue.isEmpty {
                text = newValue
            }
        }
        .alert("保存しました", isPresented: $saved) {
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

        // Wait for location (started when view appeared, up to 10s)
        let location = await LocationManager.shared.getLocation()

        do {
            try await WebDAVService.shared.saveMemo(text: text, category: category, location: location)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            saved = true
            saveError = nil
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            saveError = error.localizedDescription
        }
    }
}
