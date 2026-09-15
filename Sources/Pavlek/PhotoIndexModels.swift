import Foundation

enum IndexedPhotoCategory: String, Codable, Sendable {
    case document = "Documentos"
    case other = "Outros"
    case pendingCloud = "Pendente no iCloud"
    case unknown = "Não classificado"
}

enum PhotoIndexSourceKind: String, Codable, Sendable { case photoLibrary }

enum PhotoContentAvailability: String, Codable, Sendable {
    case local, cloudOnly, unavailable
}

enum PhotoProcessingState: String, Codable, Sendable {
    case pending, processing, processed, waitingForLocalContent, interrupted, failed
}

enum PhotoIndexAuthorizationScope: String, Codable, Sendable {
    case notDetermined, denied, restricted, limited, authorized
    var canRead: Bool { self == .limited || self == .authorized }
}

enum PhotoIndexUpdateState: String, Codable, Sendable { case idle, inProgress, interrupted }
enum PhotoIndexStorageAuthority: String, Codable, Sendable { case transactionalJSON }

struct PhotoAlbumAssociationEvidence: Codable, Equatable, Sendable, Identifiable {
    let albumLocalIdentifier: String
    let title: String
    let observedAt: Date
    let provider: String
    var id: String { albumLocalIdentifier }
}

struct PhotoOriginalMetadataEvidence: Codable, Equatable, Sendable {
    let provider: String
    let observedAt: Date
    let assetLocalIdentifier: String
}

struct PhotoExtractedTextEvidence: Codable, Equatable, Sendable {
    let text: String
    let normalizedText: String
    let extractor: String
    let extractedAt: Date
}

struct PhotoClassificationEvidence: Codable, Equatable, Sendable {
    let category: IndexedPhotoCategory
    let classifier: String
    let basis: String
    let confidence: Double
    let classifiedAt: Date
}

enum PhotoStableIdentifier {
    static func make(deviceID: String, assetLocalIdentifier: String) -> String {
        let input = "\(deviceID)\u{1f}\(assetLocalIdentifier)"
        let hash = input.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return "pavlak-photo-\(String(hash, radix: 16))"
    }
}

