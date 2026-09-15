import SwiftUI

enum UniversalResultKind: String, CaseIterable, Sendable {
    case file, photo, contact, page, event, text

    var symbol: String {
        switch self {
        case .file: "doc"
        case .photo: "photo"
        case .contact: "person.crop.circle"
        case .page: "safari"
        case .event: "calendar"
        case .text: "text.bubble"
        }
    }
}

enum PavlakResultAction: String, Sendable {
    case preview = "Visualizar"
    case open = "Abrir"
    case share = "Compartilhar"

    var symbol: String {
        switch self {
        case .preview: "eye"
        case .open: "arrow.up.forward.app"
        case .share: "square.and.arrow.up"
        }
    }
}

struct PavlakResultEntity: Identifiable, Sendable {
    let id: String
    let kind: UniversalResultKind
    let title: String
    let type: String
    let location: String?
    let date: Date?
    let actions: [PavlakResultAction]
    let context: PavlakResultContext?

    init(id: String, kind: UniversalResultKind, title: String, type: String, location: String?, date: Date?, actions: [PavlakResultAction], context: PavlakResultContext? = nil) {
        self.id = id; self.kind = kind; self.title = title; self.type = type
        self.location = location; self.date = date; self.actions = actions; self.context = context
    }

    var details: String {
        [type, location, date?.formatted(date: .numeric, time: .omitted)]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • ")
    }
}

struct ActionableResultView: View {
    let entity: PavlakResultEntity
    var onAction: (PavlakResultAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entity.kind.symbol).font(.title2).foregroundStyle(.tint).frame(width: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entity.title).font(.headline).lineLimit(2)
                    Text(entity.details).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
            }
            HStack(spacing: 8) {
                ForEach(entity.actions, id: \.rawValue) { action in
                    if action == .preview {
                        Button(action.rawValue, systemImage: action.symbol) { onAction(action) }.buttonStyle(.borderedProminent)
                    } else {
                        Button(action.rawValue, systemImage: action.symbol) { onAction(action) }.buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.08)))
    }
}

struct UniversalTextResultView: View {
    let title: String
    let message: String
    let kind: UniversalResultKind

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: kind.symbol).font(.title3).foregroundStyle(.tint).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(message).font(.body).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.08)))
    }
}
