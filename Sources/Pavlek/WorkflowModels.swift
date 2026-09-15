#if os(macOS)
import Foundation

enum WorkflowStepStatus: String, Codable, Sendable { case pending, running, completed, failed }

struct WorkflowStep: Identifiable, Codable, Sendable {
    let id: UUID
    let title: String
    let tool: String
    var input: String
    var result: String?
    let nextStepID: UUID?
    var status: WorkflowStepStatus
}

struct PavlakWorkflow: Identifiable, Codable, Sendable {
    let id: UUID
    let objective: String
    var steps: [WorkflowStep]
}

enum WorkflowEngineError: LocalizedError {
    case invalidTransition, noCandidate, cancelled
    var errorDescription: String? {
        switch self {
        case .invalidTransition: "A etapa anterior ainda não produziu um resultado válido."
        case .noCandidate: "Nenhum documento compatível foi localizado."
        case .cancelled: "A criação do documento foi cancelada."
        }
    }
}
#endif
