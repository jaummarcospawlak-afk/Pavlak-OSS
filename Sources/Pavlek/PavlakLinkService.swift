import Foundation
import CryptoKit
@preconcurrency import Network
import Security

final class PavlakLinkService: ObservableObject, @unchecked Sendable {
    static let shared = PavlakLinkService()
    static let serviceType = "_pavlak-link._tcp"

    #if os(iOS)
    let localDevice: PavlakDevice = .iPhone
    private let serviceName = "Pavlak iPhone"
    #else
    let localDevice: PavlakDevice = .mac
    private let serviceName = "Pavlak Mac"
    #endif

    @Published private(set) var remoteState: PavlakLinkConnectionState = .idle
    @Published private(set) var connectedDevices: Set<PavlakDevice> = []
    @Published private(set) var lastLatency: TimeInterval?
    @Published private(set) var lastMessage: PavlakLinkMessage?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isTransportEncrypted = false

    var commandHandler: (@MainActor @Sendable (PavlakLinkMessage) async -> PavlakLinkMessage)?

    private let queue = DispatchQueue(label: "com.pavlak.link.network")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [PavlakDevice: NWConnection] = [:]
    private var connectingDevices: Set<PavlakDevice> = []
    private var buffers: [ObjectIdentifier: Data] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()
    private var pending: [UUID: CheckedContinuation<PavlakLinkMessage, Error>] = [:]
    private var pendingStartedAt: [UUID: Date] = [:]
    private var pendingTimeouts: [UUID: Task<Void, Never>] = [:]
    private var started = false
    private var acceptedNonces: [String] = []

    private init() { }

    var hasPairingSecret: Bool { PavlakLinkPairingStore.load() != nil }

    func configurePairingCode(_ code: String) throws {
        try PavlakLinkPairingStore.save(code: code)
        errorMessage = nil
        start()
    }

    func revokePairing() {
        stop()
        PavlakLinkPairingStore.remove()
        DispatchQueue.main.async {
            self.connectedDevices.removeAll()
            self.isTransportEncrypted = false
            self.errorMessage = PavlakLinkError.pairingRequired.localizedDescription
        }
    }

    func start() {
        guard hasPairingSecret else {
            publish(error: PavlakLinkError.pairingRequired)
            return
        }
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        publish(state: .discovering)
        #if os(iOS)
        startBrowser()
        #else
        startListener()
        #endif
    }

    func stop() {
        queue.async {
            self.listener?.cancel(); self.browser?.cancel()
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll(); self.buffers.removeAll()
            self.failAllPending(with: PavlakLinkError.connectionClosed)
            self.lock.lock(); self.started = false; self.lock.unlock()
            DispatchQueue.main.async {
                self.connectedDevices.removeAll()
                self.isTransportEncrypted = false
                self.remoteState = .idle
            }
        }
    }

