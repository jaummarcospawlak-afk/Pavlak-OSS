import Foundation

enum PavlakDevice: String, Codable, Sendable {
    case mac, iPhone
}

enum PavlakLinkAction: String, Codable, Sendable {
    case hello
    case ping
    case photoSearch = "photo.search"
    case fileSearch = "file.search"
    case stageTransfer = "transfer.stage"
}

struct PavlakTransferPayload: Codable, Sendable, Equatable {
    static let maximumByteCount = 512 * 1_024

    let itemID: UUID
    let filename: String
    let contentType: String
    let byteCount: Int
    let data: Data

    init(itemID: UUID = UUID(), filename: String, contentType: String, data: Data) throws {
        let cleanName = URL(fileURLWithPath: filename).lastPathComponent
        guard !cleanName.isEmpty, cleanName == filename else { throw PavlakTransferError.invalidFilename }
        guard !contentType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PavlakTransferError.invalidContentType }
        guard !data.isEmpty else { throw PavlakTransferError.emptyData }
        guard data.count <= Self.maximumByteCount else { throw PavlakTransferError.payloadTooLarge }
        self.itemID = itemID
        self.filename = cleanName
        self.contentType = contentType
        self.byteCount = data.count
        self.data = data
    }

    func validated() throws -> PavlakTransferPayload {
        guard byteCount == data.count else { throw PavlakTransferError.byteCountMismatch }
        return try PavlakTransferPayload(itemID: itemID, filename: filename, contentType: contentType, data: data)
    }
}

struct PavlakTransferReceipt: Codable, Sendable, Equatable {
    let itemID: UUID
    let state: String
}

enum PavlakTransferError: LocalizedError, Equatable {
    case invalidFilename, invalidContentType, emptyData, payloadTooLarge, byteCountMismatch, invalidRoute, invalidPayload

    var errorDescription: String? {
        switch self {
        case .invalidFilename: "O nome do item transferido não é seguro."
        case .invalidContentType: "O tipo do item transferido não foi informado."
        case .emptyData: "O item transferido está vazio."
        case .payloadTooLarge: "O item excede o limite temporário de 512 KB."
        case .byteCountMismatch: "O tamanho informado não corresponde ao conteúdo recebido."
        case .invalidRoute: "A transferência não veio do iPhone para a bandeja do Mac."
        case .invalidPayload: "A transferência recebida não pôde ser validada."
        }
    }
}

enum PavlakLinkConnectionState: Equatable, Sendable {
    case idle, discovering, found, connecting, connected, failed(String)

    var title: String {
        switch self {
        case .idle, .discovering: "Descobrindo iPhone…"
        case .found: "iPhone encontrado"
        case .connecting: "Conectando…"
        case .connected: "Pavlak Link conectado"
        case .failed(let error): error
        }
    }
}

enum PavlakLinkStatus: String, Codable, Sendable {
    case requested, executing, success, failure
}

struct PavlakLinkMessage: Identifiable, Codable, Sendable {
    let requestID: UUID
    let sourceDevice: PavlakDevice
    let targetDevice: PavlakDevice
    let action: PavlakLinkAction
    let query: String
    let payload: String?
    let status: PavlakLinkStatus
    let result: String?
    let sentAt: Date
    let authentication: PavlakLinkAuthentication?

    init(
        requestID: UUID, sourceDevice: PavlakDevice, targetDevice: PavlakDevice,
        action: PavlakLinkAction, query: String, payload: String?, status: PavlakLinkStatus,
        result: String?, sentAt: Date, authentication: PavlakLinkAuthentication? = nil
    ) {
        self.requestID = requestID; self.sourceDevice = sourceDevice; self.targetDevice = targetDevice
        self.action = action; self.query = query; self.payload = payload; self.status = status
        self.result = result; self.sentAt = sentAt; self.authentication = authentication
    }

    var id: UUID { requestID }

    func response(status: PavlakLinkStatus, result: String?) -> PavlakLinkMessage {
        PavlakLinkMessage(requestID: requestID, sourceDevice: targetDevice, targetDevice: sourceDevice,
                          action: action, query: query, payload: nil, status: status, result: result, sentAt: Date())
    }
}

struct PavlakLinkPhotoCandidate: Codable, Sendable {
    let stableID: String
    let sourceLocalIdentifier: String
    let sourceDeviceID: String
    let sourceDevice: PavlakDevice
    let sourceKind: String
    let sourceLocation: String
    let score: Int
    let date: Date?
    let filename: String?
    let textPreview: String
    let processingState: String
    let evidenceSummary: String

    var assetID: String { stableID }
}

struct PavlakLinkFileCandidate: Codable, Sendable {
    let stableID: String
    let fileID: String
    let sourceDeviceID: String
    let sourceDevice: PavlakDevice
    let sourceLocation: String
    let score: Int
    let name: String
    let relativePath: String
    let fileExtension: String
    let modifiedAt: Date?
    let evidenceSummary: String
}
