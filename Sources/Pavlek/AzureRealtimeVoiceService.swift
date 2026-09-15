#if os(macOS)
@preconcurrency import AVFoundation
import Foundation

struct AzureRealtimeEvent: Sendable {
    let type: String
    let textDelta: String?
    let audio: Data?
    let inputTranscript: String?
    let errorMessage: String?
    let responseID: String?

    static func decode(_ data: Data) -> AzureRealtimeEvent? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = root["type"] as? String else { return nil }
        let delta = root["delta"] as? String
        let audio: Data?
        if ["response.audio.delta", "response.output_audio.delta"].contains(type), let delta {
            audio = Data(base64Encoded: delta)
        } else {
            audio = nil
        }
        let textDelta = ["response.audio_transcript.delta", "response.output_audio_transcript.delta", "response.output_text.delta"].contains(type)
            ? delta : nil
        let inputTranscript = root["transcript"] as? String
        let response = root["response"] as? [String: Any]
        let errorMessage = (root["error"] as? [String: Any])?["message"] as? String
            ?? (response?["error"] as? [String: Any])?["message"] as? String
        let responseID = response?["id"] as? String
        return .init(type: type, textDelta: textDelta, audio: audio,
                     inputTranscript: inputTranscript, errorMessage: errorMessage,
                     responseID: responseID)
    }
}