struct IndexedPhoto: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let sourceLocalIdentifier: String
    let sourceDeviceID: String
    let sourceDevice: PavlakDevice
    let sourceKind: PhotoIndexSourceKind
    let contentType: String
    let creationDate: Date?
    let modificationDate: Date?
    let width: Int
    let height: Int
    let originalFilename: String?
    let albumAssociations: [PhotoAlbumAssociationEvidence]
    let originalEvidence: PhotoOriginalMetadataEvidence
    var category: IndexedPhotoCategory
    var normalizedOCRText: String
    var extractedTextEvidence: PhotoExtractedTextEvidence?
    var classificationEvidence: PhotoClassificationEvidence?
    var contentAvailability: PhotoContentAvailability
    var processingState: PhotoProcessingState
    var processingError: String?
    var indexedAt: Date
    let sourceFingerprint: String

    init(
        id: String, sourceLocalIdentifier: String, sourceDeviceID: String,
        sourceDevice: PavlakDevice = .iPhone, sourceKind: PhotoIndexSourceKind = .photoLibrary,
        contentType: String, creationDate: Date?, modificationDate: Date?, width: Int, height: Int,
        originalFilename: String?, albumAssociations: [PhotoAlbumAssociationEvidence],
        originalEvidence: PhotoOriginalMetadataEvidence, category: IndexedPhotoCategory,
        normalizedOCRText: String, extractedTextEvidence: PhotoExtractedTextEvidence?,
        classificationEvidence: PhotoClassificationEvidence?, contentAvailability: PhotoContentAvailability,
        processingState: PhotoProcessingState, processingError: String? = nil,
        indexedAt: Date, sourceFingerprint: String
    ) {
        self.id = id; self.sourceLocalIdentifier = sourceLocalIdentifier; self.sourceDeviceID = sourceDeviceID
        self.sourceDevice = sourceDevice; self.sourceKind = sourceKind; self.contentType = contentType
        self.creationDate = creationDate; self.modificationDate = modificationDate
        self.width = width; self.height = height; self.originalFilename = originalFilename
        self.albumAssociations = albumAssociations; self.originalEvidence = originalEvidence
        self.category = category; self.normalizedOCRText = normalizedOCRText
        self.extractedTextEvidence = extractedTextEvidence; self.classificationEvidence = classificationEvidence
        self.contentAvailability = contentAvailability; self.processingState = processingState
        self.processingError = processingError; self.indexedAt = indexedAt; self.sourceFingerprint = sourceFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case id, sourceLocalIdentifier, sourceDeviceID, sourceDevice, sourceKind, contentType
        case creationDate, modificationDate, width, height, originalFilename
        case albumAssociations, originalEvidence, category, normalizedOCRText
        case extractedTextEvidence, classificationEvidence, contentAvailability
        case processingState, processingError, indexedAt, sourceFingerprint
    }

    private enum LegacyCodingKeys: String, CodingKey { case mediaType }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let legacyValues = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let legacyID = try values.decode(String.self, forKey: .id)
        let localID = try values.decodeIfPresent(String.self, forKey: .sourceLocalIdentifier) ?? legacyID
        let observedAt = try values.decodeIfPresent(Date.self, forKey: .indexedAt) ?? Date.distantPast
        id = legacyID
        sourceLocalIdentifier = localID
        sourceDeviceID = try values.decodeIfPresent(String.self, forKey: .sourceDeviceID) ?? "legacy-device"
        sourceDevice = try values.decodeIfPresent(PavlakDevice.self, forKey: .sourceDevice) ?? .iPhone
        sourceKind = try values.decodeIfPresent(PhotoIndexSourceKind.self, forKey: .sourceKind) ?? .photoLibrary
        contentType = try values.decodeIfPresent(String.self, forKey: .contentType)
            ?? legacyValues.decodeIfPresent(String.self, forKey: .mediaType) ?? "public.image"
        creationDate = try values.decodeIfPresent(Date.self, forKey: .creationDate)
        modificationDate = try values.decodeIfPresent(Date.self, forKey: .modificationDate)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        originalFilename = try values.decodeIfPresent(String.self, forKey: .originalFilename)
        albumAssociations = try values.decodeIfPresent([PhotoAlbumAssociationEvidence].self, forKey: .albumAssociations) ?? []
        originalEvidence = try values.decodeIfPresent(PhotoOriginalMetadataEvidence.self, forKey: .originalEvidence)
            ?? .init(provider: "PhotoKit", observedAt: observedAt, assetLocalIdentifier: localID)
        category = try values.decodeIfPresent(IndexedPhotoCategory.self, forKey: .category) ?? .unknown
        normalizedOCRText = try values.decodeIfPresent(String.self, forKey: .normalizedOCRText) ?? ""
        extractedTextEvidence = try values.decodeIfPresent(PhotoExtractedTextEvidence.self, forKey: .extractedTextEvidence)
        classificationEvidence = try values.decodeIfPresent(PhotoClassificationEvidence.self, forKey: .classificationEvidence)
        contentAvailability = try values.decodeIfPresent(PhotoContentAvailability.self, forKey: .contentAvailability)
            ?? (category == .pendingCloud ? .cloudOnly : .local)
        processingState = try values.decodeIfPresent(PhotoProcessingState.self, forKey: .processingState)
            ?? (category == .pendingCloud ? .waitingForLocalContent : .processed)
        processingError = try values.decodeIfPresent(String.self, forKey: .processingError)
        indexedAt = observedAt
        sourceFingerprint = try values.decodeIfPresent(String.self, forKey: .sourceFingerprint) ?? ""
    }
}

struct PhotoIndexSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2
    var schemaVersion = currentSchemaVersion
    var sourceDeviceID = ""
    var storageAuthority = PhotoIndexStorageAuthority.transactionalJSON
    var generation = 0
    var assets: [IndexedPhoto] = []
    var lastIncrementalUpdate: Date?
    var lastCompletedUpdate: Date?
    var initialIndexDuration: TimeInterval?
    var updateState = PhotoIndexUpdateState.idle
    var authorizationScope = PhotoIndexAuthorizationScope.notDetermined
    var recoveryNotice: String?

    init() { }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sourceDeviceID, storageAuthority, generation, assets
        case lastIncrementalUpdate, lastCompletedUpdate, initialIndexDuration
        case updateState, authorizationScope, recoveryNotice
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        sourceDeviceID = try values.decodeIfPresent(String.self, forKey: .sourceDeviceID) ?? "legacy-device"
        storageAuthority = try values.decodeIfPresent(PhotoIndexStorageAuthority.self, forKey: .storageAuthority) ?? .transactionalJSON
        generation = try values.decodeIfPresent(Int.self, forKey: .generation) ?? 0
        assets = try values.decodeIfPresent([IndexedPhoto].self, forKey: .assets) ?? []
        lastIncrementalUpdate = try values.decodeIfPresent(Date.self, forKey: .lastIncrementalUpdate)
        lastCompletedUpdate = try values.decodeIfPresent(Date.self, forKey: .lastCompletedUpdate)
        initialIndexDuration = try values.decodeIfPresent(TimeInterval.self, forKey: .initialIndexDuration)
        updateState = try values.decodeIfPresent(PhotoIndexUpdateState.self, forKey: .updateState) ?? .idle
        authorizationScope = try values.decodeIfPresent(PhotoIndexAuthorizationScope.self, forKey: .authorizationScope) ?? .notDetermined
        recoveryNotice = try values.decodeIfPresent(String.self, forKey: .recoveryNotice)
    }

    var documentCount: Int { assets.lazy.filter { $0.category == .document && $0.processingState == .processed }.count }
    var pendingContentCount: Int { assets.lazy.filter { $0.processingState == .waitingForLocalContent || $0.processingState == .interrupted }.count }
}

