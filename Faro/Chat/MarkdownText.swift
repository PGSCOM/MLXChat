import SwiftUI

/// Renders Markdown with the platform's own CommonMark parser — no
/// third-party Markdown package. Content is always fully present in the
/// view hierarchy; nothing here is gated behind an entrance animation.
///
/// ponytail: `AttributedString(markdown:)` covers headings, emphasis,
/// lists, inline code, code blocks (as plain monospace, no syntax
/// highlighting) and links, but not GFM tables. Add swift-markdown-ui
/// only if tables/highlighting are actually requested.
struct MarkdownText: View {
    let content: String

    var body: some View {
        Text(attributed)
            .textSelection(.enabled)
    }

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: content,
            options: .init(interpretedSyntax: .full)
        )) ?? AttributedString(content)
    }
}
