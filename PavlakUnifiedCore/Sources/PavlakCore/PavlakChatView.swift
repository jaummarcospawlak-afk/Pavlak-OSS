#if os(macOS) && canImport(SwiftUI)
import SwiftUI

public struct PavlakChatMessage: Identifiable, Equatable, Sendable {
    public enum Role: Sendable, Equatable { case user, assistant }
    public let id: UUID
    public let role: Role
    public var text: String
    public let date: Date

    public init(id: UUID = UUID(), role: Role, text: String, date: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.date = date
    }
}

@MainActor
public final class PavlakChatModel: ObservableObject {
    @Published public private(set) var messages: [PavlakChatMessage] = []
    @Published public private(set) var isRunning = false
    private let engine: PavlakAgentEngine

    public init(engine: PavlakAgentEngine = .shared) {
        self.engine = engine
    }

    public func send(_ text: String) {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !isRunning else { return }
        messages.append(PavlakChatMessage(role: .user, text: command))
        let replyID = UUID()
        messages.append(PavlakChatMessage(id: replyID, role: .assistant, text: "Executando…"))
        isRunning = true

        Task {
            let result = await engine.run(command)
            if let index = messages.firstIndex(where: { $0.id == replyID }) {
                messages[index].text = result
            }
            isRunning = false
        }
    }
}

public struct PavlakChatView: View {
    @StateObject private var model: PavlakChatModel
    @State private var command = ""
    @State private var showingSettings = false

    public init(model: PavlakChatModel = PavlakChatModel()) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pavlak").font(.title2.bold())
                Spacer()
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Conexões e permissões")
            }
            .padding(18)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if model.messages.isEmpty {
                            Text("Como posso ajudar?")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 250)
                        }

                        ForEach(model.messages) { message in
                            HStack {
                                if message.role == .user { Spacer(minLength: 90) }
                                Text(message.text)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(message.role == .user ? Color.accentColor : Color.secondary.opacity(0.12))
                                    .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                if message.role == .assistant { Spacer(minLength: 90) }
                            }
                            .id(message.id)
                        }
                    }
                    .padding(18)
                }
                .onChange(of: model.messages) { messages in
                    if let id = messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }

            Divider()

            HStack(alignment: .bottom, spacing: 10) {
                TextField("Digite uma solicitação", text: $command, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...5)
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .buttonStyle(.plain)
                .disabled(model.isRunning || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(18)
        }
        .frame(minWidth: 660, minHeight: 520)
        .sheet(isPresented: $showingSettings) {
            PavlakSettingsView()
        }
    }

    private func send() {
        let value = command
        command = ""
        model.send(value)
    }
}
#endif
