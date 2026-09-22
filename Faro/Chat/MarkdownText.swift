import SwiftUI
import UIKit

/// Renders Markdown with the platform's own CommonMark parser plus a
/// small pre-scan for GFM tables and display equations (see
/// `MarkdownBlock`) — no third-party Markdown package — as one `View` per
/// block, so headings, lists, quotes, code blocks, tables and equations
/// actually look like themselves instead of being flattened into one
/// run-on paragraph. Content is always fully present in the view
/// hierarchy; nothing here is gated behind an entrance animation.
///
/// ponytail: reparses the whole string on every streamed token, so
/// headings/tables/equations render live instead of popping into shape
/// once the turn ends. Cheap at chat-message length; if a very long
/// streaming reply ever makes this visible, parse only up to the last
/// blank line and stream the tail as plain text.
struct MarkdownText: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(MarkdownBlock.blocks(of: content)) { block in
                BlockView(block: block, isFirst: block.id == 0)
            }
        }
        .textSelection(.enabled)
    }
}

private struct BlockView: View {
    let block: MarkdownBlock
    let isFirst: Bool

    var body: some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text)
                .font(headingFont(level))
                .padding(.top, isFirst ? 0 : 6)
        case .paragraph:
            Text(block.text)
        case .listItem(let marker, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(FaroColor.ash)
                Text(block.text)
            }
            .padding(.leading, CGFloat(depth - 1) * 14)
        case .code(let language):
            CodeBlockView(text: block.text, language: language)
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                Capsule().fill(FaroColor.edge).frame(width: 2)
                Text(block.text).foregroundStyle(FaroColor.ash)
            }
        case .rule:
            Capsule().fill(FaroColor.edge).frame(height: 1)
        case .equation(let latex):
            ScrollView(.horizontal, showsIndicators: false) {
                MathView(latex: latex)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .faroCard()
        case .table(let header, let alignment, let rows):
            TableBlockView(header: header, alignment: alignment, rows: rows)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.weight(.semibold)
        case 2: .title3.weight(.semibold)
        default: .headline
        }
    }
}

/// A code block, syntax-colored by `CodeHighlighter` (falling back to
/// plain monospace if that fails), with a copy affordance: a bare icon
/// (no tile behind it) that swaps to a checkmark for a beat after a tap
/// instead of bouncing or glowing. Same header-row-above-content shape as
/// `ReasoningCard`.
private struct CodeBlockView: View {
    let text: AttributedString
    let language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Spacer()
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FaroColor.ash)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copiar código")
            }
            Text(highlighted ?? text)
                .font(.system(.footnote, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .faroCard()
    }

    @MainActor private var highlighted: AttributedString? {
        CodeHighlighter.highlight(String(text.characters), language: language)
    }

    private func copy() {
        UIPasteboard.general.string = String(text.characters)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }
}

/// A GFM table rendered with SwiftUI's native `Grid`, scrollable
/// horizontally so a wide table never gets clipped on a phone.
private struct TableBlockView: View {
    let header: [AttributedString]
    let alignment: [MarkdownBlock.ColumnAlignment]
    let rows: [[AttributedString]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 8) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { column, value in
                        cell(value, column: column).font(.footnote.weight(.semibold))
                    }
                }
                Capsule().fill(FaroColor.edge).frame(height: 1).gridCellColumns(header.count)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { column, value in
                            cell(value, column: column).font(.footnote)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .faroCard()
    }

    private func cell(_ text: AttributedString, column: Int) -> some View {
        Text(text)
            .foregroundStyle(FaroColor.bone)
            .gridColumnAlignment(alignment[column].horizontalAlignment)
    }
}

private extension MarkdownBlock.ColumnAlignment {
    var horizontalAlignment: HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
