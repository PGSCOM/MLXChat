import SwiftUI
import UIKit

struct MessageView: View {
    let message: ChatMessage
    /// Set only on the message currently being generated, so the bubble
    /// can report what the model is doing right now.
    var liveTurn: LiveTurn?
    let viewModel: ChatViewModel
    /// Models already on disk, for the "relanzar con" menu — same list
    /// `ChatView`'s own model picker uses.
    let quickModelIDs: [String]

    struct LiveTurn: Equatable {
        let phase: TurnPhase
        let startedAt: Date
    }

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                HStack {
                    Spacer(minLength: 48)
                    UserBubble(message: message)
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = message.content
                            } label: {
                                Label("Copiar", systemImage: "doc.on.doc")
                            }
                            if !viewModel.isGenerating {
                                Button {
                                    viewModel.beginEditing(message)
                                } label: {
                                    Label("Editar", systemImage: "pencil")
                                }
                            }
                        }
                }
                if siblings.count > 1 {
                    BranchSwitcher(index: siblingIndex, count: siblings.count, disabled: viewModel.isGenerating) { offset in
                        viewModel.showSibling(of: message, offset: offset)
                    }
                }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                // Walks the turn in the order it actually happened — think,
                // call a tool, think again, answer — instead of one
                // reasoning blob followed by every tool card at the end.
                ForEach(Array(timeline.enumerated()), id: \.offset) { _, item in
                    switch item {
                    case .text(let text):
                        textView(text)
                    case .step(let step, let text):
                        stepView(step, text: text)
                    }
                }
                // Between blocks (waiting for the first token, or right
                // after a tool result) no step is open yet — still show a
                // live card so the bubble doesn't sit there looking stuck.
                if showsThinkingPlaceholder {
                    ReasoningCard(text: "", isLive: true, seconds: nil, startedAt: liveTurn?.startedAt)
                }
                if let liveTurn, showsStatusLine(liveTurn) {
                    TurnStatusLine(turn: liveTurn)
                }
                if liveTurn == nil {
                    AssistantActionRow(
                        message: message, viewModel: viewModel, quickModelIDs: quickModelIDs,
                        siblings: siblings, siblingIndex: siblingIndex
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 48)
        case .system:
            EmptyView()
        }
    }

    private var siblings: [ChatMessage] { viewModel.siblings(of: message) }

    private var siblingIndex: Int {
        siblings.firstIndex(where: { $0.id == message.id }) ?? 0
    }

    /// The turn's steps interleaved back into `content`, in the order they
    /// actually streamed — a step only records where it sits (a character
    /// range, an offset), so this recomputes cheaply on every redraw.
    private var timeline: [TurnTimelineItem] {
        TurnStep.timeline(content: message.content, reasoning: message.reasoning ?? "", steps: message.steps)
    }

    /// A reasoning block still open (no `end` yet) can only be the one the
    /// model is writing right now — `finish()` always closes whatever was
    /// open before a turn's stream ends, so a closed conversation loaded
    /// back from disk never has one.
    private func isOpenReasoningStep(_ step: TurnStep) -> Bool {
        guard liveTurn != nil, case .reasoning(_, let end) = step.kind else { return false }
        return end == nil
    }

    @ViewBuilder private func textView(_ text: String) -> some View {
        // Artifacts are only derived once the turn is done — parsing
        // mid-stream could turn a half-written fence into a false positive.
        if liveTurn == nil {
            ForEach(ArtifactParser.segments(text)) { segment in
                switch segment {
                case .text(_, let piece):
                    MarkdownText(content: piece)
                        .foregroundStyle(FaroColor.bone)
                case .artifact(let artifact):
                    ArtifactCard(artifact: artifact)
                }
            }
        } else {
            MarkdownText(content: text)
                .foregroundStyle(FaroColor.bone)
        }
    }

    /// One card for both states, so a block doesn't change shape the moment
    /// it closes — only its title and its body do.
    @ViewBuilder private func stepView(_ step: TurnStep, text: String?) -> some View {
        switch step.kind {
        case .reasoning:
            let isOpen = isOpenReasoningStep(step)
            let text = text ?? ""
            if isOpen || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ReasoningCard(text: text, isLive: isOpen, seconds: step.seconds, startedAt: isOpen ? step.startedAt : nil)
            }
        case .tool(let record):
            ToolCallCard(call: record, startedAt: step.startedAt, seconds: step.seconds)
        }
    }

    /// True only between blocks: the model is thinking again (a tool result
    /// just came back, or the very first token hasn't landed) but no
    /// reasoning step is open yet to carry a live card of its own.
    private var showsThinkingPlaceholder: Bool {
        guard let liveTurn, liveTurn.phase == .thinking else { return false }
        return !timeline.contains {
            if case .step(let step, _) = $0 { return isOpenReasoningStep(step) }
            return false
        }
    }

    private func showsStatusLine(_ turn: LiveTurn) -> Bool {
        // While thinking or using a tool, that step's own card already
        // carries the label and the counter — two live timers is just noise.
        if turn.phase == .thinking || turn.phase == .usingTool { return false }
        return message.content.isEmpty || turn.phase != .writing
    }
}

