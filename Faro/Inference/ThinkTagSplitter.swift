import Foundation

/// Splits a model's streamed text into visible content and `<think>` /
/// `</think>` reasoning, one chunk at a time. Reasoning-capable models emit
/// both delimiters inline in the token stream (MLXLMCommon's `Generation`
/// has no separate reasoning case), and a delimiter can land split across
/// two chunks, so this buffers the tail of an incomplete tag instead of
/// scanning chunk-by-chunk in isolation.
struct ThinkTagSplitter {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var buffer = ""
    private var insideThink = false

    struct Delta {
        var reasoning = ""
        var content = ""
    }

    /// Longest tag length minus one: how much tail to hold back so a tag
    /// split across chunk boundaries is still recognized next time.
    private static let maxLookback = max(openTag.count, closeTag.count) - 1

    mutating func consume(_ chunk: String) -> Delta {
        buffer += chunk
        var delta = Delta()

        while true {
            // Outside a block, some reasoning-capable chat templates (Qwen3
            // and kin) pre-inject the opening `<think>` into the prompt
            // itself, so the model only ever emits the closing tag. Look for
            // whichever tag actually shows up next instead of assuming the
            // opener always arrives first.
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

            if let range = buffer.range(of: tag) {
                let piece = String(buffer[buffer.startIndex..<range.lowerBound])
                if insideThink || tag == Self.closeTag { delta.reasoning += piece } else { delta.content += piece }
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                insideThink = tag == Self.openTag
            } else {
                let keep = Self.maxLookback
                guard buffer.count > keep else { break }
                let cut = buffer.index(buffer.endIndex, offsetBy: -keep)
                let piece = String(buffer[buffer.startIndex..<cut])
                if insideThink { delta.reasoning += piece } else { delta.content += piece }
                buffer.removeSubrange(buffer.startIndex..<cut)
                break
            }
        }
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
}
