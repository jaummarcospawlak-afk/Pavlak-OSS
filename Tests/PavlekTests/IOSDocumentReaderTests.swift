#if os(macOS)
import AppKit
import PDFKit
import XCTest
@testable import Pavlek

@MainActor
final class IOSDocumentReaderTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("IOSReader-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 1200, height: 700))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1200, height: 700)).fill()
        ("CONTRATO FICTICIO\nTitular: Marina Teste\nCODIGO RASTROAZUL" as NSString).draw(
            in: NSRect(x: 60, y: 200, width: 1080, height: 400),
            withAttributes: [.font: NSFont.systemFont(ofSize: 45), .foregroundColor: NSColor.black])
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("a01.png"))
        try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:])).write(to: root.appendingPathComponent("a02.jpeg"))
        let scan = PDFDocument()
        scan.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(scan.write(to: root.appendingPathComponent("a03.pdf")))
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try XCTUnwrap(CGContext(consumer: try XCTUnwrap(CGDataConsumer(data: data)), mediaBox: &box, nil))
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("DOCUMENTO DIGITAL FICTICIO\nTitular: Bruno Exemplo\nCODIGO TEXTOVERDE" as NSString).draw(
            in: NSRect(x: 40, y: 300, width: 520, height: 400),
            withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage(); context.closePDF()
        try (data as Data).write(to: root.appendingPathComponent("a04.pdf"))
        let mixed = try XCTUnwrap(PDFDocument(data: data as Data))
        mixed.insert(try XCTUnwrap(PDFPage(image: image)), at: 1)
        XCTAssertTrue(mixed.write(to: root.appendingPathComponent("a05.pdf")))
        return root
    }

    func testRealOCRImagesScannedAndMixedPDFKeepBothPageEvidence() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = IOSDocumentReader()
        for file in ["a01.png", "a02.jpeg", "a03.pdf"] {
            let result = try await reader.extract(at: root.appendingPathComponent(file))
            XCTAssertTrue(result.text.contains("RASTROAZUL"), file)
            XCTAssertTrue(result.text.contains("Marina Teste"), file)
        }
        let digital = try await reader.extract(at: root.appendingPathComponent("a04.pdf"))
        XCTAssertTrue(digital.text.contains("TEXTOVERDE"))
        let mixed = try await reader.extract(at: root.appendingPathComponent("a05.pdf"))
        XCTAssertTrue(mixed.text.contains("TEXTOVERDE"))
        XCTAssertTrue(mixed.text.contains("RASTROAZUL"))
        XCTAssertTrue(mixed.text.contains("Página 2 — OCR"))
        XCTAssertTrue(mixed.coverage.contains("2 de 2"))
    }

    func testUnsupportedFileFailsWithoutTreatingNameAsContent() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("contrato-\(UUID()).txt")
        try "Contrato fictício".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        do { _ = try await IOSDocumentReader().extract(at: url); XCTFail("Unsupported type must fail") }
        catch { XCTAssertTrue(error is IOSDocumentError) }
    }
}
#endif
