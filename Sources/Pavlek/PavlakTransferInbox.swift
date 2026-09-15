import Foundation

@MainActor
final class PavlakTransferInbox: ObservableObject {
    static let shared = PavlakTransferInbox()
    static let maximumItems = 10

    struct Item: Identifiable, Equatable {
        let id: UUID
        let filename: String
        let contentType: String
        let data: Data
        let receivedAt: Date
    }

    @Published private(set) var items: [Item] = []

    func receive(_ message: PavlakLinkMessage) -> PavlakLinkMessage {
        guard message.action == .stageTransfer,
              message.sourceDevice == .iPhone,
              message.targetDevice == .mac else {
            return message.response(status: .failure, result: PavlakTransferError.invalidRoute.localizedDescription)
        }
        do {
            guard let payloadText = message.payload,
                  let payloadData = payloadText.data(using: .utf8) else { throw PavlakTransferError.invalidPayload }
            let payload = try JSONDecoder().decode(PavlakTransferPayload.self, from: payloadData).validated()
            items.removeAll { $0.id == payload.itemID }
            items.insert(Item(id: payload.itemID, filename: payload.filename, contentType: payload.contentType,
                              data: payload.data, receivedAt: Date()), at: 0)
            if items.count > Self.maximumItems { items.removeLast(items.count - Self.maximumItems) }
            let receipt = PavlakTransferReceipt(itemID: payload.itemID, state: "staged")
            let data = try JSONEncoder().encode(receipt)
            return message.response(status: .success, result: String(data: data, encoding: .utf8))
        } catch {
            return message.response(status: .failure, result: error.localizedDescription)
        }
    }

    func remove(_ id: UUID) { items.removeAll { $0.id == id } }
    func clear() { items.removeAll() }
}
