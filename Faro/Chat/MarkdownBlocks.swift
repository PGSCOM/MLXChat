import Foundation

/// One block of a parsed Markdown document (a heading, a paragraph, a list
/// item, a code block, a quote, a rule, a GFM table or a display equation),
/// each with its own `AttributedString` so inline formatting (bold, links,
/// inline code) inside it still renders. Foundation's
/// `AttributedString(markdown:)` parses headings/paragraphs/lists/code/
/// quotes into `presentationIntent` but drops the text separators between
/// blocks, and doesn't parse GFM tables or LaTeX at all — `blocks(of:)`
/// pre-scans the raw text line by line for tables and display equations,
/// then hands whatever's left to the `AttributedString`-based parser for
/// everything else.
struct MarkdownBlock: Identifiable, Equatable {
    enum ColumnAlignment: Equatable {
        case leading, center, trailing
    }

    enum Kind: Equatable {
        case paragraph
        case heading(level: Int)
        /// `marker` is `"•"` for an unordered item, `"3."` for an ordered
        /// one; `depth` is how many nested lists it sits inside (1 = top).
        case listItem(marker: String, depth: Int)
        case code
        case quote
        case rule
        /// A display equation (`$$...$$`, `\[...\]`, or a whole line/
        /// paragraph wrapped in `$...$`/`\(...\)`) — its raw LaTeX source.
        /// True inline math mid-sentence isn't split out: `Text` can't
        /// host an arbitrary math view, so it's left as literal text.
        case equation(String)
        case table(header: [AttributedString], alignment: [ColumnAlignment], rows: [[AttributedString]])
    }

    let id: Int
    let kind: Kind
    let text: AttributedString

