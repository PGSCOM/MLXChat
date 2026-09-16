import SwiftUI

struct MessageView: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                MarkdownText(content: message.content)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(FaroColor.inkRaised, in: .rect(cornerRadius: 16))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if let reasoning = message.reasoning, !reasoning.isEmpty {
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
