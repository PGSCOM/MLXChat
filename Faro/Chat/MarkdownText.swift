import SwiftUI

/// Renders Markdown with the platform's own CommonMark parser — no
/// third-party Markdown package — as one `View` per block, so headings,
/// lists, quotes and code blocks actually look like themselves instead of
/// being flattened into one run-on paragraph (see `MarkdownBlock`).
/// Content is always fully present in the view hierarchy; nothing here is
/// gated behind an entrance animation.
///
/// ponytail: reparses the whole string on every streamed token, so
/// headings render live instead of popping into shape once the turn ends.
/// Cheap at chat-message length; if a very long streaming reply ever makes
/// this visible, parse only up to the last blank line and stream the tail
/// as plain text.
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
        case .code:
            Text(block.text)
                .font(.system(.footnote, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .faroCard()
        case .quote:
            HStack(alignment: .top, spacing: 10) {
                Capsule().fill(FaroColor.edge).frame(width: 2)
                Text(block.text).foregroundStyle(FaroColor.ash)
            }
        case .rule:
            Capsule().fill(FaroColor.edge).frame(height: 1)
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
