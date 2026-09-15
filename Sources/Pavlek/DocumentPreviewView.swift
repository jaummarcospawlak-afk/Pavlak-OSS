#if os(macOS)
import PDFKit
import QuickLookUI
import SwiftUI

struct DocumentPreviewView: View {
    let url: URL
    let presentation: DocumentPresentationCapability

    var body: some View {
        switch presentation {
        case .pdfKit: PDFDocumentView(url: url)
        case .quickLook: QuickLookDocumentView(url: url)
        case .metadataOnly:
            ContentUnavailableView("Pré-visualização indisponível", systemImage: "doc", description: Text("O formato não oferece visualização interna neste Mac."))
        }
    }
}

private struct PDFDocumentView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

private struct QuickLookDocumentView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = true; view.previewItem = url as QLPreviewItem
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as QLPreviewItem }
}
#endif