struct PhotoSearchMatch: Identifiable, Equatable, Sendable {
    let id: String
    let sourceLocalIdentifier: String
    let sourceDeviceID: String
    let sourceDevice: PavlakDevice
    let sourceKind: PhotoIndexSourceKind
    let score: Int
    let filename: String?
    let date: Date?
    let dimensions: String
    let textPreview: String
    let albumTitles: [String]
    let processingState: PhotoProcessingState
    let contentAvailability: PhotoContentAvailability
    let evidenceSummary: String
    let indexGeneration: Int
    let authorizationScope: PhotoIndexAuthorizationScope
    let sourceFingerprint: String

    var documentTypeHint: String? = nil
    var holderMatchEvidence: String? = nil

    var canPreviewLocally: Bool { contentAvailability == .local && processingState == .processed }
    var originDescription: String { "\(sourceDevice.rawValue) • Fotos • \(sourceDeviceID)" }
}

/// Local lexical hints, never a verified document class or proof of ownership.
struct PhotoDocumentQuery {
    enum Kind: String, CaseIterable {
        case identity, drivingLicense, residence, contract, receipt, marriage
        var title: String {
            switch self {
            case .identity: "Identidade"
            case .drivingLicense: "CNH"
            case .residence: "Comprovante de residência"
            case .contract: "Contrato"
            case .receipt: "Comprovante de pagamento"
            case .marriage: "Certidão de casamento"
            }
        }
        var phrases: [String] {
            switch self {
            case .identity: ["carteira de identidade", "registro geral", "identidade", "rg"]
            case .drivingLicense: ["carteira nacional de habilitacao", "carteira de motorista", "cnh"]
            case .residence: ["comprovante de residencia", "comprovante de endereco", "conta de energia", "conta de luz", "conta de agua"]
            case .contract: ["instrumento contratual", "contrato"]
            case .receipt: ["comprovante de pagamento", "comprovante de transferencia", "recibo"]
            case .marriage: ["certidao de casamento", "registro de casamento"]
            }
        }
        var contentSignals: [String] {
            switch self {
            case .residence: phrases + ["unidade consumidora", "energia eletrica", "kwh"]
            default: phrases
            }
        }
    }
    let kind: Kind?
    let terms: [String]
    let holderTerms: [String]
    let detailTerms: [String]

    init(_ query: String) {
        let normalized = Self.normalize(query)
        let matches = Kind.allCases.flatMap { kind in
            kind.phrases.filter { Self.contains(normalized, phrase: $0) }.map { (kind, $0) }
        }
        let match = matches.max { $0.1.count < $1.1.count }
        kind = match?.0
        var remainder = normalized
        if let phrase = match?.1 { remainder = (" " + remainder + " ").replacingOccurrences(of: " " + phrase + " ", with: " ") }
        let ignored: Set<String> = ["localize", "localizar", "encontre", "encontrar", "buscar", "busque", "procure", "procurar", "pesquise", "ache", "minha", "meu", "galeria", "foto", "fotos", "documento", "documentos", "do", "da", "de", "dos", "das", "o", "a", "os", "as", "no", "na", "nos", "nas", "em", "para", "por", "favor", "pavlak", "pavlek", "titular", "nome"]
        let details = remainder.split(separator: " ").map(String.init).filter { !ignored.contains($0) }
        detailTerms = details
        // Subject/date words must remain content constraints, not become a person's
        // name merely because they follow a document type (“contrato do lote”).
        let subjectWords: Set<String> = ["lote", "lotes", "terreno", "terrenos", "imovel", "imoveis", "endereco", "rua", "avenida", "bairro", "cidade", "apartamento", "casa", "matricula", "numero", "valor", "pagamento", "aluguel", "locacao", "compra", "venda", "hoje", "ontem", "amanha", "data", "vencimento", "mes", "ano", "janeiro", "fevereiro", "marco", "abril", "maio", "junho", "julho", "agosto", "setembro", "outubro", "novembro", "dezembro"]
        let explicitPattern = #"(?:^| )(?:nome do titular|titular|nome) (.+)$"#
        if match != nil,
           let range = normalized.range(of: explicitPattern, options: .regularExpression),
           let regex = try? NSRegularExpression(pattern: explicitPattern),
           let result = regex.firstMatch(in: normalized, range: NSRange(range, in: normalized)),
           let valueRange = Range(result.range(at: 1), in: normalized) {
            holderTerms = normalized[valueRange].split(separator: " ").map(String.init).filter { !ignored.contains($0) }
        } else if match != nil && details.allSatisfy({ !subjectWords.contains($0) && !$0.allSatisfy(\.isNumber) }) {
            holderTerms = details
        } else {
            holderTerms = []
        }
        let categoryTerms = match.map { $0.0.contentSignals.flatMap { $0.split(separator: " ").map(String.init) }.filter { !ignored.contains($0) } } ?? []
        terms = Array(Set(categoryTerms + details)).sorted()
    }

