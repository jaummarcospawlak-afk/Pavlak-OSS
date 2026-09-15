import Foundation
import Combine

@MainActor
final class IOSChatState: ObservableObject {
    @Published private(set) var messages: [IOSChatMessage] = []
    @Published private(set) var selection: IOSChatSelection?
    @Published private(set) var allowsExcerpt = false
    @Published private(set) var isSending = false
    @Published private(set) var errorMessage: String?
    private let client: any IOSChatResponding
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(client: any IOSChatResponding = IOSChatClient()) { self.client = client }

    func select(_ item: IOSChatSelection?) {
        guard item != selection else { return }
        clear()
        selection = item
        allowsExcerpt = false
    }

    func setAllowsExcerpt(_ enabled: Bool) {
        let next = enabled && selection != nil
        guard next != allowsExcerpt else { return }
        // Revoking consent must also discard answers that may repeat the previous excerpt.
        clear()
        allowsExcerpt = next
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }
        errorMessage = nil
        messages.append(.init(role: .user, text: trimmed))
        messages = Array(messages.suffix(12))
        isSending = true
        let token = UUID()
        generation = token
        let submittedMessages = messages
        let selected = selection
        let consent = allowsExcerpt
        task = Task { [weak self, client] in
            do {
                let response = try await client.respond(messages: submittedMessages, selection: selected, allowsExcerpt: consent)
                guard let self, self.generation == token else { return }
                guard !Task.isCancelled else {
                    self.isSending = false
                    self.task = nil
                    return
                }
                self.messages.append(.init(role: .assistant, text: response))
                self.messages = Array(self.messages.suffix(12))
                self.isSending = false
                self.task = nil
            } catch {
                guard let self, self.generation == token else { return }
                self.isSending = false
                self.task = nil
                if !Task.isCancelled {
                    // Never expose raw transport/server errors or credentials.
                    self.errorMessage = (error as? IOSChatError ?? .network).localizedDescription
                }
            }
        }
        let activeTask = task
        await withTaskCancellationHandler {
            await activeTask?.value
        } onCancel: {
            activeTask?.cancel()
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        isSending = false
    }

    func clear() {
        cancel()
        messages = []
        errorMessage = nil
    }

    func waitForCurrentRequest() async { await task?.value }
}
