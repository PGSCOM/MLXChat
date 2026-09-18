import SwiftUI
import UIKit

struct MessageView: View {
    let message: ChatMessage
    /// Set only on the message currently being generated, so the bubble
    /// can report what the model is doing right now.
    var liveTurn: LiveTurn?

    struct LiveTurn: Equatable {
        let phase: TurnPhase
        let startedAt: Date
    }

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                UserBubble(content: message.content, imageData: message.imageData)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                reasoning
                if !message.content.isEmpty {
                    MarkdownText(content: message.content, parsed: liveTurn == nil)
                        .foregroundStyle(FaroColor.bone)
                }
                if let liveTurn, message.content.isEmpty || liveTurn.phase != .writing {
                    TurnStatusLine(turn: liveTurn)
                }
                if liveTurn == nil, let tps = message.tokensPerSecond, tps > 0 {
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

    private var reasoningText: String? {
        guard let text = message.reasoning,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// While the model is still inside its `<think>` block the reasoning
    /// stays open and streaming — that wait is the part that most needs
    /// explaining. Once the answer starts it folds away behind how long it
    /// took, which is real information, not a label.
    @ViewBuilder private var reasoning: some View {
        if let text = reasoningText {
            if liveTurn?.phase == .thinking {
                LiveReasoning(text: text)
            } else {
                ReasoningDisclosure(text: text, seconds: message.reasoningSeconds)
            }
        }
    }
}

/// Counts up from the moment the phase began. The label is always
/// rendered — the timer only refreshes the number beside it, so nothing
/// here can disappear if the timeline never ticks.
private struct TurnStatusLine: View {
    let turn: MessageView.LiveTurn

    var body: some View {
        TimelineView(.periodic(from: turn.startedAt, by: 1)) { timeline in
            HStack(spacing: 8) {
                Text(label)
                Text(elapsed(at: timeline.date))
                    .monospacedDigit()
            }
            .font(.footnote)
            .foregroundStyle(FaroColor.ash)
        }
    }

    private var label: String {
        switch turn.phase {
        case .preparing: "Preparando el modelo…"
        case .thinking: "Pensando…"
        case .writing: "Escribiendo…"
        case .idle: ""
        }
    }

    private func elapsed(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(turn.startedAt)))
        return seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
    }
}

/// The tail of the reasoning as it streams. Capped by character count
/// rather than by a line limit: a line limit truncates the end, which is
/// exactly the part being written. Nothing is clipped, the block just
/// stays small.
private struct LiveReasoning: View {
    let text: String
    private static let visibleCharacters = 180

    var body: some View {
        Text(tail)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(FaroColor.ash)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(FaroColor.inkRaised, in: .rect(cornerRadius: 14))
    }

    private var tail: String {
        guard text.count > Self.visibleCharacters else { return text }
        return "…" + String(text.suffix(Self.visibleCharacters))
    }
}

/// A pasted file attachment can make a user message huge — this keeps
/// the bubble readable without ever hiding the real content
/// behind opacity or an entrance animation; it's a plain length cap the
/// person can lift, same idea as the reasoning disclosure above.
private struct UserBubble: View {
    let content: String
    let imageData: Data?
    @State private var expanded = false
    private static let previewLimit = 600

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            MarkdownText(content: displayedContent)
                .foregroundStyle(FaroColor.bone)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(FaroColor.inkRaised, in: .rect(cornerRadius: 16))
                .overlay {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(FaroColor.edge, lineWidth: 1)
                }

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
    let seconds: Double?
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(label, isExpanded: $expanded) {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(FaroColor.ash)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        }
        .tint(FaroColor.ash)
        .font(.footnote)
    }

    private var label: String {
        guard let seconds, seconds >= 1 else { return "Razonamiento" }
        return seconds < 60
            ? "Razonó durante \(Int(seconds.rounded())) s"
            : "Razonó durante \(Int(seconds) / 60) min \(Int(seconds) % 60) s"
    }
}
