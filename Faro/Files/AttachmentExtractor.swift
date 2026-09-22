import Foundation
import PDFKit
import UniformTypeIdentifiers

struct ExtractedAttachment: Sendable {
    let fileName: String
    let text: String
    let wasTruncated: Bool
}

/// Pulls text out of an attached file. CSV/TSV/TXT/MD/source files are
/// all just plain text underneath — the model reads that raw, no CSV
/// parser or syntax awareness needed. PDF is the one format that needs
/// real extraction.
enum AttachmentExtractor {
    /// A cheap proxy for "won't blow the context window" — the real
    /// limit depends on the loaded model's tokenizer, which isn't known
    /// until a model is actually loaded, so this errs conservative.
    static let characterLimit = 12_000

    enum ExtractionError: LocalizedError {
        case unreadablePDF
        case unreadableText

        var errorDescription: String? {
            switch self {
            case .unreadablePDF: return "No se pudo leer el PDF."
            case .unreadableText: return "No se pudo leer el archivo como texto."
            }
        }
    }

    /// File types the composer and the project knowledge picker both accept.
    static let fileTypes: [UTType] = [.pdf, .plainText, .commaSeparatedText, .text]

    /// Same as `extractText(from:)`, but wraps the security-scoped access a
    /// `.fileImporter` result requires. Callers reading a URL straight off
    /// disk (drag-and-drop's temp file) should keep using `extractText`.
    static func extractSecurityScoped(_ url: URL) throws -> ExtractedAttachment {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        return try extractText(from: url)
    }

    static func extractText(from url: URL) throws -> ExtractedAttachment {
        let fileName = url.lastPathComponent
        let raw: String

        if url.pathExtension.lowercased() == "pdf" {
            guard let document = PDFDocument(url: url) else {
                throw ExtractionError.unreadablePDF
            }
            var pages: [String] = []
            for index in 0..<document.pageCount {
                if let page = document.page(at: index), let text = page.string {
                    pages.append(text)
                }
            }
            raw = pages.joined(separator: "\n\n")
        } else {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                throw ExtractionError.unreadableText
            }
            raw = text
        }

        if raw.count > characterLimit {
            return ExtractedAttachment(fileName: fileName, text: String(raw.prefix(characterLimit)), wasTruncated: true)
        }
        return ExtractedAttachment(fileName: fileName, text: raw, wasTruncated: false)
    }
}