    var holderEvidence: String? {
        guard !holderTerms.isEmpty else { return nil }
        return "Todos os termos solicitados aparecem no OCR: “\(holderTerms.joined(separator: " "))”. Titularidade não confirmada; confira os campos no original."
    }

    func matches(extracted: String, metadata: String, rawText: String? = nil) -> Bool {
        if let kind {
            guard kind.contentSignals.contains(where: { Self.contains(extracted, phrase: $0) }) else { return false }
            guard detailTerms.allSatisfy({ Self.contains(extracted, phrase: $0) }) else { return false }
            if !holderTerms.isEmpty, let rawText {
                let labeled = Self.labeledHolders(in: rawText)
                if !labeled.isEmpty {
                    return labeled.contains { value in
                        holderTerms.allSatisfy { Self.contains(Self.normalize(value), phrase: $0) }
                    }
                }
            }
            return true
        }
        return terms.contains { Self.contains(extracted, phrase: $0) || Self.contains(metadata, phrase: $0) }
    }

    func holderEvidence(in rawText: String) -> String? {
        guard !holderTerms.isEmpty else { return nil }
        if let value = Self.labeledHolders(in: rawText).first(where: { value in
            holderTerms.allSatisfy { Self.contains(Self.normalize(value), phrase: $0) }
        }) {
            return "Campo Nome/Titular observado no OCR: “\(value)”. Correspondência textual; confira o campo no original. Titularidade não confirmada."
        }
        return holderEvidence
    }

    /// Only explicit field labels at line starts count. Names of parents and witness
    /// sections are not promoted to holders. This remains fallible OCR evidence.
    static func labeledHolders(in rawText: String) -> [String] {
        let lines = rawText.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var output: [String] = []
        var witnessSection = false
        let pattern = #"(?i)^(nome do titular|titular|nome)(?:\s*[:：-]\s*(.*)|\s*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for (index, line) in lines.enumerated() {
            let normalized = normalize(line)
            if normalized.hasPrefix("testemunha") { witnessSection = true; continue }
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let labelRange = Range(match.range(at: 1), in: line) else { continue }
            let label = normalize(String(line[labelRange]))
            if label != "nome" { witnessSection = false }
            guard !witnessSection else { continue }
            var value = Range(match.range(at: 2), in: line).map { String(line[$0]) } ?? ""
            if value.isEmpty, index + 1 < lines.count {
                let next = lines[index + 1]
                // Do not consume another field label as a person's name.
                if !next.contains(":") && !next.contains("：") { value = next }
            }
            // A subsequent field on the same OCR line must not supply a witness name.
            if let boundary = value.range(of: #"(?i)\s+(?:testemunhas?|cpf|rg|assinatura|filiacao|filiação)\s*[:：-]"#, options: .regularExpression) {
                value = String(value[..<boundary.lowerBound])
            }
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { output.append(String(value.prefix(200))) }
        }
        return output
    }

    static func contains(_ text: String, phrase: String) -> Bool {
        (" " + text + " ").contains(" " + phrase + " ")
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }
}

