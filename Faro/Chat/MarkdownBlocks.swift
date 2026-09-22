import Foundation

/// One block of a parsed Markdown document (a heading, a paragraph, a list
/// item, a code block, a quote or a rule), each with its own
/// `AttributedString` so inline formatting (bold, links, inline code)
/// inside it still renders. Foundation's `AttributedString(markdown:)`
/// parses this structure into `presentationIntent` but drops the text
/// separators between blocks — `MarkdownText` needs the blocks split back
/// out to render one `View` per block instead of one run-on paragraph.
struct MarkdownBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case paragraph
        case heading(level: Int)
        /// `marker` is `"•"` for an unordered item, `"3."` for an ordered
        /// one; `depth` is how many nested lists it sits inside (1 = top).
        case listItem(marker: String, depth: Int)
        case code
        case quote
        case rule
    }

    let id: Int
    let kind: Kind
    let text: AttributedString

    static func blocks(of markdown: String) -> [MarkdownBlock] {
        guard let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full)
        ), !attributed.runs.isEmpty else {
            return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(markdown))]
        }

        var blocks: [MarkdownBlock] = []
        var blockText = AttributedString()
        // `presentationIntent` carries a per-block `identity`, so two
        // consecutive paragraphs compare unequal even with identical
        // components — that's what lets this loop tell them apart.
        var blockIntent = attributed.runs.first?.presentationIntent

        func flush() {
            defer { blockText = AttributedString() }
            let trimmedText = trimmed(blockText)
            let blockKind = kind(for: blockIntent)
            guard !trimmedText.characters.isEmpty || blockKind == .rule else { return }
            blocks.append(MarkdownBlock(id: blocks.count, kind: blockKind, text: trimmedText))
        }

        for run in attributed.runs {
            if run.presentationIntent != blockIntent {
                flush()
                blockIntent = run.presentationIntent
            }
            blockText += AttributedString(attributed[run.range])
        }
        flush()
        return blocks
    }

    private static func kind(for intent: PresentationIntent?) -> Kind {
        guard let intent else { return .paragraph }
        var headingLevel: Int?
        var listDepth = 0
        var isUnordered = false
        var ordinal: Int?
        for component in intent.components {
            switch component.kind {
            case .header(let level): headingLevel = level
            case .orderedList: listDepth += 1
            case .unorderedList: listDepth += 1; isUnordered = true
            case .listItem(let itemOrdinal): ordinal = itemOrdinal
            case .codeBlock: return .code
            case .blockQuote: return .quote
            case .thematicBreak: return .rule
            default: break
            }
        }
        if let headingLevel { return .heading(level: headingLevel) }
        if listDepth > 0 {
            return .listItem(marker: isUnordered ? "•" : "\(ordinal ?? 1).", depth: listDepth)
        }
        return .paragraph
    }

    private static func trimmed(_ text: AttributedString) -> AttributedString {
        var start = text.startIndex
        while start < text.endIndex, text.characters[start].isWhitespace {
            start = text.index(afterCharacter: start)
        }
        var end = text.endIndex
        while end > start, text.characters[text.index(beforeCharacter: end)].isWhitespace {
            end = text.index(beforeCharacter: end)
        }
        return AttributedString(text[start..<end])
    }
}