    static func blocks(of markdown: String) -> [MarkdownBlock] {
        let lines = markdown.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var prose: [String] = []

        func flushProse() {
            defer { prose = [] }
            let joined = prose.joined(separator: "\n")
            guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            for (kind, text) in proseBlocks(of: joined) {
                blocks.append(MarkdownBlock(id: blocks.count, kind: kind, text: text))
            }
        }

        var index = 0
        // Tracks whether we're inside a ``` fence, so a table- or equation-
        // looking line pasted as an example *inside* a code block isn't
        // mistaken for a real one — it stays opaque prose, and the existing
        // AttributedString parser below classifies the fence as `.code`.
        var insideCodeFence = false
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                insideCodeFence.toggle()
                prose.append(line)
                index += 1
                continue
            }
            if !insideCodeFence, let equation = displayEquation(at: index, in: lines) {
                flushProse()
                blocks.append(MarkdownBlock(id: blocks.count, kind: .equation(equation.latex), text: AttributedString(equation.latex)))
                index = equation.nextIndex
                continue
            }
            if !insideCodeFence, let table = gfmTable(at: index, in: lines) {
                flushProse()
                blocks.append(MarkdownBlock(
                    id: blocks.count,
                    kind: .table(header: table.header, alignment: table.alignment, rows: table.rows),
                    text: AttributedString()
                ))
                index = table.nextIndex
                continue
            }
            prose.append(line)
            index += 1
        }
        flushProse()
        return blocks.isEmpty ? [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(markdown))] : blocks
    }

    // MARK: - Prose (headings, paragraphs, lists, code, quotes, rules)

    private static func proseBlocks(of markdown: String) -> [(Kind, AttributedString)] {
        guard let attributed = try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .full)
        ), !attributed.runs.isEmpty else {
            return [(.paragraph, AttributedString(markdown))]
        }

        var result: [(Kind, AttributedString)] = []
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
            result.append((blockKind, trimmedText))
        }

        for run in attributed.runs {
            if run.presentationIntent != blockIntent {
                flush()
                blockIntent = run.presentationIntent
            }
            blockText += AttributedString(attributed[run.range])
        }
        flush()
        return result
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

    // MARK: - Display equations

    private struct EquationMatch {
        let latex: String
        let nextIndex: Int
    }

    /// Delimiters whose content may span several lines, as a fence: the
    /// whole line is just the opener, content follows, then a line that's
    /// just the closer (mirrors how ``` code fences work). Also matched on
    /// one line if both ends land there.
    private static let fenceDelimiters: [(open: String, close: String)] = [("$$", "$$"), ("\\[", "\\]")]
    /// Delimiters only recognized when the *entire* line is one wrapped
    /// expression — the common "$E = mc^2$ on its own line" case — never
    /// mid-sentence, and never a line with more than one pair (that's
    /// ordinary prose using a literal `$`).
    private static let inlineOnlyDelimiters: [(open: String, close: String)] = [("$", "$"), ("\\(", "\\)")]

    private static func displayEquation(at index: Int, in lines: [String]) -> EquationMatch? {
        let trimmedLine = lines[index].trimmingCharacters(in: .whitespaces)

        for (open, close) in fenceDelimiters where trimmedLine.hasPrefix(open) {
            if trimmedLine.count > open.count + close.count, trimmedLine.hasSuffix(close) {
                let inner = trimmedLine.dropFirst(open.count).dropLast(close.count)
                    .trimmingCharacters(in: .whitespaces)
                if !inner.isEmpty { return EquationMatch(latex: inner, nextIndex: index + 1) }
            }
            if trimmedLine == open {
                var body: [String] = []
                var cursor = index + 1
                while cursor < lines.count {
                    if lines[cursor].trimmingCharacters(in: .whitespaces) == close {
                        let latex = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                        return latex.isEmpty ? nil : EquationMatch(latex: latex, nextIndex: cursor + 1)
                    }
                    body.append(lines[cursor])
                    cursor += 1
                }
                return nil // unterminated fence — leave the opener as plain text
            }
        }

        for (open, close) in inlineOnlyDelimiters {
            guard trimmedLine.hasPrefix(open), trimmedLine.hasSuffix(close),
                  trimmedLine.count > open.count + close.count else { continue }
            let inner = trimmedLine.dropFirst(open.count).dropLast(close.count)
                .trimmingCharacters(in: .whitespaces)
            guard !inner.isEmpty, !inner.contains(open) else { continue }
            return EquationMatch(latex: inner, nextIndex: index + 1)
        }

        return nil
    }

    // MARK: - GFM tables

    private struct TableMatch {
        let header: [AttributedString]
        let alignment: [ColumnAlignment]
        let rows: [[AttributedString]]
        let nextIndex: Int
    }

    private static func gfmTable(at index: Int, in lines: [String]) -> TableMatch? {
        guard index + 1 < lines.count, lines[index].contains("|") else { return nil }
        guard let alignment = columnAlignment(of: lines[index + 1]) else { return nil }

        let headerCells = splitRow(lines[index])
        guard !headerCells.isEmpty, headerCells.count == alignment.count else { return nil }

        var rows: [[String]] = []
        var cursor = index + 2
        while cursor < lines.count {
            let line = lines[cursor]
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, line.contains("|") else { break }
            var cells = splitRow(line)
            if cells.count < headerCells.count {
                cells += Array(repeating: "", count: headerCells.count - cells.count)
            } else if cells.count > headerCells.count {
                cells = Array(cells.prefix(headerCells.count))
            }
            rows.append(cells)
            cursor += 1
        }

        return TableMatch(
            header: headerCells.map(inlineAttributed),
            alignment: alignment,
            rows: rows.map { $0.map(inlineAttributed) },
            nextIndex: cursor
        )
    }

    /// The row of `---`/`:--`/`--:`/`:-:` cells right under a table header,
    /// the thing that actually marks a run of `|`-separated lines as a GFM
    /// table rather than prose that happens to contain a pipe.
    private static func columnAlignment(of separatorLine: String) -> [ColumnAlignment]? {
        let cells = splitRow(separatorLine)
        guard !cells.isEmpty else { return nil }
        var result: [ColumnAlignment] = []
        for cell in cells {
            guard !cell.isEmpty, cell.allSatisfy({ $0 == "-" || $0 == ":" }), cell.contains("-") else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): result.append(.center)
            case (false, true): result.append(.trailing)
            default: result.append(.leading)
            }
        }
        return result
    }

    private static func splitRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func inlineAttributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
