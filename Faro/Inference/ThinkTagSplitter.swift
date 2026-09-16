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

    mutating func consume(_ chunk: String) -> Delta {
        buffer += chunk
        var delta = Delta()

        while true {
            let tag = insideThink ? Self.closeTag : Self.openTag
            if let range = buffer.range(of: tag) {
                let piece = String(buffer[buffer.startIndex..<range.lowerBound])
                if insideThink { delta.reasoning += piece } else { delta.content += piece }
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                insideThink.toggle()
            } else {
                // Keep enough of the tail that a tag split across chunk
                // boundaries can still be recognized next time.
                let keep = tag.count - 1
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
}
