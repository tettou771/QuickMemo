import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
class SpeechRecognizer: ObservableObject {
    @Published var transcript = ""
    @Published var isRecording = false
    @Published var errorMessage: String?

    private var audioEngine: AVAudioEngine?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))

    // MARK: - Permissions

    func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard speechStatus == .authorized else {
            errorMessage = "音声認識の許可が必要です"
            return false
        }

        let audioGranted: Bool
        if #available(iOS 17.0, *) {
            audioGranted = await AVAudioApplication.requestRecordPermission()
        } else {
            audioGranted = await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
        guard audioGranted else {
            errorMessage = "マイクの許可が必要です"
            return false
        }

        return true
    }

    // MARK: - Start / Stop

    func startRecording() {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            errorMessage = "音声認識が利用できません"
            return
        }

        let audioEngine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            request.append(buffer)
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            try audioEngine.start()
        } catch {
            errorMessage = "オーディオエンジンの起動に失敗: \(error.localizedDescription)"
            return
        }

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.stopRecording()
                }
            }
        }

        self.audioEngine = audioEngine
        self.recognitionRequest = request
        self.isRecording = true
        self.errorMessage = nil
    }

    func stopRecording() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()

        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
    }

    func reset() {
        stopRecording()
        transcript = ""
        errorMessage = nil
    }
}
