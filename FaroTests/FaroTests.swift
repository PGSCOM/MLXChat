import Testing
@testable import Faro

/// Pure-logic coverage that doesn't touch MLX/GPU, so it runs on the
/// simulator regardless of Metal availability there.
struct ThinkTagSplitterTests {
    /// Feeds every chunk, then calls `finish()` (as the real stream
    /// consumer does once generation ends) and returns the combined delta.
    private func run(_ chunks: [String]) -> (reasoning: String, content: String) {
        var splitter = ThinkTagSplitter()
        var reasoning = ""
        var content = ""
        for chunk in chunks {
            let delta = splitter.consume(chunk)
            reasoning += delta.reasoning
            content += delta.content
        }
        let tail = splitter.finish()
        reasoning += tail.reasoning
        content += tail.content
        return (reasoning, content)
    }

    @Test func passesPlainTextThrough() {
        let result = run(["Hola, ¿en qué te ayudo?"])
        #expect(result.content == "Hola, ¿en qué te ayudo?")
        #expect(result.reasoning.isEmpty)
    }

    @Test func splitsAReasoningBlockInOneChunk() {
        let result = run(["<think>pensando en voz alta</think>respuesta"])
        #expect(result.reasoning == "pensando en voz alta")
        #expect(result.content == "respuesta")
    }

    @Test func handlesATagSplitAcrossChunks() {
        let result = run(["<thi", "nk>razo", "namiento</th", "ink>hola"])
        #expect(result.reasoning == "razonamiento")
        #expect(result.content == "hola")
    }

    @Test func supportsMultipleReasoningBlocks() {
        let result = run(["<think>uno</think>a<think>dos</think>b"])
        #expect(result.reasoning == "unodos")
        #expect(result.content == "ab")
    }

    @Test func leavesAnUnterminatedThinkBlockAsReasoning() {
        // If the stream ends mid-block (truncated generation), finish()
        // must not silently drop the partial reasoning text.
        let result = run(["<think>a la mitad"])
        #expect(result.reasoning == "a la mitad")
        #expect(result.content.isEmpty)
    }

    @Test func handlesAnImplicitlyOpenedBlock() {
        // Chat templates (Qwen3 and kin) pre-inject the opening `<think>`
        // into the prompt, so the model's own stream only carries the
        // closing tag.
        let result = run(["razono</think>respuesta"])
        #expect(result.reasoning == "razono")
        #expect(result.content == "respuesta")
    }

    @Test func handlesAnImplicitlyOpenedBlockSplitAcrossChunks() {
        let result = run(["razo", "no</th", "ink>resp", "uesta"])
        #expect(result.reasoning == "razono")
        #expect(result.content == "respuesta")
    }
}