    func request(
        action: PavlakLinkAction,
        query: String,
        target: PavlakDevice,
        payload: String? = nil,
        timeout: Duration = .seconds(15)
    ) async throws -> PavlakLinkMessage {
        guard connectedDevices.contains(target) else { throw PavlakLinkError.deviceUnavailable(target) }
        let message = PavlakLinkMessage(requestID: UUID(), sourceDevice: localDevice, targetDevice: target,
                                        action: action, query: query, payload: payload, status: .requested, result: nil, sentAt: Date())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled else { return }
                    self?.finishPending(message.requestID, with: .failure(PavlakLinkError.timedOut))
                }
                lock.lock()
                pending[message.requestID] = continuation
                pendingStartedAt[message.requestID] = Date()
                pendingTimeouts[message.requestID] = timeoutTask
                lock.unlock()
                do { try send(message, target: target) }
                catch { finishPending(message.requestID, with: .failure(error)) }
            }
        } onCancel: {
            self.finishPending(message.requestID, with: .failure(CancellationError()))
        }
    }

    private func startListener() {
        do {
            let parameters = try secureParameters()
            let listener = try NWListener(using: parameters, on: .any)
            listener.service = NWListener.Service(name: serviceName, type: Self.serviceType)
            listener.stateUpdateHandler = { [weak self] state in self?.handle(listenerState: state) }
            listener.newConnectionHandler = { [weak self] connection in self?.start(connection: connection, expected: nil) }
            self.listener = listener
            listener.start(queue: queue)
        } catch { publish(error: error) }
    }

    private func startBrowser() {
        guard let parameters = try? secureParameters() else {
            publish(error: PavlakLinkError.pairingRequired)
            return
        }
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state { self?.publish(error: error) }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.handle(results: results) }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func handle(results: Set<NWBrowser.Result>) {
        let remote = localDevice == .mac ? PavlakDevice.iPhone : .mac
        let expectedName = remote == .iPhone ? "Pavlak iPhone" : "Pavlak Mac"
        guard !connections.keys.contains(remote), !connectingDevices.contains(remote),
              let result = results.first(where: { result in
                  if case .service(let name, _, _, _) = result.endpoint { return name == expectedName }
                  return false
              }) else { return }
        connectingDevices.insert(remote)
        publish(state: .found)
        guard let parameters = try? secureParameters() else {
            connectingDevices.remove(remote)
            publish(error: PavlakLinkError.pairingRequired)
            return
        }
        let connection = NWConnection(to: result.endpoint, using: parameters)
        start(connection: connection, expected: remote)
    }

    private func start(connection: NWConnection, expected: PavlakDevice?) {
        publish(state: .connecting)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if let expected {
                    self.connectingDevices.remove(expected)
                    self.connections[expected] = connection
                }
                self.receive(on: connection)
                self.sendHello(on: connection)
                DispatchQueue.main.async { self.isTransportEncrypted = true }
            case .failed(let error):
                if let expected { self.connectingDevices.remove(expected) }
                self.remove(connection); self.publish(error: error)
            case .cancelled:
                if let expected { self.connectingDevices.remove(expected) }
                self.remove(connection)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func sendHello(on connection: NWConnection) {
        let target: PavlakDevice = localDevice == .mac ? .iPhone : .mac
        let hello = PavlakLinkMessage(requestID: UUID(), sourceDevice: localDevice, targetDevice: target,
                                      action: .hello, query: "handshake", payload: localDevice.rawValue,
                                      status: .requested, result: nil, sentAt: Date())
        try? send(hello, on: connection)
    }

    private func send(_ message: PavlakLinkMessage, target: PavlakDevice) throws {
        guard let connection = connections[target] else { throw PavlakLinkError.deviceUnavailable(target) }
        try send(message, on: connection)
        DispatchQueue.main.async { self.lastMessage = message }
    }

    private func send(_ message: PavlakLinkMessage, on connection: NWConnection) throws {
        guard let secret = PavlakLinkPairingStore.load() else { throw PavlakLinkError.pairingRequired }
        let authenticated = PavlakLinkAuthenticator.sign(message, secret: secret)
        var data = try encoder.encode(authenticated); data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in if let error { self?.publish(error: error) } })
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection else { return }
            if let data { self.consume(data, from: connection) }
            if let error { self.publish(error: error); self.remove(connection); return }
            if complete { self.remove(connection); return }
            self.receive(on: connection)
        }
    }

    private func consume(_ data: Data, from connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        var buffer = buffers[key, default: Data()]; buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let packet = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
            if let message = try? decoder.decode(PavlakLinkMessage.self, from: packet) {
                guard let secret = PavlakLinkPairingStore.load(),
                      PavlakLinkAuthenticator.verify(message, secret: secret),
                      let nonce = message.authentication?.nonce,
                      !acceptedNonces.contains(nonce) else {
                    publish(error: PavlakLinkError.authenticationFailed)
                    continue
                }
                acceptedNonces.append(nonce)
                if acceptedNonces.count > 500 { acceptedNonces.removeFirst(acceptedNonces.count - 500) }
                receive(message, from: connection)
            }
        }
        buffers[key] = buffer
    }

    private func receive(_ message: PavlakLinkMessage, from connection: NWConnection) {
        if message.action == .hello {
            connections[message.sourceDevice] = connection
            DispatchQueue.main.async {
                self.connectedDevices.insert(message.sourceDevice)
                self.remoteState = .connected
                self.lastMessage = message
            }
            if message.status == .requested {
                try? send(message.response(status: .success, result: "connected"), on: connection)
            }
            return
        }
        DispatchQueue.main.async { self.lastMessage = message }
        if message.status == .success || message.status == .failure {
            finishPending(message.requestID, with: .success(message))
            return
        }
        guard message.targetDevice == localDevice, let handler = commandHandler else { return }
        Task { @MainActor in
            let response: PavlakLinkMessage
            if message.action == .ping { response = message.response(status: .success, result: "pong") }
            else { response = await handler(message) }
            // Reply on the exact connection that delivered the request. Both
            // peers browse and listen at the same time, so the device map may
            // point at a second, competing connection during the handshake.
            try? self.send(response, on: connection)
        }
    }

    private func remove(_ connection: NWConnection) {
        let removed = connections.filter { $0.value === connection }.map(\.key)
        removed.forEach { connections.removeValue(forKey: $0) }
        buffers.removeValue(forKey: ObjectIdentifier(connection))
        DispatchQueue.main.async {
            removed.forEach { self.connectedDevices.remove($0) }
            if !removed.isEmpty { self.remoteState = .discovering }
        }
        if !removed.isEmpty { failAllPending(with: PavlakLinkError.connectionClosed) }
    }

    private func finishPending(_ requestID: UUID, with result: Result<PavlakLinkMessage, Error>) {
        lock.lock()
        let continuation = pending.removeValue(forKey: requestID)
        let startedAt = pendingStartedAt.removeValue(forKey: requestID)
        let timeoutTask = pendingTimeouts.removeValue(forKey: requestID)
        lock.unlock()
        guard let continuation else { return } // A late response is ignored after timeout/cancellation.
        timeoutTask?.cancel()
        if let startedAt {
            DispatchQueue.main.async { self.lastLatency = Date().timeIntervalSince(startedAt) }
        }
        continuation.resume(with: result)
    }

    private func failAllPending(with error: Error) {
        lock.lock()
        let requestIDs = Array(pending.keys)
        lock.unlock()
        requestIDs.forEach { finishPending($0, with: .failure(error)) }
    }

    private func handle(listenerState: NWListener.State) {
        if case .failed(let error) = listenerState { publish(error: error) }
    }

    /// TLS 1.3 with a pre-shared key authenticates both peers by possession of the
    /// Keychain-backed pairing secret. No trust-all certificate callback is installed.
    private func secureParameters() throws -> NWParameters {
        guard let pairingSecret = PavlakLinkPairingStore.load() else {
            throw PavlakLinkError.pairingRequired
        }
        return PavlakLinkTLS.parameters(secret: pairingSecret)
    }

    private func publish(state: PavlakLinkConnectionState) { DispatchQueue.main.async { self.remoteState = state } }
    private func publish(error: Error) {
        let message: String
        if let nwError = error as? NWError, case .posix(.EPERM) = nwError {
            message = "Rede Local negada. Autorize o Pavlak nos Ajustes de Privacidade."
        } else { message = error.localizedDescription }
        DispatchQueue.main.async {
            self.errorMessage = message
            self.isTransportEncrypted = false
            self.remoteState = .failed(message)
        }
    }
}

