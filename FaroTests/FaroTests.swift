import Testing
@testable import Faro

/// Pure-logic coverage that doesn't touch MLX/GPU, so it runs on the
/// simulator regardless of Metal availability there.
struct ThinkTagSplitterTests {
    @Test func passesPlainTextThrough() {
        var splitter = ThinkTagSplitter()
        let delta = splitter.consume("Hola, ¿en qué te ayudo?")
        #expect(delta.content == "Hola, ¿en qué te ayudo?")
        #expect(delta.reasoning.isEmpty)
    }

    @Test func splitsAReasoningBlockInOneChunk() {
        var splitter = ThinkTagSplitter()
        let delta = splitter.consume("<think>pensando en voz alta</think>respuesta")
        #expect(delta.reasoning == "pensando en voz alta")
        #expect(delta.content == "respuesta")
    }

    @Test func handlesATagSplitAcrossChunks() {
        var splitter = ThinkTagSplitter()
        var reasoning = ""
        var content = ""

        for piece in ["<thi", "nk>razo", "namiento</th", "ink>hola"] {
            let delta = splitter.consume(piece)
            reasoning += delta.reasoning
            content += delta.content
        }

        #expect(reasoning == "razonamiento")
        #expect(content == "hola")
    }

    @Test func supportsMultipleReasoningBlocks() {
        var splitter = ThinkTagSplitter()
        let delta = splitter.consume("<think>uno</think>a<think>dos</think>b")
        #expect(delta.reasoning == "unodos")
        #expect(delta.content == "ab")
    }
}
