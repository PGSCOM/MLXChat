import Foundation

struct Artifact: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let language: String
    let content: String

    var lineCount: Int { content.isEmpty ? 0 : content.components(separatedBy: "\n").count }

    var fileExtension: String {
        switch language.lowercased() {
        case "swift": "swift"
        case "python", "py": "py"
        case "javascript", "js": "js"
        case "typescript", "ts": "ts"
        case "html": "html"
        case "svg": "svg"
        case "css": "css"
        case "json": "json"
        case "markdown", "md": "md"
        case "yaml", "yml": "yaml"
        case "sh", "bash", "shell": "sh"
        default: "txt"
        }
    }

    var isPreviewable: Bool {
        let language = language.lowercased()
        return language == "html" || language == "svg"
    }
}

/// A message's content, split into plain-text runs and promoted code
/// blocks. Reassembling every segment's raw text reproduces the original
/// `content` exactly — see `ArtifactParserTests`.
enum MessageSegment: Identifiable, Hashable {
    case text(id: Int, String)
    case artifact(Artifact)

    var id: Int {
        switch self {
        case .text(let id, _): id
        case .artifact(let artifact): artifact.id
        }
    }
}

/// Derives artifacts from fenced code blocks (```` ``` ````) — no
/// cooperation from the model required. A block is promoted when its
/// language is a document type (renders or downloads as a real file) or
/// it's long enough that a card beats an inline wall of code; anything
/// shorter stays inline so `MarkdownText` keeps rendering it as normal code.
enum ArtifactParser {
    private static let documentLanguages: Set<String> = ["html", "svg", "markdown", "md"]
    private static let minimumLines = 8

    static func segments(_ content: String) -> [MessageSegment] {
        let lines = content.components(separatedBy: "\n")
        var segments: [MessageSegment] = []
        var textLines: [String] = []
        var index = 0

        func flushText() {
            guard !textLines.isEmpty else { return }
            let text = textLines.joined(separator: "\n")
            if !text.isEmpty {
                segments.append(.text(id: segments.count, text))
            }
            textLines = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let fence = fenceInfo(trimmed) else {
                textLines.append(line)
                index += 1
                continue
            }

            // Find a matching close fence of at least the same length.
            var closeIndex: Int?
            var bodyLines: [String] = []
            var scan = index + 1
            while scan < lines.count {
                let candidate = lines[scan].trimmingCharacters(in: .whitespaces)
                if candidate.hasPrefix(fence.marker) && candidate.allSatisfy({ $0 == fence.markerChar }) {
                    closeIndex = scan
                    break
                }
                bodyLines.append(lines[scan])
                scan += 1
            }

            guard let closeIndex else {
                // Unclosed fence (a cut-off response): keep as plain text,
                // never drop content.
                textLines.append(line)
                index += 1
                continue
            }

            let body = bodyLines.joined(separator: "\n")
            let shouldPromote = documentLanguages.contains(fence.language.lowercased())
                || bodyLines.count >= minimumLines

            if shouldPromote {
                flushText()
                let title = fence.title ?? defaultTitle(for: fence.language)
                segments.append(.artifact(Artifact(id: segments.count, title: title, language: fence.language, content: body)))
            } else {
                // Keep the original fenced text verbatim, including the fences.
                textLines.append(line)
                textLines.append(contentsOf: bodyLines)
                textLines.append(lines[closeIndex])
            }
            index = closeIndex + 1
        }
        flushText()
        return segments
    }

    private struct FenceInfo {
        let marker: String
        let markerChar: Character
        let language: String
        let title: String?
    }

    /// Parses an opening fence line (` ``` ` or longer, optionally followed
    /// by a language and a title, e.g. ` ```swift Ordenar.swift `).
    private static func fenceInfo(_ trimmed: String) -> FenceInfo? {
        guard let markerChar = trimmed.first, markerChar == "`" || markerChar == "~" else { return nil }
        let markerLength = trimmed.prefix { $0 == markerChar }.count
        guard markerLength >= 3 else { return nil }
        let marker = String(repeating: markerChar, count: markerLength)
        let rest = trimmed.dropFirst(markerLength).trimmingCharacters(in: .whitespaces)
        let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
        let language = parts.first ?? ""
        let title = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : nil
        return FenceInfo(marker: marker, markerChar: markerChar, language: language, title: title?.isEmpty == false ? title : nil)
    }

    private static func defaultTitle(for language: String) -> String {
        switch language.lowercased() {
        case "": "Fragmento"
        case "html": "Documento HTML"
        case "svg": "Imagen SVG"
        case "markdown", "md": "Documento Markdown"
        case "swift": "Código Swift"
        case "python", "py": "Código Python"
        case "javascript", "js": "Código JavaScript"
        case "typescript", "ts": "Código TypeScript"
        case "json": "Datos JSON"
        default: "Código \(language.capitalized)"
        }
    }
}
