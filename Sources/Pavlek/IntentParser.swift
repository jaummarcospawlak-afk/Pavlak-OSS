import Foundation

enum PavlekSource: String, CaseIterable, Identifiable, Sendable {
    case unknown = "Pavlak"
    case photos = "Fotos"
    case files = "Arquivos"
    case web = "Safari"
    case notes = "Notas"
    case calendar = "Calendário"
    case mail = "Mail"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .unknown: "sparkles"
        case .photos: "photo.on.rectangle.angled"
        case .files: "folder"
        case .web: "safari"
        case .notes: "note.text"
        case .calendar: "calendar"
        case .mail: "envelope"
        }
    }

    var colorName: String {
        switch self {
        case .unknown: "gray"
        case .photos: "pink"
        case .files: "blue"
        case .web: "blue"
        case .notes: "yellow"
        case .calendar: "red"
        case .mail: "cyan"
        }
    }
}

struct ParsedRequest: Equatable, Sendable {
    let action: String
    let source: PavlekSource
    let object: String
    let period: String
    let originalText: String
    let destination: String?
    let person: String?
    let restrictions: [String]
    let searchScopes: [String]

    init(action: String, source: PavlekSource, object: String, period: String, originalText: String,
         destination: String? = nil, person: String? = nil, restrictions: [String] = [], searchScopes: [String] = []) {
        self.action = action
        self.source = source
        self.object = object
        self.period = period
        self.originalText = originalText
        self.destination = destination
        self.person = person
        self.restrictions = restrictions
        self.searchScopes = searchScopes
    }

    var planSteps: [PlanStep] {
        [
            PlanStep(symbol: "lock.shield", title: "Solicitar acesso temporário", detail: "Apenas leitura em \(source.rawValue) durante esta execução."),
            PlanStep(symbol: "line.3.horizontal.decrease.circle", title: "Localizar \(object.lowercased())", detail: "Aplicar o recorte de tempo “\(period)” e ordenar por relevância."),
            PlanStep(symbol: "sparkles", title: action, detail: "Preparar uma visualização. Nada será alterado ou compartilhado.")
        ]
    }
}

struct PlanStep: Identifiable, Equatable, Sendable {
    let id = UUID()
    let symbol: String
    let title: String
    let detail: String
}

enum PavlakIntentRouter {
    static func parse(_ text: String) -> ParsedRequest {
        let normalized = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))

        let source: PavlekSource
        if containsAny(normalized, ["foto", "galeria", "fototeca", "imagem", "video"]) {
            source = .photos
        } else if containsAny(normalized, ["arquivo", "pasta", "documento", "pdf", "contrato", "desktop", "finder"]) {
            source = .files
        } else if containsAny(normalized, ["http://", "https://", "www.", "site", "pagina web", "safari"]) {
            source = .web
        } else if containsAny(normalized, ["nota", "anotacao"]) {
            source = .notes
        } else if containsAny(normalized, ["agenda", "calendario", "evento", "reuniao"]) {
            source = .calendar
        } else if containsAny(normalized, ["email", "e-mail", "mensagem", "mail"]) {
            source = .mail
        } else {
            source = .unknown
        }

        let action: String
        if containsAny(normalized, ["resuma", "resumir", "resumo"]) {
            action = "Resumir conteúdo encontrado"
        } else if containsAny(normalized, ["compare", "comparar"]) {
            action = "Comparar itens encontrados"
        } else if containsAny(normalized, ["envie", "mande", "compartilhe", "mandar"]) {
            action = "Preparar compartilhamento"
        } else if containsAny(normalized, ["organize", "agrupe", "separe"]) {
            action = "Organizar resultados"
        } else {
            action = "Localizar e apresentar resultados"
        }

        let period = detectPeriod(in: normalized)
        let object = detectObject(for: source, in: normalized)
        let person = detectPerson(in: text, normalized: normalized)
        let destination = source == .web ? detectWebDestination(in: text) : person
        let scopes = detectSearchScopes(in: normalized)
        let restrictions = detectRestrictions(in: normalized, scopes: scopes)
        return ParsedRequest(
            action: action, source: source, object: object, period: period, originalText: text,
            destination: destination, person: person, restrictions: restrictions, searchScopes: scopes
        )
    }

    private static func containsAny(_ text: String, _ terms: [String]) -> Bool {
        terms.contains(where: text.contains)
    }

    private static func detectPeriod(in text: String) -> String {
        let candidates: [(String, String)] = [
            ("hoje", "Hoje"), ("ontem", "Ontem"), ("esta semana", "Esta semana"),
            ("semana passada", "Semana passada"), ("este mes", "Este mês"),
            ("mes passado", "Mês passado"), ("este ano", "Este ano"),
            ("ano passado", "Ano passado"), ("ultimos 7 dias", "Últimos 7 dias"),
            ("ultimos 30 dias", "Últimos 30 dias")
        ]
        return candidates.first(where: { text.contains($0.0) })?.1 ?? "Sem período definido"
    }

    private static func detectObject(for source: PavlekSource, in text: String) -> String {
        if text.contains("contrato") && text.contains("locacao") { return "Contrato de locação" }
        if containsAny(text, ["talao de energia", "conta de energia", "fatura de energia"]) { return "Conta de energia" }
        if containsAny(text, ["esta foto", "essa foto", "foto atual"]) { return "Foto atual" }
        switch source {
        case .unknown: return "Solicitação"
        case .photos:
            if text.contains("video") { return "Vídeos da galeria" }
            if text.contains("captura") { return "Capturas de tela" }
            return "Fotos da galeria"
        case .files:
            if text.contains("pdf") { return "Documentos PDF" }
            return "Arquivos e documentos"
        case .web: return "Página web"
        case .notes: return "Notas"
        case .calendar: return "Eventos"
        case .mail: return "Mensagens"
        }
    }

    private static func detectWebDestination(in text: String) -> String? {
        let pattern = #"(?:https?://|www\.)[^\s]+|[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+(?:/[^\s]*)?"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[range]).trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "/.:_-")))
    }

    private static func detectPerson(in original: String, normalized: String) -> String? {
        guard containsAny(normalized, ["mande", "envie", "compartilhe", "mandar"]) else { return nil }
        guard let range = original.range(of: #"\b(?:para|pro|pra)\s+([\p{L}][\p{L}'’-]*(?:\s+[\p{L}][\p{L}'’-]*)?)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let phrase = String(original[range])
        return phrase.replacingOccurrences(of: #"^(?:para|pro|pra)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    private static func detectSearchScopes(in text: String) -> [String] {
        var scopes: [String] = []
        if containsAny(text, ["talao", "conta", "fatura", "documento"]) { scopes.append("Documentos") }
        if text.contains("album") { scopes.append("Álbuns") }
        if text.contains("pdf") { scopes.append("PDF") }
        return scopes
    }

    private static func detectRestrictions(in text: String, scopes: [String]) -> [String] {
        var restrictions = scopes
        if containsAny(text, ["sem excluir", "nao exclua"]) { restrictions.append("Não excluir") }
        if containsAny(text, ["sem modificar", "nao modifique"]) { restrictions.append("Não modificar") }
        return restrictions
    }
}

enum IntentParser {
    static func parse(_ text: String) -> ParsedRequest { PavlakIntentRouter.parse(text) }
}
