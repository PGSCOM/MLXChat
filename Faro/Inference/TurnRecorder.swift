import Foundation

/// Turns one assistant turn's raw stream into `message.content` /
/// `message.reasoning` plus the ordered `TurnStep`s that let the UI replay
/// the turn as it actually happened — think, call a tool, think again,
/// answer — instead of one reasoning blob followed by every tool card.
///
/// Owns the turn's one `ThinkTagSplitter`: the token loop and the tool-call
/// listener both need to agree on where a reasoning block is currently
/// open, which is exactly what living in two places used to make impossible
/// (see `ThinkTagSplitter.commitContent`).
@MainActor
final class TurnRecorder {
    private let message: ChatMessage
    private var splitter = ThinkTagSplitter()
    /// The currently-open reasoning step's id, if any — closed (given an
    /// `end` and a duration) as soon as content resumes, a tool call
    /// starts, or the turn finishes.
    private var openStepID: UUID?
    /// When the current segment (since the turn began, or since the last
    /// block boundary) started — an implicitly-opened reasoning block
    /// (see `ThinkTagSplitter`) is backdated to here, since its text was
    /// already streaming out as content before the close tag revealed it.
    private var segmentStartedAt = Date.now

    init(message: ChatMessage) {
        self.message = message
    }

    /// Feeds one chunk of the stream. Returns the phase it moved the turn
    /// into, if any, so the caller can drive its own status line.
    @discardableResult
    func consume(_ chunk: String) -> TurnPhase? {
        let delta = splitter.consume(chunk)
        var phase: TurnPhase?

        if delta.contentWasReasoning {
            // A bare `</think>` revealed the tail of `content` was really
            // reasoning — move it into the (new) open step first.
            let content = message.content
            let cut = content.index(content.endIndex, offsetBy: -delta.reclaimedContentLength)
            let reclaimed = String(content[cut...])
            message.content = String(content[..<cut])
            if openStepID == nil { openReasoningStep() }
            appendReasoning(reclaimed)
        }
        if !delta.reasoning.isEmpty {
            if openStepID == nil { openReasoningStep() }
            appendReasoning(delta.reasoning)
            phase = .thinking
        }
        if !delta.content.isEmpty {
            closeOpenReasoningStep()
            message.content += delta.content
            phase = .writing
        }
        return phase
    }

    /// Call when a tool call starts. Closes whatever reasoning was open
    /// (the model usually calls a tool right after `</think>`, with no
    /// content in between, so `consume` alone would never close it) and
    /// draws an explicit segment boundary so text written just before the
    /// call isn't later reclaimed as the next block's leaked reasoning.
    func toolStarted(_ record: ToolCallRecord) {
        closeOpenReasoningStep()
        splitter.commitContent()
        var steps = message.steps
        steps.append(TurnStep(id: record.id, kind: .tool(record), contentOffset: message.content.count))
        message.steps = steps
        segmentStartedAt = .now
    }

    func toolFinished(id: UUID, status: ToolCallStatus) {
        var steps = message.steps
        guard let index = steps.firstIndex(where: { $0.id == id }),
            case .tool(var record) = steps[index].kind
        else { return }
        record.status = status
        steps[index].kind = .tool(record)
        steps[index].seconds = Date.now.timeIntervalSince(steps[index].startedAt)
        message.steps = steps
    }

    /// Call once the stream has ended: releases whatever the splitter was
    /// still holding back as tag lookahead, closes any still-open reasoning
    /// step, and fails any tool call left `.running` — a cancellation can
    /// land here before its own `.finished` event does, which would
    /// otherwise leave that card spinning forever.
    func finish() {
        let tail = splitter.finish()
        if !tail.reasoning.isEmpty {
            if openStepID == nil { openReasoningStep() }
            appendReasoning(tail.reasoning)
        }
        if !tail.content.isEmpty {
            message.content += tail.content
        }
        closeOpenReasoningStep()

        var steps = message.steps
        var changed = false
        for index in steps.indices {
            guard case .tool(var record) = steps[index].kind, case .running = record.status else { continue }
            record.status = .failed("Cancelada")
            steps[index].kind = .tool(record)
            steps[index].seconds = Date.now.timeIntervalSince(steps[index].startedAt)
            changed = true
        }
        if changed { message.steps = steps }
    }

    private func openReasoningStep() {
        var steps = message.steps
        let start = message.reasoning?.count ?? 0
        let step = TurnStep(
            kind: .reasoning(start: start, end: nil), contentOffset: message.content.count,
            startedAt: segmentStartedAt
        )
        openStepID = step.id
        steps.append(step)
        message.steps = steps
    }

    private func appendReasoning(_ text: String) {
        message.reasoning = (message.reasoning ?? "") + text
    }

    private func closeOpenReasoningStep() {
        guard let openStepID else { return }
        defer {
            self.openStepID = nil
            segmentStartedAt = .now
        }
        var steps = message.steps
        guard let index = steps.firstIndex(where: { $0.id == openStepID }),
            case .reasoning(let start, _) = steps[index].kind
        else { return }
        steps[index].kind = .reasoning(start: start, end: message.reasoning?.count ?? start)
        steps[index].seconds = Date.now.timeIntervalSince(steps[index].startedAt)
        message.steps = steps
    }
}