/// The short name shown for a model — the toolbar picker (`ChatView`) uses
/// the same one, so a model reads identically everywhere it's named.
func shortModelName(_ modelID: String) -> String {
    if modelID == AppleFoundationModel.id { return AppleFoundationModel.displayName }
    return modelID.split(separator: "/").last.map(String.init) ?? modelID
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
        case .usingTool: "Usando herramienta…"
        case .writing: "Escribiendo…"
        case .idle: ""
        }
    }
}

/// The row under a finished reply: copy, relaunch (optionally with another
/// model), a branch switcher when other versions exist, and which model
/// wrote this one. Bare icons only — no tiles, no dividers, no pills.
private struct AssistantActionRow: View {
    let message: ChatMessage
    let viewModel: ChatViewModel
    let quickModelIDs: [String]
    let siblings: [ChatMessage]
    let siblingIndex: Int
    @State private var copied = false

    var body: some View {
        HStack(spacing: 18) {
            Button {
                UIPasteboard.general.string = message.content
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(copied ? FaroColor.lamp : FaroColor.ash)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? "Copiado" : "Copiar el mensaje")

            if !viewModel.isGenerating {
                Menu {
                    Button {
                        viewModel.regenerate(message)
                    } label: {
                        Label("Relanzar", systemImage: "arrow.clockwise")
                    }
                    if !otherModels.isEmpty {
                        Section("Relanzar con") {
                            ForEach(otherModels, id: \.self) { id in
                                Button(shortModelName(id)) {
                                    viewModel.regenerate(message, with: id)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FaroColor.ash)
                }
                .accessibilityLabel("Relanzar la respuesta")
            }

            if siblings.count > 1 {
                BranchSwitcher(index: siblingIndex, count: siblings.count, disabled: viewModel.isGenerating) { offset in
                    viewModel.showSibling(of: message, offset: offset)
                }
            }

            Spacer(minLength: 8)

            footer
        }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// Other downloaded models this reply could be relaunched with —
    /// whichever model actually wrote it (which may no longer be the
    /// conversation's current model) is left out of its own list.
    private var otherModels: [String] {
        quickModelIDs.filter { $0 != (message.modelID ?? viewModel.conversation.modelID) }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let modelID = message.modelID {
                Text(shortModelName(modelID)).lineLimit(1)
            }
            if let tps = message.tokensPerSecond, tps > 0 {
                Text(String(format: "%.1f tok/s", tps))
                    .font(.system(.caption2, design: .monospaced))
            }
        }
        .font(.footnote)
        .foregroundStyle(FaroColor.ash)
    }
}

/// `‹ 2/3 ›`: switches between sibling versions of an edited or relaunched
/// message. The ends disable rather than wrap, so the count never lies.
private struct BranchSwitcher: View {
    let index: Int
    let count: Int
    let disabled: Bool
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button { select(-1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(disabled || index == 0)
            .accessibilityLabel("Versión anterior")

            Text("\(index + 1)/\(count)")
                .font(.footnote)
                .monospacedDigit()
                .accessibilityLabel("Versión \(index + 1) de \(count)")

            Button { select(1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(disabled || index == count - 1)
            .accessibilityLabel("Versión siguiente")
        }
        .foregroundStyle(FaroColor.ash)
        .opacity(disabled ? 0.5 : 1)
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

/// One row per tool or skill call. Same card language as `ReasoningCard`.
/// The arguments summary is always visible — what was actually asked is the
/// point of showing an MCP call — and the card opens (even while still
/// running, if there are arguments to show) to reveal the full request and,
/// once it lands, the response or error.
private struct ToolCallCard: View {
    let call: ToolCallRecord
    /// When this call started — drives the live counter while running, and
    /// backdates the placeholder shown before any result exists.
    let startedAt: Date
    let seconds: Double?
    @State private var expanded = false

    private var isRunning: Bool { if case .running = call.status { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            // Always visible, not just once expanded: what was actually
            // asked (the search query, the file path…) is the whole point
            // of showing an MCP call, not a detail to dig for.
            if let summary = call.argumentsSummary {
                Text(summary)
                    .font(.footnote)
                    .foregroundStyle(FaroColor.ash)
                    .lineLimit(2)
            }
            if expanded {
                if let arguments = call.arguments {
                    detailSection(title: "Solicitud", content: arguments)
                }
                if let detail {
                    detailSection(title: detailTitle, content: detail)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .faroCard()
    }

    private var canExpand: Bool { call.arguments != nil || detail != nil }

    private var detail: String? {
        switch call.status {
        case .running: nil
        case .succeeded(let preview): preview.isEmpty ? nil : preview
        case .failed(let message): message
        }
    }

    private var detailTitle: String {
        if case .failed = call.status { return "Error" }
        return "Respuesta"
    }

    private func detailSection(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(FaroColor.bone)
            Text(content)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(FaroColor.ash)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var header: some View {
        if canExpand {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                headerRow
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Ocultar la llamada" : "Mostrar la llamada")
        } else {
            headerRow
        }
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            icon
            if isRunning {
                SweptLabel(text: title)
            } else {
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(FaroColor.bone)
            }
            if let server = call.server {
                Text("· \(server)")
                    .font(.footnote)
                    .foregroundStyle(FaroColor.ash)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            duration
            if canExpand {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FaroColor.ash)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .contentShape(.rect)
    }

    @ViewBuilder private var duration: some View {
        if isRunning {
            TimelineView(.periodic(from: startedAt, by: 1)) { timeline in
                Text(ReasoningCard.elapsedLabel(since: startedAt, at: timeline.date))
                    .font(.footnote)
                    .monospacedDigit()
                    .foregroundStyle(FaroColor.ash)
            }
        } else if let durationText = Self.durationLabel(seconds) {
            Text(durationText)
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(FaroColor.ash)
        }
    }

    private var label: String { call.isSkill ? "Skill: \(call.name)" : call.name }

    private var title: String {
        switch call.status {
        case .running: "Llamando a \(label)…"
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

    private static func durationLabel(_ seconds: Double?) -> String? {
        guard let seconds, seconds >= 0.1 else { return nil }
        return seconds < 60
            ? String(format: "%.1f s", seconds)
            : "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
    }
}

/// A user turn: its image (if any), its attachment named but not spelled
/// out in full, then what was actually typed. A pasted file's extracted
/// text used to sit inline in the bubble; it now lives on the message
/// itself, so only the file name shows here.
private struct UserBubble: View {
    let message: ChatMessage
    @State private var expanded = false
    private static let previewLimit = 600

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let imageData = message.imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 220, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            if let name = message.attachmentName {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                    Text(name).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(FaroColor.ash)
            }
            MarkdownText(content: displayedContent)
                .foregroundStyle(FaroColor.bone)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .faroCard()

            if message.content.count > Self.previewLimit {
                Button(expanded ? "Mostrar menos" : "Mostrar todo") {
                    expanded.toggle()
                }
                .font(.caption)
                .foregroundStyle(FaroColor.ash)
            }
        }
    }

    private var displayedContent: String {
        guard !expanded, message.content.count > Self.previewLimit else { return message.content }
        return String(message.content.prefix(Self.previewLimit)) + "…"
    }
}
