#if os(macOS)
import SwiftUI

struct WorkflowResultView: View {
    @ObservedObject var engine: PavlakWorkflowEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Contrato de locação", systemImage: "doc.text.magnifyingglass").font(.headline)
            switch engine.phase {
            case .locating: ProgressView("Localizando o contrato…")
            case .selecting: candidateSelection
            case .extracting: ProgressView("Lendo o documento selecionado…")
            case .summarizing: ProgressView("Preparando o resumo…")
            case .readyToCreate: summaryResult
            case .creating: ProgressView("Criando a versão organizada…")
            case .finished: finalResult
            case .failed(let error): Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .idle: EmptyView()
            }
        }
        .padding(19).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(.primary.opacity(0.065)))
    }

    private var candidateSelection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Qual é o documento correto?").font(.callout.weight(.semibold))
            ForEach(engine.candidates.prefix(5)) { candidate in
                let selected = engine.selectedCandidateID == candidate.id
                Button { engine.selectedCandidateID = candidate.id } label: {
                    HStack {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading) { Text(candidate.file.name).lineLimit(1); Text(candidate.file.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            HStack { Spacer(); Button("Usar este documento", action: engine.confirmAndProcess).buttonStyle(.borderedProminent) }
        }
    }

    private var summaryResult: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(engine.summary).font(.callout).textSelection(.enabled)
            HStack { Spacer(); Button("Criar versão organizada", systemImage: "doc.badge.plus", action: engine.createOrganizedVersion).buttonStyle(.borderedProminent) }
        }
    }

    private var finalResult: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Versão organizada criada", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            if let url = engine.outputURL { Text(url.lastPathComponent).font(.callout.weight(.semibold)); Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
    }
}
#endif