/// A small, provider-specific Realtime transport. It never logs or persists
/// the credential and only opens a socket after the caller explicitly starts
/// a voice session.
actor AzureRealtimeClient {
    typealias EventHandler = @Sendable (AzureRealtimeEvent) async -> Void

    private let configurationProvider: @Sendable () -> PavlakAIConfiguration
    private let session: URLSession
    private let budget: CloudBudget
    private let isLocalOnly: @Sendable () -> Bool
    private let credentialProvider: (@Sendable (PavlakAIConfiguration) async -> String?)?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var configuredContinuation: CheckedContinuation<Void, Error>?
    private var eventHandler: EventHandler?

    init(
        configurationProvider: @escaping @Sendable () -> PavlakAIConfiguration = { PavlakAIConfigurationStore.load() },
        session: URLSession = CloudHTTP.session,
        budget: CloudBudget = .shared,
        isLocalOnly: @escaping @Sendable () -> Bool = { OpenAIUsagePolicy.isLocalOnly },
        credentialProvider: (@Sendable (PavlakAIConfiguration) async -> String?)? = nil
    ) {
        self.configurationProvider = configurationProvider
        self.session = session
        self.budget = budget
        self.isLocalOnly = isLocalOnly
        self.credentialProvider = credentialProvider
    }

    func connect(instructions: String, onEvent: @escaping EventHandler) async throws {
        guard !isLocalOnly() else { throw CloudFailure.consent }
        let configuration = configurationProvider()
        guard configuration.provider == .azureOpenAI,
              configuration.validationError() == nil,
              configuration.realtimeURL != nil else { throw CloudFailure.configuration }
        let credential = if let credentialProvider {
            await credentialProvider(configuration)
        } else {
            await CloudCredentialStore.load(configuration: configuration)
        }
        guard let credential, !credential.isEmpty else {
            throw CloudFailure.credential
        }
        try budget.reserve(inputBytes: 0, voice: true)
        try Task.checkCancellation()

        let request = try Self.makeRealtimeRequest(configuration: configuration, credential: credential)
        let task = session.webSocketTask(with: request)
        socket = task
        eventHandler = onEvent
        task.resume()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            configuredContinuation = continuation
            receiveTask = Task { [weak self] in await self?.receiveLoop(instructions: instructions) }
        }
    }

    static func makeRealtimeRequest(configuration: PavlakAIConfiguration, credential: String) throws -> URLRequest {
        guard let url = configuration.realtimeURL else { throw CloudFailure.configuration }
        var request = try CloudHTTP.request(configuration: configuration, credential: credential, body: nil, realtime: true)
        request.setValue("audio/pcm;rate=24000", forHTTPHeaderField: "Accept")
        request.url = url
        return request
    }

    func appendAudio(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await send(.object([
            "type": .string("input_audio_buffer.append"),
            "audio": .string(data.base64EncodedString())
        ]))
    }

    func commitAndRespond() async throws {
        try await send(.object(["type": .string("input_audio_buffer.commit")]))
        try await send(.object(["type": .string("response.create")]))
    }

    func disconnect() {
        configuredContinuation?.resume(throwing: CloudFailure.cancelled)
        configuredContinuation = nil
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        eventHandler = nil
    }

    private func send(_ value: JSONValue) async throws {
        guard !isLocalOnly(), let socket else { throw CloudFailure.cancelled }
        let data = try JSONEncoder().encode(value)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receiveLoop(instructions: String) async {
        do {
            while let socket {
                let message = try await socket.receive()
                let data: Data?
                switch message {
                case .data(let value): data = value
                case .string(let value): data = Data(value.utf8)
                @unknown default: data = nil
                }
                guard let data, let event = AzureRealtimeEvent.decode(data) else { continue }
                if event.type == "session.created" {
                    try await send(Self.makeSessionUpdate(instructions: instructions))
                } else if event.type == "session.updated" {
                    configuredContinuation?.resume()
                    configuredContinuation = nil
                } else if event.type == "error" {
                    let message = event.errorMessage ?? "Falha na sessão de voz Azure."
                    configuredContinuation?.resume(throwing: CloudFailure.response)
                    configuredContinuation = nil
                    await eventHandler?(event)
                    throw NSError(domain: "Pavlek.AzureRealtime", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
                }
                await eventHandler?(event)
            }
        } catch is CancellationError {
            configuredContinuation?.resume(throwing: CloudFailure.cancelled)
            configuredContinuation = nil
        } catch {
            configuredContinuation?.resume(throwing: CloudFailure.response)
            configuredContinuation = nil
            let event = AzureRealtimeEvent(type: "transport.error", textDelta: nil, audio: nil,
                                           inputTranscript: nil, errorMessage: nil, responseID: nil)
            await eventHandler?(event)
        }
    }

    static func makeSessionUpdate(instructions: String) -> JSONValue {
        .object([
            "type": .string("session.update"),
            "session": .object([
                "type": .string("realtime"),
                "instructions": .string(String(instructions.prefix(8_000))),
                "output_modalities": .array([.string("audio")]),
                "audio": .object([
                    "input": .object([
                        "format": .object([
                            "type": .string("audio/pcm"),
                            "rate": .number(24_000)
                        ]),
                        "transcription": .object([
                            "model": .string("whisper-1")
                        ]),
                        // Push-to-talk keeps the request boundary explicit.
                        "turn_detection": .null
                    ]),
                    "output": .object([
                        "format": .object([
                            "type": .string("audio/pcm"),
                            "rate": .number(24_000)
                        ]),
                        "voice": .string("alloy")
                    ])
                ])
            ])
        ])
    }
}

@MainActor
final class AzureRealtimeAudioEngine {
    private final class AudioInputProvider: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var supplied = false

        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)
    private var converter: AVAudioConverter?
    private var tapInstalled = false
    private var playerAttached = false
    private var playerConnected = false
    private var isStarted = false

    func start(onAudio: @escaping @Sendable (Data) async -> Void) async throws {
        guard !isStarted else { return }
        let currentPermission = AVCaptureDevice.authorizationStatus(for: .audio)
        let microphoneAllowed: Bool
        if currentPermission == .authorized {
            microphoneAllowed = true
        } else if currentPermission == .notDetermined {
            microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            microphoneAllowed = false
        }
        guard microphoneAllowed else {
            throw CloudFailure.consent
        }
        guard let outputFormat else { throw CloudFailure.configuration }
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw CloudFailure.response
        }
        self.converter = converter
        if !playerAttached {
            engine.attach(player)
            playerAttached = true
        }
        if !playerConnected {
            engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
            playerConnected = true
        }
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { @Sendable buffer, _ in
            guard let converted = Self.convert(buffer, converter: converter, format: outputFormat), converted.frameLength > 0,
                  let channel = converted.int16ChannelData?.pointee else { return }
            let bytes = Data(bytes: channel, count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
            Task { await onAudio(bytes) }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        player.play()
        isStarted = true
    }

    func stopCapture() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        converter = nil
    }

    func stop() {
        stopCapture()
        player.stop()
        if engine.isRunning { engine.stop() }
        converter = nil
        isStarted = false
    }

    func play(_ data: Data) {
        guard let outputFormat, !data.isEmpty else { return }
        let frameCount = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCount),
              let channel = buffer.int16ChannelData?.pointee else { return }
        buffer.frameLength = frameCount
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            memcpy(channel, baseAddress, min(data.count, Int(frameCount) * MemoryLayout<Int16>.size))
        }
        player.scheduleBuffer(buffer)
        if isStarted, !player.isPlaying { player.play() }
    }

    nonisolated private static func convert(_ input: AVAudioPCMBuffer, converter: AVAudioConverter, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        let provider = AudioInputProvider(input)
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if provider.supplied {
                status.pointee = .endOfStream
                return nil
            }
            provider.supplied = true
            status.pointee = .haveData
            return provider.buffer
        }
        return conversionError == nil ? output : nil
    }
}