enum PavlakLinkTLS {
    static let identity = Data("com.pavlak.link.paired-device.v1".utf8)

    static func derivedKey(secret: Data) -> Data {
        let salt = Data("com.pavlak.link.tls13.psk.salt.v1".utf8)
        let info = Data("Pavlak Link paired-device transport".utf8)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return derived.withUnsafeBytes { Data($0) }
    }

    static func parameters(secret: Data) -> NWParameters {
        let keyData = derivedKey(secret: secret)
        let psk = keyData.withUnsafeBytes { DispatchData(bytes: $0) }
        let pskIdentity = identity.withUnsafeBytes { DispatchData(bytes: $0) }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions, psk as dispatch_data_t, pskIdentity as dispatch_data_t)
        sec_protocol_options_set_tls_pre_shared_key_identity_hint(tls.securityProtocolOptions, pskIdentity as dispatch_data_t)
        return NWParameters(tls: tls)
    }
}

enum PavlakLinkError: LocalizedError {
    case deviceUnavailable(PavlakDevice)
    case pairingRequired, invalidPairingCode, pairingStorageFailure, authenticationFailed
    case timedOut, connectionClosed
    var errorDescription: String? {
        switch self {
        case .deviceUnavailable(let device): "Pavlak \(device.rawValue) não foi descoberto."
        case .pairingRequired: "Configure o mesmo código de pareamento no Mac e no iPhone antes de usar o Pavlak Link."
        case .invalidPairingCode: "O código de pareamento protegido deve ter pelo menos 16 caracteres."
        case .pairingStorageFailure: "Não foi possível preservar o código de pareamento no Chaveiro."
        case .authenticationFailed: "Uma mensagem do Pavlak Link falhou na autenticação e foi rejeitada."
        case .timedOut: "A consulta ao outro dispositivo excedeu 15 segundos e foi cancelada."
        case .connectionClosed: "A conexão protegida com o outro dispositivo foi encerrada."
        }
    }
}
