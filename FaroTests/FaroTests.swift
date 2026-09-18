import Testing
@testable import Faro

/// Pure-logic coverage that doesn't touch MLX/GPU, so it runs on the
/// simulator regardless of Metal availability there.
struct ThinkTagSplitterTests {
    /// Feeds every chunk, then calls `finish()` (as the real stream
    /// consumer does once generation ends) and returns the combined delta.
    /// Mirrors how `ChatViewModel` handles `contentWasReasoning`.
    private func run(_ chunks: [String]) -> (reasoning: String, content: String) {
        var splitter = ThinkTagSplitter()
        var reasoning = ""
        var content = ""
        for chunk in chunks {
            let delta = splitter.consume(chunk)
            if delta.contentWasReasoning {
                reasoning += content
                content = ""
            }
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

    /// The regression that mattered: text used to sit in the buffer until
    /// a tag showed up (or 4 KB piled up), so a model that never reasons
    /// aloud printed nothing until it had finished.
    @Test func streamsEachChunkInsteadOfBufferingUntilATagArrives() {
        var splitter = ThinkTagSplitter()
        #expect(splitter.consume("Hola, ").content == "Hola, ")
        #expect(splitter.consume("¿qué tal?").content == "¿qué tal?")
    }

    @Test func holdsBackOnlyWhatCouldStillBecomeATag() {
        var splitter = ThinkTagSplitter()
        #expect(splitter.consume("cinco < siete").content == "cinco < siete")
        #expect(splitter.consume("y luego </thi").content == "y luego ")
        #expect(splitter.consume("nk>listo").content == "listo")
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

    /// Split that way, the reasoning has already been streamed as content
    /// before the closing tag identifies it — the delta says so and the
    /// consumer moves it across.
    @Test func reclassifiesTextAlreadyStreamedWhenTheBlockWasOpenedInThePrompt() {
        let result = run(["razo", "no</th", "ink>resp", "uesta"])
        #expect(result.reasoning == "razono")
        #expect(result.content == "respuesta")
    }

    @Test func doesNotReclassifyOnceARealOpeningTagHasBeenSeen() {
        var splitter = ThinkTagSplitter()
        _ = splitter.consume("<think>uno</think>")
        let delta = splitter.consume("respuesta")
        #expect(delta.content == "respuesta")
        #expect(!delta.contentWasReasoning)
    }
}

struct ModelLoadStatusFormatterTests {
    @Test func reportsProgressWithoutAnEstimatedTimeLeft() {
        let status = ModelLoadStatus(
            phase: .downloading, fraction: 0.5,
            completedBytes: 500_000_000, totalBytes: 1_000_000_000,
            bytesPerSecond: 1_000_000
        )
        let line = ModelLoadStatusFormatter.line(status)
        #expect(line.hasPrefix("50 %"))
        #expect(!line.contains("quedan"))
    }
}

struct ModelCacheStoreTests {
    @Test func parsesARepoIDFromItsCacheDirectoryName() {
        #expect(
            ModelCacheStore.repoID(fromDirectoryName: "models--mlx-community--Qwen2.5-0.5B-Instruct-4bit")
                == "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
        )
    }

    @Test func rejectsNamesWithoutTheModelsPrefixOrANamespaceSeparator() {
        #expect(ModelCacheStore.repoID(fromDirectoryName: "datasets--squad") == nil)
        #expect(ModelCacheStore.repoID(fromDirectoryName: "models--incomplete") == nil)
    }
}
