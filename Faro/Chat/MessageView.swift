import SwiftUI

struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                UserBubble(content: message.content)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if let reasoning = message.reasoning,
                   !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ReasoningDisclosure(text: reasoning)
                }
                if message.content.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .tint(FaroColor.beamCore)
                } else {
                    MarkdownText(content: message.content)
                        .foregroundStyle(.white)
                }
                if let tps = message.tokensPerSecond, tps > 0 {
                    Text(String(format: "%.1f tok/s", tps))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(FaroColor.ash)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 48)
        case .system:
            EmptyView()
        }
    }
}

/// A pasted file (Fase 6 attachments) can make a user message huge —
/// this keeps the bubble readable without ever hiding the real content
/// behind opacity or an entrance animation; it's a plain length cap the
/// person can lift, same idea as the reasoning disclosure above.
private struct UserBubble: View {
    let content: String
    @State private var expanded = false
    private static let previewLimit = 600

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            MarkdownText(content: displayedContent)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(FaroColor.inkRaised, in: .rect(cornerRadius: 16))

            if content.count > Self.previewLimit {
                Button(expanded ? "Mostrar menos" : "Mostrar todo") {
                    expanded.toggle()
                }
                .font(.caption)
                .foregroundStyle(FaroColor.ash)
            }
        }
    }

    private var displayedContent: String {
        guard !expanded, content.count > Self.previewLimit else { return content }
        return String(content.prefix(Self.previewLimit)) + "…"
    }
}

private struct ReasoningDisclosure: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Razonamiento", isExpanded: $expanded) {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(FaroColor.ash)
                .padding(.top, 4)
        }
        .tint(FaroColor.ash)
        .font(.footnote)
    }
}
