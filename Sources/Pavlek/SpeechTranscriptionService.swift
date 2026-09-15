#if os(macOS)
import AVFoundation
import Combine
import Foundation
@preconcurrency import Speech

struct SpeechCommandComposer {
    static func compose(baseCommand: String, transcript: String) -> String {
        let spokenText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spokenText.isEmpty else { return baseCommand }

        let existingText = baseCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !existingText.isEmpty else { return spokenText }
        return existingText + " " + spokenText
    }
}

@MainActor
final class SpeechTranscriptionService: ObservableObject {
    enum Permission: String, Equatable, Sendable {
        case microphone
        case speechRecognition
    }

    enum State: Equatable, Sendable {
        case idle
        case requestingPermission
        case listening
        case finalizing
        case transcribed
        case permissionDenied(Permission)
        case failed(String)

        var statusMessage: String {
            switch self {
            case .idle:
                "Clique no microfone para ditar o comando."
            case .requestingPermission:
                "Solicitando acesso ao microfone e ao reconhecimento de fala…"
            case .listening:
                "Escutando… clique em Parar quando terminar."
            case .finalizing:
                "Finalizando a transcrição…"
            case .transcribed:
                "Transcrição inserida no comando."
            case .permissionDenied(.microphone):
                "Acesso ao microfone negado. Autorize o Pavlek nos Ajustes do Sistema."
            case .permissionDenied(.speechRecognition):
                "Reconhecimento de fala negado. Autorize o Pavlek nos Ajustes do Sistema."
            case .failed(let message):
                message
            }
        }

        var isCapturingOrRequesting: Bool {
            switch self {
            case .requestingPermission, .listening, .finalizing: true
            case .idle, .transcribed, .permissionDenied, .failed: false
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = ""

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var finalizationTask: Task<Void, Never>?
    private var sessionID: UUID?
    private var hasInstalledTap = false

    init(locale: Locale = Locale(identifier: "pt-BR")) {
        recognizer = SFSpeechRecognizer(locale: locale)
    }

    func start() {
        guard !state.isCapturingOrRequesting else { return }
        let sessionID = UUID()
        self.sessionID = sessionID
        transcript = ""
        state = .requestingPermission

        Task { [weak self] in
            await self?.startAfterPermissions(sessionID: sessionID)
        }
    }

    func stop() {
        switch state {
        case .requestingPermission:
            sessionID = nil
            state = .idle
        case .listening:
            state = .finalizing
            stopAudioCapture(endingRecognition: true)
            scheduleFinalizationFallback()
        case .idle, .finalizing, .transcribed, .permissionDenied, .failed:
            break
        }
    }

    private func startAfterPermissions(sessionID: UUID) async {
        let speechStatus = await requestSpeechRecognitionPermission()
        guard self.sessionID == sessionID else { return }
        guard speechStatus == .authorized else {
            self.sessionID = nil
            state = .permissionDenied(.speechRecognition)
            return
        }

        let microphoneAllowed = await requestMicrophonePermission()
        guard self.sessionID == sessionID else { return }
        guard microphoneAllowed else {
            self.sessionID = nil
            state = .permissionDenied(.microphone)
            return
        }

        startRecognition()
    }

    private func startRecognition() {
        guard let recognizer, recognizer.isAvailable else {
            sessionID = nil
            state = .failed("O reconhecimento de fala não está disponível neste momento.")
            return
        }

        // AVAudioEngine invokes the tap on its real-time audio queue. Keep the
        // request itself out of MainActor isolation so that appending audio
        // buffers does not trigger Swift 6's executor precondition at runtime.
        nonisolated(unsafe) let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            finishWithError("O microfone não forneceu um formato de áudio válido.")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { @Sendable buffer, _ in
            request.append(buffer)
        }
        hasInstalledTap = true

        recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let recognizedText = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let hasError = error != nil
            Task { @MainActor [weak self] in
                self?.handleRecognition(text: recognizedText, isFinal: isFinal, hasError: hasError)
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            state = .listening
        } catch {
            finishWithError("Não foi possível iniciar a captura do microfone.")
        }
    }

    private func handleRecognition(text: String?, isFinal: Bool, hasError: Bool) {
        if let text, !text.isEmpty { transcript = text }
        if isFinal {
            finishRecognition()
        } else if hasError {
            finishWithError("Não foi possível transcrever a fala.")
        }
    }

    private func finishRecognition() {
        finalizationTask?.cancel()
        finalizationTask = nil
        stopAudioCapture(endingRecognition: false)
        recognitionTask = nil
        recognitionRequest = nil
        sessionID = nil
        state = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .idle : .transcribed
    }

    private func finishWithError(_ message: String) {
        finalizationTask?.cancel()
        finalizationTask = nil
        stopAudioCapture(endingRecognition: false)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        sessionID = nil
        state = .failed(message)
    }

    private func stopAudioCapture(endingRecognition: Bool) {
        if audioEngine.isRunning { audioEngine.stop() }
        if hasInstalledTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInstalledTap = false
        }
        if endingRecognition { recognitionRequest?.endAudio() }
    }

    private func scheduleFinalizationFallback() {
        finalizationTask?.cancel()
        finalizationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.state == .finalizing else { return }
                self.finishRecognition()
            }
        }
    }

    private func requestSpeechRecognitionPermission() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
    }

    private func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            false
        @unknown default:
            false
        }
    }
}
#endif
