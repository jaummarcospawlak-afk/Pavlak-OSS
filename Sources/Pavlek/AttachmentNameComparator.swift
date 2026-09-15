import Foundation

enum AttachmentNameComparator {
    static func commonNames(in texts: [String]) -> [String] {
        guard !texts.isEmpty else { return [] }
        let maps = texts.map(names)
        let common = maps.dropFirst().reduce(Set(maps[0].keys)) { $0.intersection($1.keys) }
        return common.sorted().compactMap { maps[0][$0] }
    }

    private static func names(in text: String) -> [String: String] {
        let pattern = #"[A-ZÁÀÂÃÉÊÍÓÔÕÚÇ][a-záàâãéêíóôõúç]+\s+[A-ZÁÀÂÃÉÊÍÓÔÕÚÇ][a-záàâãéêíóôõúç]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [:] }
        let ignored = ["contrato de locacao", "locador e locatario", "registro de imoveis", "republica federativa"]
        var result: [String: String] = [:]
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalize(value)
            if !ignored.contains(key), value.count <= 80 { result[key] = value }
        }
        return result
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
