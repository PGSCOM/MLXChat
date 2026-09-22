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
                // Shown as soon as a call starts (mid-stream, before the
                // model's own written answer even begins) and stays after
                // the turn ends — visibility into tool/skill use, not just
                // a transient status line, like Claude Code's tool blocks.
                ForEach(message.toolCalls) { call in
                    ToolCallCard(call: call)
                }
                if !message.content.isEmpty {
                    // Artifacts are only derived once the turn is done —
                    // parsing mid-stream could turn a half-written fence
                    // into a false positive.
                    if liveTurn == nil {
                        ForEach(ArtifactParser.segments(message.content)) { segment in
                            switch segment {
                            case .text(_, let text):
                                MarkdownText(content: text)
                                    .foregroundStyle(FaroColor.bone)
                            case .artifact(let artifact):
                                ArtifactCard(artifact: artifact)
                            }
                        }
                    } else {
                        MarkdownText(content: message.content, parsed: false)
                            .foregroundStyle(FaroColor.bone)
                    }
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
    /// moment the stream ends — only its title and its body do. It stands
    /// in for the status line for the whole thinking phase, so it arrives
    /// with the phase rather than with the first reasoning token: nothing
    /// pops in halfway through the turn.
    @ViewBuilder private var reasoning: some View {
        if isThinking || reasoningText != nil {
            ReasoningCard(
                text: reasoningText ?? "",
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
        if isThinking { return false }
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
/// both states, and closed in both by default: while the model thinks the
/// row says so and the lamp passes over the word, and the reasoning itself
/// only appears if the person opens it. When the stream ends the title
/// swaps for how long it took, and nothing else moves.
struct ReasoningCard: View {
    let text: String
    let isLive: Bool
    let seconds: Double?
    /// Only while live — drives the counter in the header.
    let startedAt: Date?

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded, isOpenable {
                textBlock(text)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .faroCard()
    }

    /// Until the first reasoning token lands there is nothing behind the
    /// header, so the row isn't a control yet.
    private var isOpenable: Bool { !text.isEmpty }

    @ViewBuilder private var header: some View {
        if isOpenable {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                headerRow
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Ocultar el razonamiento" : "Mostrar el razonamiento")
        } else {
            headerRow
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            if isLive {
                SweptLabel(text: title)
            } else {
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(FaroColor.bone)
            }
            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
                    Text(Self.elapsedLabel(since: startedAt, at: timeline.date))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(FaroColor.ash)
                }
            }
            Spacer(minLength: 8)
            if isOpenable {
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

    // Pure functions with no view state — `nonisolated` so the tests (and
    // any other non-MainActor caller) can call them synchronously instead
    // of inheriting `@MainActor` from `ReasoningCard: View`.
    nonisolated static func durationLabel(_ seconds: Double?) -> String {
        guard let seconds, seconds >= 1 else { return "Pensamientos" }
        let whole = Int(seconds)
        return whole < 60
            ? "Razonó durante \(Int(seconds.rounded())) s"
            : "Razonó durante \(whole / 60) min \(whole % 60) s"
    }

    nonisolated static func elapsedLabel(since start: Date, at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(start)))
        return seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
    }
}

/// One row per tool or skill call. Same card language as `ReasoningCard`:
/// a running call shows a spinner and no chevron (nothing to open yet), a
/// finished one becomes tappable to reveal the result or error beneath it.
private struct ToolCallCard: View {
    let call: ToolCallRecord
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if expanded, let detail {
                Text(detail)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(FaroColor.ash)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .faroCard()
    }

    private var detail: String? {
        switch call.status {
        case .running: nil
        case .succeeded(let preview): preview.isEmpty ? nil : preview
        case .failed(let message): message
        }
    }

    @ViewBuilder private var header: some View {
        if detail != nil {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                headerRow
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Ocultar el resultado" : "Mostrar el resultado")
        } else {
            headerRow
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            icon
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(FaroColor.bone)
            Spacer(minLength: 8)
            if detail != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FaroColor.ash)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .contentShape(.rect)
    }

    private var label: String { call.isSkill ? "Skill: \(call.name)" : call.name }

    private var title: String {
        switch call.status {
        case .running: "Usando \(label)…"
        case .succeeded: label
        case .failed: "\(label) falló"
        }
    }

    @ViewBuilder private var icon: some View {
        switch call.status {
        case .running:
            ProgressView().controlSize(.small).tint(FaroColor.lamp)
        case .succeeded:
            Image(systemName: call.isSkill ? "sparkles" : "wrench.and.screwdriver")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FaroColor.lamp)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(FaroColor.error)
        }
    }
}

/// The word the model is busy with, lit by the same lamp as the beam: a
/// warm pass travelling across the glyphs while the turn is live. Driven
/// off the timeline's clock rather than a repeating animation, so a redraw
/// on every token can't leave it stranded mid-sweep — and the label is
/// drawn at full strength underneath, so it stays readable if the timeline
/// never ticks at all or motion is reduced.
private struct SweptLabel: View {
    let text: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One pass, plus a beat of darkness before the next one comes round.
    private static let period: Double = 2.6

    var body: some View {
        label
            .foregroundStyle(FaroColor.ash)
            .overlay { if !reduceMotion { light } }
    }

    private var label: some View {
        Text(text).font(.footnote.weight(.medium))
    }

    private var light: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.period) / Self.period
            GeometryReader { geo in
                LinearGradient(
                    stops: [
                        .init(color: FaroColor.lampCore.opacity(0), location: 0),
                        .init(color: FaroColor.lampCore, location: 0.5),
                        .init(color: FaroColor.lampCore.opacity(0), location: 1),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: geo.size.width * 0.7)
                // Starts fully off the left edge, leaves fully past the right.
                .offset(x: (t * 1.7 - 0.7) * geo.size.width)
            }
            .mask(label)
        }
        .allowsHitTesting(false)
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