enum PhotoIndexQueryEngine {
    static func search(query: String, in snapshot: PhotoIndexSnapshot, limit: Int = 8) -> [PhotoSearchMatch] {
        let request = PhotoDocumentQuery(query)
        let terms = request.terms
        guard !terms.isEmpty else { return [] }

        return snapshot.assets.compactMap { item in
            guard item.processingState == .processed || item.processingState == .waitingForLocalContent else {
                return nil
            }
            let original = normalize([
                item.originalFilename,
                item.albumAssociations.map(\.title).joined(separator: " ")
            ].compactMap { $0 }.joined(separator: " "))
            // Only structured extraction evidence is queried as extracted content. A legacy
            // normalized string remains preserved, but is not silently promoted to new evidence.
            let extracted = normalize(item.extractedTextEvidence?.normalizedText ?? "")
            // Requested identity terms must be present in OCR, not merely an album/filename.
            guard request.matches(extracted: extracted, metadata: original, rawText: item.extractedTextEvidence?.text) else { return nil }
            let originalScore = terms.reduce(0) { $0 + (PhotoDocumentQuery.contains(original, phrase: $1) ? 5 : 0) }
            let extractedScore = terms.reduce(0) { $0 + (PhotoDocumentQuery.contains(extracted, phrase: $1) ? 8 : 0) }
            let score = originalScore + extractedScore
            guard score > 0 else { return nil }
            let evidence = [
                originalScore > 0 ? "metadados originais PhotoKit" : nil,
                extractedScore > 0 ? "texto extraído por \(item.extractedTextEvidence?.extractor ?? "extrator registrado")" : nil,
                item.classificationEvidence.map { "classificação inferida por \($0.classifier)" },
                request.kind.map { "tipo candidato: \($0.title); conferir original" },
                request.holderEvidence(in: item.extractedTextEvidence?.text ?? "")
            ].compactMap { $0 }.joined(separator: " • ")
            return PhotoSearchMatch(
                id: item.id, sourceLocalIdentifier: item.sourceLocalIdentifier,
                sourceDeviceID: item.sourceDeviceID, sourceDevice: item.sourceDevice,
                sourceKind: item.sourceKind, score: score, filename: item.originalFilename,
                date: item.creationDate, dimensions: "\(item.width) × \(item.height)",
                textPreview: String(extracted.prefix(180)), albumTitles: item.albumAssociations.map(\.title),
                processingState: item.processingState, contentAvailability: item.contentAvailability,
                evidenceSummary: evidence, indexGeneration: snapshot.generation,
                authorizationScope: snapshot.authorizationScope,
                sourceFingerprint: item.sourceFingerprint,
                documentTypeHint: request.kind?.title,
                holderMatchEvidence: request.holderEvidence(in: item.extractedTextEvidence?.text ?? "")
            )
        }
        .sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return ($0.date ?? .distantPast) > ($1.date ?? .distantPast)
        }
        .prefix(min(5, max(1, limit))).map { $0 }
    }

    static func match(stableID: String, in snapshot: PhotoIndexSnapshot) -> PhotoSearchMatch? {
        guard let item = snapshot.assets.first(where: { $0.id == stableID }),
              item.processingState == .processed || item.processingState == .waitingForLocalContent else {
            return nil
        }
        let evidence = [
            "identidade e metadados originais PhotoKit",
            item.extractedTextEvidence.map { "texto extraído por \($0.extractor)" },
            item.classificationEvidence.map { "classificação inferida por \($0.classifier)" }
        ].compactMap { $0 }.joined(separator: " • ")
        return PhotoSearchMatch(
            id: item.id, sourceLocalIdentifier: item.sourceLocalIdentifier,
            sourceDeviceID: item.sourceDeviceID, sourceDevice: item.sourceDevice,
            sourceKind: item.sourceKind, score: 0, filename: item.originalFilename,
            date: item.creationDate, dimensions: "\(item.width) × \(item.height)",
            textPreview: String((item.extractedTextEvidence?.normalizedText ?? "").prefix(180)),
            albumTitles: item.albumAssociations.map(\.title), processingState: item.processingState,
            contentAvailability: item.contentAvailability, evidenceSummary: evidence,
            indexGeneration: snapshot.generation, authorizationScope: snapshot.authorizationScope,
            sourceFingerprint: item.sourceFingerprint
        )
    }

    private static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }
}

struct IndexRunReport: Sendable {
    let visibleAssetCount: Int
    let newlyIndexedCount: Int
    let changedAssetCount: Int
    let removedAssetCount: Int
    let documentCount: Int
    let pendingCloudCount: Int
    let elapsed: TimeInterval
    let indexByteCount: Int64
    let authorizationScope: PhotoIndexAuthorizationScope
}

enum PhotoIndexError: LocalizedError {
    case accessDenied, indexUnavailable, inconsistentIndex
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .accessDenied: "O acesso à Fototeca não permite consultar itens."
        case .indexUnavailable: "O Pavlak Photo Index não está disponível."
        case .inconsistentIndex: "O índice local estava inconsistente e foi isolado para recuperação."
        case .unsupportedSchema(let version): "A versão \(version) do índice ainda não é compatível."
        }
    }
}