@MainActor
final class AzureRealtimeVoiceService: ObservableObject {
    enum State: Equatable, Sendable {
        case idle
        case connecting
        case listening
        case responding
        case failed(String)

        var isActive: Bool {
            switch self { case .connecting, .listening, .responding: true; case .idle, .failed: false }
        }
        var message: String {
            switch self {
            case .idle: "Voz Azure pronta; a sessão só começa ao clicar."
            case .connecting: "Conectando voz ao Azure…"
            case .listening: "Escutando; clique novamente para enviar esta fala."
            case .responding: "O Azure está respondendo por voz…"
            case .failed(let value): value
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var assistantText = ""
    @Published private(set) var inputTranscript = ""

    private let client: AzureRealtimeClient
    private let audio: AzureRealtimeAudioEngine
    private var task: Task<Void, Never>?
    private var outputShutdownTask: Task<Void, Never>?
    private var voiceLimitTask: Task<Void, Never>?
    private var voiceStartedAt: Date?

    init(client: AzureRealtimeClient = .init(), audio: AzureRealtimeAudioEngine = .init()) {
        self.client = client
        self.audio = audio
    }

    func start() {
        guard !state.isActive else { return }
        task?.cancel()
        outputShutdownTask?.cancel()
        voiceLimitTask?.cancel()
        audio.stop()
        assistantText = ""
        inputTranscript = ""
        state = .connecting
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await client.connect(instructions: "Responda em português do Brasil. Seja conciso e nunca afirme ter acessado arquivos sem evidência.") { [weak self] event in
                    await MainActor.run { self?.handle(event) }
                }
                try Task.checkCancellation()
                try await audio.start { [client] data in try? await client.appendAudio(data) }
                state = .listening
                voiceStartedAt = Date()
                let limit = CloudBudget.shared.limits.voiceSeconds
                voiceLimitTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(limit))
                    guard !Task.isCancelled else { return }
                    await MainActor.run { [weak self] in
                        guard let self, self.state == .listening else { return }
                        self.stop()
                    }
                }
            } catch is CancellationError {
                await client.disconnect()
                await MainActor.run { if self.state != .idle { self.state = .idle } }
            } catch {
                audio.stop()
                await client.disconnect()
                await MainActor.run { self.state = .failed((error as? LocalizedError)?.errorDescription ?? "Não foi possível iniciar a voz Azure.") }
            }
        }
    }

    func stop() {
        guard state == .listening else {
            if state == .connecting { reset(); return }
            if state == .responding { task?.cancel(); task = nil; audio.stop(); Task { await client.disconnect() }; state = .idle }
            return
        }
        state = .responding
        voiceLimitTask?.cancel(); voiceLimitTask = nil
        audio.stopCapture()
        task = Task { [weak self] in
            guard let self else { return }
            do { try await client.commitAndRespond() }
            catch {
                await client.disconnect()
                await MainActor.run { self.state = .failed("A fala não pôde ser enviada ao Azure.") }
            }
        }
    }

    func reset() {
        task?.cancel(); task = nil
        outputShutdownTask?.cancel(); outputShutdownTask = nil
        voiceLimitTask?.cancel(); voiceLimitTask = nil
        voiceStartedAt = nil
        audio.stop()
        Task { await client.disconnect() }
        state = .idle
    }

    private func handle(_ event: AzureRealtimeEvent) {
        if let delta = event.textDelta {
            let remaining = max(0, 8_000 - assistantText.count)
            if remaining > 0 { assistantText.append(String(delta.prefix(remaining))) }
        }
        if let audio = event.audio { self.audio.play(audio) }
        if let transcript = event.inputTranscript { inputTranscript = String(transcript.prefix(8_000)) }
        if event.type == "response.done" {
            voiceLimitTask?.cancel(); voiceLimitTask = nil
            if let started = voiceStartedAt {
                CloudBudget.shared.record(input: 0, output: assistantText.count,
                                          voiceSeconds: Int(ceil(Date().timeIntervalSince(started))))
                voiceStartedAt = nil
            }
            state = .idle
            Task { await client.disconnect() }
            outputShutdownTask?.cancel()
            outputShutdownTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.state == .idle else { return }
                    self.audio.stop()
                }
            }
        } else if event.type == "error" || event.type == "transport.error" || event.type == "response.failed" {
            voiceLimitTask?.cancel(); voiceLimitTask = nil
            voiceStartedAt = nil
            audio.stopCapture()
            state = .failed(event.errorMessage ?? "A sessão de voz Azure foi encerrada.")
            Task { await client.disconnect() }
        }
    }
}
#endif
