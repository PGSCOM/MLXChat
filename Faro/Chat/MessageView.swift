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
                if let liveTurn, showsStatusLine(liveTurn) {
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

    /// One card for both states, so the block doesn't change shape the
    /// moment the stream ends — only its title and its body do.
    @ViewBuilder private var reasoning: some View {
        if let text = reasoningText {
            ReasoningCard(
                text: text,
                isLive: isThinking,
                seconds: message.reasoningSeconds,
                startedAt: isThinking ? liveTurn?.startedAt : nil
            )
        }
    }

    private var isThinking: Bool { liveTurn?.phase == .thinking }

    private func showsStatusLine(_ turn: LiveTurn) -> Bool {
        // While thinking, the reasoning card already carries the label and
        // the counter; two live timers on one bubble is just noise.
        if isThinking, reasoningText != nil { return false }
        return message.content.isEmpty || turn.phase != .writing
    }
}

/// Counts up from the moment the phase began. The label is always
/// rendered — the timer only refreshes the number beside it, so nothing
/// here can disappear if the timeline never ticks.
private struct TurnStatusLine: View {
    let turn: MessageView.LiveTurn

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
            TimelineView(.periodic(from: turn.startedAt, by: 1)) { timeline in
                Text(ReasoningCard.elapsedLabel(since: turn.startedAt, at: timeline.date))
                    .monospacedDigit()
            }
        }
        .font(.footnote)
        .foregroundStyle(FaroColor.ash)
    }

    private var label: String {
        switch turn.phase {
        case .preparing: "Preparando el modelo…"
        case .thinking: "Pensando…"
        case .writing: "Escribiendo…"
        case .idle: ""
        }
    }
}

/// The reasoning block, live and finished. Same card, same header row in
/// both states: when the stream ends the body folds away and the title
/// swaps for how long it took, and nothing else moves.
struct ReasoningCard: View {
    let text: String
    let isLive: Bool
    let seconds: Double?
    /// Only while live — drives the counter in the header.
    let startedAt: Date?

    @State private var expanded = false

    /// Capped by characters, never by a line limit: a line limit truncates
    /// the end, which is exactly the part being written.
    private static let liveCharacters = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if isLive {
                textBlock(tail)
            } else if expanded {
                textBlock(text)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .faroCard()
    }

    /// Live, there is nothing to collapse to yet — the duration doesn't
    /// exist until the block closes — so the row isn't a control.
    @ViewBuilder private var header: some View {
        if isLive {
            headerRow
        } else {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                headerRow
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Ocultar el razonamiento" : "Mostrar el razonamiento")
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(FaroColor.bone)
            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
                    Text(Self.elapsedLabel(since: startedAt, at: timeline.date))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(FaroColor.ash)
                }
            }
            Spacer(minLength: 8)
            if !isLive {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FaroColor.ash)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .contentShape(.rect)
    }

    private func textBlock(_ content: String) -> some View {
        Text(content)
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(FaroColor.ash)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        isLive ? "Pensando…" : Self.durationLabel(seconds)
    }

    private var tail: String {
        guard text.count > Self.liveCharacters else { return text }
        return "…" + String(text.suffix(Self.liveCharacters))
    }

    static func durationLabel(_ seconds: Double?) -> String {
        guard let seconds, seconds >= 1 else { return "Pensamientos" }
        let whole = Int(seconds)
        return whole < 60
            ? "Razonó durante \(Int(seconds.rounded())) s"
            : "Razonó durante \(whole / 60) min \(whole % 60) s"
    }

    static func elapsedLabel(since start: Date, at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
    }
}

/// A pasted file attachment can make a user message huge — this keeps
/// the bubble readable without ever hiding the real content
/// behind opacity or an entrance animation; it's a plain length cap the
/// person can lift, same idea as the reasoning card above.
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
                .faroCard()

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
