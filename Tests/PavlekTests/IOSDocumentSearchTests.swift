import XCTest
@testable import Pavlek

final class IOSDocumentSearchTests: XCTestCase {
    func testShortRGQueryFindsIdentityOCRButNotEmbeddedLetters() {
        XCTAssertEqual(search("RG", texts: ["REGISTRO GERAL Nome Ana Silva", "energia solar"]).count, 1)
    }

    func testRequestedHolderRequiresEveryWholeTokenInOCR() {
        let results = search("encontre o RG de Ana Silva", texts: [
            "REGISTRO GERAL Nome ANA SILVA", "REGISTRO GERAL Nome Ana Souza",
            "REGISTRO GERAL Nome Mariana Silva", "CNH Nome Ana Silva"
        ])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.documentTypeHint, "Identidade")
        XCTAssertTrue(results.first?.holderMatchEvidence?.contains("Titularidade não confirmada") == true)
    }

    func testFilenameCannotSupplyMissingHolderOrType() {
        var snapshot = PhotoIndexSnapshot()
        snapshot.assets = [record("REGISTRO GERAL Nome Ana Souza", name: "RG Ana Silva.jpg"),
                           record("Ana Silva", name: "RG Ana Silva 2.jpg")]
        XCTAssertTrue(PhotoIndexQueryEngine.search(query: "RG de Ana Silva", in: snapshot).isEmpty)
    }

    func testAccentsCaseAndLongDocumentTypeAliases() {
        XCTAssertEqual(search("CNH de Marina Teste", texts: ["CARTEIRA NACIONAL DE HABILITAÇÃO MARINA TESTE"]).count, 1)
        XCTAssertEqual(search("comprovante de residência de Marina", texts: ["ENERGIA ELÉTRICA UNIDADE CONSUMIDORA MARINA"]).count, 1)
    }

    func testWitnessNameRemainsCandidateWithoutClaimingOwnership() {
        let result = search("contrato de Ana Silva", texts: ["CONTRATO Testemunha Ana Silva"]).first
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.evidenceSummary.contains("Titularidade não confirmada") == true)
    }

    func testLegacyTextNotPromotedAndResultsRemainFew() {
        var legacy = record("REGISTRO GERAL Ana Silva")
        legacy.extractedTextEvidence = nil
        var snapshot = PhotoIndexSnapshot()
        snapshot.assets = [legacy]
        XCTAssertTrue(PhotoIndexQueryEngine.search(query: "RG de Ana Silva", in: snapshot).isEmpty)
        XCTAssertEqual(search("RG", texts: Array(repeating: "REGISTRO GERAL", count: 12)).count, 5)
    }

    func testOCRTextWithoutDocumentClassificationIsSearchable() {
        var item = record("captura sintética com código ALFA998")
        item.category = .other
        item.classificationEvidence = nil
        var snapshot = PhotoIndexSnapshot(); snapshot.assets = [item]
        XCTAssertEqual(PhotoIndexQueryEngine.search(query: "ALFA998", in: snapshot).count, 1)
    }

    func testGenericFilenameSearchRemainsAvailableForCloudPendingItem() {
        var item = record("", name: "relatorio janeiro.jpg")
        item.contentAvailability = .cloudOnly; item.processingState = .waitingForLocalContent
        var snapshot = PhotoIndexSnapshot(); snapshot.assets = [item]
        XCTAssertEqual(PhotoIndexQueryEngine.search(query: "janeiro", in: snapshot).count, 1)
    }

    func testDifferentExplicitHolderExcludesWitnessOnlyMatch() {
        let texts = [
            "CONTRATO\nTitular: Bruno Costa\nTestemunha: Ana Silva",
            "CONTRATO\nNome do titular: Ana Silva\nTestemunha: Bruno Costa"
        ]
        let result = search("contrato de Ana Silva", texts: texts)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.sourceLocalIdentifier, "fixture-1.jpg")
        XCTAssertTrue(result.first?.holderMatchEvidence?.contains("Campo Nome/Titular observado") == true)
    }

    func testLabelOnSeparateLineAndParentNameDoNotSupplyHolder() {
        XCTAssertEqual(search("RG de Ana Silva", texts: [
            "REGISTRO GERAL\nNome:\nAna Silva\nNome da mãe: Clara Silva",
            "REGISTRO GERAL\nNome: Bruno Costa\nNome da mãe: Ana Silva"
        ]).count, 1)
    }

    func testWitnessSectionNameAndInlineWitnessCannotOverrideHolder() {
        XCTAssertTrue(search("contrato de Ana Silva", texts: [
            "CONTRATO\nTitular: Bruno Costa\nTestemunha 1\nNome: Ana Silva",
            "CONTRATO\nTitular: Bruno Costa Testemunha: Ana Silva"
        ]).isEmpty)
    }

    func testRawTextEvaluatorRejectsContradictoryLabel() {
        let raw = "CONTRATO\nTitular: Bruno Costa\nTestemunha: Ana Silva"
        let query = PhotoDocumentQuery("contrato de Ana Silva")
        XCTAssertFalse(query.matches(extracted: PhotoDocumentQuery.normalize(raw), metadata: "", rawText: raw))
        XCTAssertTrue(query.matches(extracted: "contrato ana silva", metadata: "", rawText: "CONTRATO Ana Silva"))
    }

    func testDocumentSubjectDoesNotBecomeRequestedHolder() {
        let raw = "CONTRATO DO LOTE\nTitular: Bruno Costa"
        let result = search("contrato do lote", texts: [raw])
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result.first?.holderMatchEvidence)
        XCTAssertTrue(search("contrato do lote", texts: ["CONTRATO\nTitular: Bruno Costa"]).isEmpty)
    }

    func testIdentityHolderStillRejectsWitnessAndExplicitHolderCanFollowSubject() {
        XCTAssertTrue(search("identidade de Maria Silva", texts: [
            "IDENTIDADE\nNome: Bruno Costa\nTestemunha: Maria Silva"
        ]).isEmpty)
        XCTAssertTrue(search("contrato do lote titular Maria Silva", texts: [
            "CONTRATO DO LOTE\nTitular: Bruno Costa\nTestemunha: Maria Silva"
        ]).isEmpty)
        XCTAssertEqual(search("contrato do lote titular Maria Silva", texts: [
            "CONTRATO DO LOTE\nTitular: Maria Silva"
        ]).count, 1)
    }

    private func search(_ query: String, texts: [String]) -> [PhotoSearchMatch] {
        var snapshot = PhotoIndexSnapshot()
        snapshot.assets = texts.enumerated().map { record($0.element, name: "fixture-\($0.offset).jpg") }
        return PhotoIndexQueryEngine.search(query: query, in: snapshot, limit: 20)
    }

    private func record(_ text: String, name: String = "fixture.jpg") -> IndexedPhoto {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return IndexedPhoto(id: name, sourceLocalIdentifier: name, sourceDeviceID: "synthetic-iphone",
            contentType: "public.jpeg", creationDate: date, modificationDate: date,
            width: 1200, height: 800, originalFilename: name, albumAssociations: [],
            originalEvidence: .init(provider: "PhotoKit fixture", observedAt: date, assetLocalIdentifier: name),
            category: .document, normalizedOCRText: PhotoDocumentQuery.normalize(text),
            extractedTextEvidence: .init(text: text, normalizedText: PhotoDocumentQuery.normalize(text), extractor: "Synthetic OCR", extractedAt: date),
            classificationEvidence: nil, contentAvailability: .local, processingState: .processed,
            indexedAt: date, sourceFingerprint: "synthetic-v2")
    }
}
