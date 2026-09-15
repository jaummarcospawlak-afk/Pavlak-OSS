#if os(macOS)
import SwiftUI

struct FileRecoveryView: View {
    @ObservedObject var model: FileRecoveryViewModel
    @ObservedObject private var index: FileIndexService

    init(model: FileRecoveryViewModel) {
        self.model = model
        self._index = ObservedObject(wrappedValue: model.index)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label("Pavlak File Index", systemImage: "externaldrive.fill.badge.magnifyingglass").font(.headline)
                Spacer(); Text("\(index.snapshot.files.count) arquivos").font(.caption).foregroundStyle(.secondary)
            }
            if index.snapshot.roots.isEmpty {
                Text("Autorize uma pasta para pesquisar somente seus metadados. O conteúdo dos arquivos não será lido durante a indexação.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Selecionar Desktop ou outra pasta", systemImage: "folder.badge.plus") { Task { await index.chooseAndIndexFolder() } }
                    .buttonStyle(.borderedProminent)
            } else {
                Label(index.snapshot.roots.map(\.displayName).joined(separator: ", "), systemImage: "folder.fill.badge.checkmark")
                    .font(.caption).foregroundStyle(.secondary)
                phaseContent
            }
            if let error = index.errorMessage { Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red) }
        }
        .padding(19).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(.primary.opacity(0.065)))
    }

    @ViewBuilder private var phaseContent: some View {
        switch model.phase {
        case .idle: Text("Índice pronto para comandos de recuperação.").font(.callout).foregroundStyle(.secondary)
        case .searching: ProgressView("Pesquisando metadados…")
        case .candidates:
            Text("Confirme o arquivo antes da leitura").font(.callout.weight(.semibold))
            ForEach(model.candidates.prefix(5)) { candidate in
                let isSelected = model.selectedID == candidate.id
                Button { model.selectedID = candidate.id } label: {
                    HStack {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading) { Text(candidate.file.name).lineLimit(1); Text(candidate.file.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer(); Text("\(candidate.score) pts").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            HStack { Spacer(); Button("Ler e resumir selecionado", systemImage: "doc.text.magnifyingglass", action: model.summarizeSelected).buttonStyle(.borderedProminent) }
        case .reading: ProgressView("Lendo o candidato e gerando resumo…")
        case .finished:
            Label("Resumo gerado por \(model.summarizerName)", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            Text(model.summary).font(.callout).textSelection(.enabled)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }
}
#endif
