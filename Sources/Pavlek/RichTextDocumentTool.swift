#if os(macOS)
import AppKit
import Foundation

@MainActor
final class RichTextDocumentTool {
    let toolName = "Documento RTF do macOS"

    func createOrganizedDocument(title: String, sourceName: String, summary: String) throws -> URL {
        let panel = NSSavePanel()
        panel.title = "Criar versão organizada"
        panel.message = "O contrato original permanecerá intacto."
        panel.nameFieldStringValue = "\(title).rtf"
        panel.allowedContentTypes = [.rtf]
        guard panel.runModal() == .OK, let url = panel.url else { throw WorkflowEngineError.cancelled }

        let body = NSMutableAttributedString()
        body.append(NSAttributedString(string: "\(title)\n", attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .bold)]))
        body.append(NSAttributedString(string: "\nDocumento de origem\n", attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold)]))
        body.append(NSAttributedString(string: "\(sourceName)\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor]))
        body.append(NSAttributedString(string: "\nResumo organizado\n", attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .semibold)]))
        body.append(NSAttributedString(string: "\n\(summary)\n", attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        let data = try body.data(from: NSRange(location: 0, length: body.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try data.write(to: url, options: .atomic)
        NSWorkspace.shared.open(url)
        return url
    }
}
#endif
