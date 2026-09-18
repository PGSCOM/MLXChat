import Foundation

/// Splits a model's streamed text into visible content and `<think>` /
/// `</think>` reasoning, one chunk at a time. Reasoning-capable models emit
/// both delimiters inline in the token stream (MLXLMCommon's `Generation`
/// has no separate reasoning case), and a delimiter can land split across
/// two chunks, so this holds back only the tail that could still grow into
/// a real tag and releases everything else immediately.
struct ThinkTagSplitter {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var buffer = ""
    private var insideThink = false
    /// Whether a real `<think>` has arrived. Until one does, a bare
    /// `</think>` means the chat template opened the block inside the
    /// prompt (Qwen3 and kin) and everything so far was reasoning.
    private var hasSeenOpenTag = false
    private var emittedContentBeforeAnyTag = false

    struct Delta {
        var reasoning = ""
        var content = ""
        /// Set once, when a bare `</think>` reveals that everything already
        /// streamed as content was really reasoning. The alternative is to
        /// withhold the start of every answer until a tag shows up or never
        /// does — which is exactly what used to stall the whole stream.
        var contentWasReasoning = false
    }

    mutating func consume(_ chunk: String) -> Delta {
        buffer += chunk
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
                if !insideThink && !hasSeenOpenTag {
                    // Implicitly opened block: reclaim what already went out.
                    hasSeenOpenTag = true
                    if emittedContentBeforeAnyTag {
                        delta.contentWasReasoning = true
                        delta.reasoning = delta.content + delta.reasoning
                        delta.content = ""
                    }
                }
                delta.reasoning += piece
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
            if !hasSeenOpenTag && !piece.isEmpty { emittedContentBeforeAnyTag = true }
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
        let longest = min(max(openTag.count, closeTag.count) - 1, text.count)
        guard longest > 0 else { return 0 }
        for length in stride(from: longest, through: 1, by: -1) {
            let suffix = text.suffix(length)
            if openTag.hasPrefix(suffix) || closeTag.hasPrefix(suffix) { return length }
        }
        return 0
    }
}
