import Foundation

/// Splits a model's streamed text into visible content and `<think>` /
/// `</think>` reasoning, one chunk at a time. Reasoning-capable models emit
/// both delimiters inline in the token stream (MLXLMCommon's `Generation`
/// has no separate reasoning case), and a delimiter can land split across
/// two chunks, so this holds back only the tail that could still grow into
/// a real tag and releases everything else immediately. Gemma 4 uses its
/// own channel delimiters for the same span (`<|channel>thought` /
/// `<channel|>`) — normalized to `<think>`/`</think>` up front so the rest
/// of this type never has to know two dialects.
struct ThinkTagSplitter {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"
    /// Gemma 4 marks the same reasoning span with its own channel
    /// delimiters. Normalized to the tags above as the very first step of
    /// `consume`, so every dialect after that point (implicit-reopen
    /// detection, `heldBackCount`) only ever has to know one.
    private static let gemmaOpenTag = "<|channel>thought"
    private static let gemmaCloseTag = "<channel|>"

    private var buffer = ""
    private var insideThink = false
    /// Whether a real `<think>` has arrived *for the block currently being
    /// awaited*. Until one does, a bare `</think>` means the chat template
    /// opened the block inside the prompt (Qwen3 and kin) and everything
    /// since the last block closed was reasoning. Reset after every block
    /// closes — not just once — because a tool-calling turn can hand the
    /// model back control after a call, and a template that pre-opens
    /// `<think>` does so for *that* generation prompt too, not only the
    /// first one.
    private var hasSeenOpenTag = false
    /// Characters released as plain `content` since the current segment
    /// started (i.e. since the last block closed, or since the turn began).
    /// Reset alongside `hasSeenOpenTag`, so it only ever covers the segment
    /// that's actually at risk of being retroactively reclassified — not
    /// the whole turn.
    private var contentSinceSegmentStart = 0

    struct Delta {
        var reasoning = ""
        var content = ""
        /// Set once, when a bare `</think>` reveals that everything already
        /// streamed as content was really reasoning. The alternative is to
        /// withhold the start of every answer until a tag shows up or never
        /// does — which is exactly what used to stall the whole stream.
        var contentWasReasoning = false
        /// Trailing characters of the *consumer's own already-accumulated*
        /// content (not this delta's) that belong to the block that just
        /// closed and should move into reasoning. 0 when `contentWasReasoning`
        /// is false. Counts only what leaked since the *last* block boundary
        /// (explicit or implicit) — not everything ever accumulated — so
        /// real content an earlier explicit block already vouched for
        /// survives a later implicit block's reclaim. It can NOT tell apart
        /// real content from leaked reasoning within the *same* unbroken
        /// stretch (see `consume`'s doc comment for why).
        var reclaimedContentLength = 0
    }

    /// Call when a tool call starts: real content written right before it
    /// ("Voy a buscar…") would otherwise be indistinguishable from the next
    /// implicitly-reopened block's own leaked reasoning, since both are just
    /// "content since the last close" — this draws the boundary explicitly
    /// instead of guessing at it.
    mutating func commitContent() {
        hasSeenOpenTag = false
        contentSinceSegmentStart = 0
    }

    mutating func consume(_ chunk: String) -> Delta {
        buffer += chunk
        buffer = buffer.replacingOccurrences(of: Self.gemmaOpenTag, with: Self.openTag)
        buffer = buffer.replacingOccurrences(of: Self.gemmaCloseTag, with: Self.closeTag)
        var delta = Delta()

        while true {
            // Outside a block, look for whichever tag actually shows up
            // next instead of assuming the opener always arrives first.
            let tag: String
            if insideThink {
                tag = Self.closeTag
            } else if let openRange = buffer.range(of: Self.openTag) {
                tag = buffer.range(of: Self.closeTag)
                    .map { $0.lowerBound < openRange.lowerBound ? Self.closeTag : Self.openTag }
                    ?? Self.openTag
            } else {
                tag = buffer.range(of: Self.closeTag) != nil ? Self.closeTag : Self.openTag
            }

            guard let range = buffer.range(of: tag) else { break }
            let piece = String(buffer[buffer.startIndex..<range.lowerBound])

            if tag == Self.openTag {
                hasSeenOpenTag = true
                delta.content += piece
            } else {
                if !insideThink && !hasSeenOpenTag && contentSinceSegmentStart > 0 {
                    // Implicitly opened block: reclaim only this segment's
                    // own leaked content, not the consumer's whole message.
                    delta.contentWasReasoning = true
                    delta.reclaimedContentLength = contentSinceSegmentStart
                }
                delta.reasoning += piece
                // This block is done — the *next* one starts fresh and may
                // just as well be implicitly opened again.
                hasSeenOpenTag = false
                contentSinceSegmentStart = 0
            }

            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            insideThink = tag == Self.openTag
        }

        // No complete tag left: release everything except a trailing
        // fragment that could still turn into one on the next chunk.
        let held = Self.heldBackCount(buffer)
        guard held < buffer.count else { return delta }
        let cut = buffer.index(buffer.endIndex, offsetBy: -held)
        let piece = String(buffer[buffer.startIndex..<cut])
        if insideThink {
            delta.reasoning += piece
        } else {
            delta.content += piece
            if !hasSeenOpenTag { contentSinceSegmentStart += piece.count }
        }
        buffer.removeSubrange(buffer.startIndex..<cut)
        return delta
    }

    /// Call once the stream has ended: whatever is still held back as
    /// tag-boundary lookahead can no longer become a real tag, so it's
    /// released as plain content (or reasoning, if a `<think>` block was
    /// left unterminated). Without this, the last few characters of every
    /// response would silently vanish.
    mutating func finish() -> Delta {
        defer { buffer = "" }
        var delta = Delta()
        if insideThink { delta.reasoning = buffer } else { delta.content = buffer }
        return delta
    }

    /// Length of the longest suffix that is still a possible start of a
    /// tag. Anything shorter than that streams out right away, so text
    /// reaches the screen token by token instead of lagging behind a
    /// fixed-size lookahead window.
    private static func heldBackCount(_ text: String) -> Int {
        let tags = [openTag, closeTag, gemmaOpenTag, gemmaCloseTag]
        let longest = min(tags.map(\.count).max()! - 1, text.count)
        guard longest > 0 else { return 0 }
        for length in stride(from: longest, through: 1, by: -1) {
            let suffix = text.suffix(length)
            if tags.contains(where: { $0.hasPrefix(suffix) }) { return length }
        }
        return 0
    }
}
