import Foundation

enum IOSCommandRouting {
    static func openPosition(_ text: String) -> Int? {
        let normalized = PhotoDocumentQuery.normalize(text)
        let ordinals = ["primeiro", "segundo", "terceiro", "quarto", "quinto"]
        return ordinals.firstIndex { normalized == "abra o \($0)" || normalized == "abrir o \($0)" }
    }
    static func opensSelection(_ text: String) -> Bool {
        ["abra esse", "abra este", "abra aquele", "abra o selecionado", "abrir selecionado"].contains(PhotoDocumentQuery.normalize(text))
    }
    static func isSearch(_ text: String) -> Bool {
        var words = PhotoDocumentQuery.normalize(text).split(separator: " ").map(String.init)
        if let first = words.first, ["pavlak", "pavlek"].contains(first) { words.removeFirst() }
        guard let first = words.first else { return false }
        return ["encontre", "localize", "ache", "procure", "busque", "pesquise", "buscar"].contains(first)
    }
    static func isQuestion(_ text: String) -> Bool {
        let n = PhotoDocumentQuery.normalize(text)
        let starters = ["qual ", "quais ", "quem ", "como ", "por que ", "quanto ", "quando ", "explique", "resuma", "o que ", "ola", "oi"]
        return starters.contains { n == $0.trimmingCharacters(in: .whitespaces) || n.hasPrefix($0) }
    }
}
