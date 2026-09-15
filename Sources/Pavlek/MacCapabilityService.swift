#if os(macOS)
import AppKit
import Foundation
import PDFKit
import QuickLookUI
import UniformTypeIdentifiers

enum DocumentPresentationCapability: Sendable {
    case pdfKit
    case quickLook
    case metadataOnly
}

struct MacCapabilities: Sendable {
    let pagesInstalled: Bool
    let pagesURL: URL?
    let presentation: DocumentPresentationCapability
}

struct MacCapabilityService {
    func inspect(fileURL: URL) -> MacCapabilities {
        let pagesURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Pages")
        let type = UTType(filenameExtension: fileURL.pathExtension)
        let presentation: DocumentPresentationCapability
        if type?.conforms(to: .pdf) == true, PDFDocument(url: fileURL) != nil {
            presentation = .pdfKit
        } else if type != nil {
            presentation = .quickLook
        } else {
            presentation = .metadataOnly
        }
        return MacCapabilities(pagesInstalled: pagesURL != nil, pagesURL: pagesURL, presentation: presentation)
    }
}
#endif
