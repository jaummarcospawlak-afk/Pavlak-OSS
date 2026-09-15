import Foundation

public struct PavlakLocalIntentParser: Sendable {
    public init() {}

    public func plan(for rawCommand: String) -> [PavlakAction]? {
        let original = cleanOriginal(rawCommand)
        let normalized = normalize(original)
        guard !normalized.isEmpty else { return nil }

        if isRecentActionsRequest(normalized) {
            return [.inspectorRecentActions(limit: extractFirstInteger(normalized) ?? 20)]
        }

        if let url = extractURL(from: original),
           containsAny(normalized, ["abra", "abrir", "acesse", "acessar", "visite", "visitar"]) {
            return [.browserOpen(url: url)]
        }

        if let app = appToOpen(from: normalized) {
            return [.appOpen(name: app)]
        }

        if isVisibleWebSearch(normalized), let query = extractSearchQuery(from: original) {
            return [.browserSearch(query: query)]
        }

        // Evita o erro antigo de tratar a galeria como uma pasta comum e devolver centenas de itens.
        if containsAny(normalized, ["foto", "fotos", "galeria", "fototeca", "photo", "imagem", "imagens"]) {
            return nil
        }

        if isFileSearch(normalized), let query = extractFileQuery(from: original) {
            return [.fileFind(query: query, maxResults: 15)]
        }

        return nil
    }

    private func cleanOriginal(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(
            of: #"(?i)^\s*pavla[ck]\s*[,;:\-]?\s*"#,
            with: "",
            options: .regularExpression
        )
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func containsAny(_ text: String, _ values: [String]) -> Bool {
        values.contains { text.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: $0) + #"\b"#, options: .regularExpression) != nil }
    }

    private func isVisibleWebSearch(_ text: String) -> Bool {
        let hasVerb = containsAny(text, ["pesquise", "pesquisar", "busque", "buscar", "procure", "procurar"])
        let hasWebContext = containsAny(text, ["safari", "google", "web", "internet", "navegador"])
        return hasVerb && hasWebContext
    }

    private func isFileSearch(_ text: String) -> Bool {
        let hasVerb = containsAny(text, ["localize", "localizar", "encontre", "encontrar", "procure", "procurar", "busque", "buscar"])
        let hasFileContext = containsAny(text, ["arquivo", "documento", "contrato", "pdf", "pasta", "finder", "desktop", "mesa"])
        return hasVerb && hasFileContext
    }

    private func isRecentActionsRequest(_ text: String) -> Bool {
        containsAny(text, ["historico", "acoes", "inspetor", "relatorio"]) &&
        containsAny(text, ["mostre", "mostrar", "veja", "ver", "ultimas", "recentes"])
    }

    private func appToOpen(from text: String) -> String? {
        guard containsAny(text, ["abra", "abrir", "inicie", "iniciar"]) else { return nil }
        let aliases: [(terms: [String], app: String)] = [
            (["safari"], "Safari"),
            (["finder"], "Finder"),
            (["pages"], "Pages"),
            (["xcode"], "Xcode"),
            (["fotos", "photos"], "Fotos"),
            (["calendario", "calendar"], "Calendário"),
            (["contatos", "contacts"], "Contatos"),
            (["notas", "notes"], "Notas"),
            (["mail", "email"], "Mail"),
            (["ajustes", "configuracoes", "settings"], "Ajustes do Sistema")
        ]
        for entry in aliases where entry.terms.contains(where: { containsAny(text, [$0]) }) {
            return entry.app
        }
        return nil
    }

    private func extractURL(from text: String) -> String? {
        let pattern = #"(?i)\b((?:https?://|www\.)[^\s]+|[a-z0-9][a-z0-9\-]*(?:\.[a-z0-9\-]+)+)(?:\b|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
    }

    private func extractSearchQuery(from text: String) -> String? {
        var result = text
        result = result.replacingOccurrences(
            of: #"(?i)^\s*(pesquise|pesquisar|busque|buscar|procure|procurar)\s+(por\s+)?"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\s+(no|na|pelo|pela)\s+(safari|google|navegador|internet|web)\s*[.!?]*$"#,
            with: "",
            options: .regularExpression
        )
        result = result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return result.isEmpty ? nil : result
    }

    private func extractFileQuery(from text: String) -> String? {
        var result = text
        result = result.replacingOccurrences(
            of: #"(?i)^\s*(localize|localizar|encontre|encontrar|procure|procurar|busque|buscar)\s+"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\b(o|a|os|as|um|uma|meu|minha|meus|minhas|arquivo|documento)\b"#,
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\s+(no|na|dentro do|dentro da)\s+(finder|desktop|mesa|pasta autorizada)\s*[.!?]*$"#,
            with: "",
            options: .regularExpression
        )
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return result.isEmpty ? nil : result
    }

    private func extractFirstInteger(_ text: String) -> Int? {
        guard let range = text.range(of: #"\b\d{1,3}\b"#, options: .regularExpression) else { return nil }
        return Int(text[range]).map { min(max($0, 1), 100) }
    }
}
