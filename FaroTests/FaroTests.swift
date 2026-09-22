import Foundation
import Testing
@testable import Faro

/// Pure-logic coverage that doesn't touch MLX/GPU, so it runs on the
/// simulator regardless of Metal availability there.
struct ThinkTagSplitterTests {
    /// Feeds every chunk, then calls `finish()` (as the real stream
    /// consumer does once generation ends) and returns the combined delta.
    /// Mirrors how `ChatViewModel`/`APIServer`/`AskFaroIntent` handle
    /// `contentWasReasoning`: reclaim only the reported suffix of the
    /// accumulated content, not all of it.
    private func run(_ chunks: [String]) -> (reasoning: String, content: String) {
        var splitter = ThinkTagSplitter()
        var reasoning = ""
        var content = ""
        for chunk in chunks {
            let delta = splitter.consume(chunk)
            if delta.contentWasReasoning {
                let cut = content.index(content.endIndex, offsetBy: -delta.reclaimedContentLength)
                reasoning += content[cut...]
                content = String(content[..<cut])
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

    /// A reasoning model that calls a tool mid-turn: `InferenceEngine`
    /// resolves the call inside `ChatSession` and only streams the clean
    /// continuation onward, but if that continuation's chat template also
    /// pre-opens `<think>` (as Qwen3-style templates do for every
    /// generation prompt, not just the first), the model's second segment
    /// arrives with no literal `<think>` either — same shape as the very
    /// first implicit block, split across chunks the way real streaming
    /// does it.
    @Test func recoversASecondImplicitlyOpenedBlockAfterATheoreticalToolCall() {
        let result = run(["primero</think>", "lue", "go</think>final"])
        #expect(result.reasoning == "primeroluego")
        #expect(result.content == "final")
    }

    /// The sibling bug the fix above could introduce if reclaiming moved
    /// *everything* accumulated instead of just the current block's own
    /// leaked tail: "X" is real content, protected from the later implicit
    /// block's reclaim by an EXPLICIT block ("Y") that closed in between —
    /// that close resets the leak counter without touching "X", so only
    /// "Z" (leaked after it, before the next bare `</think>`) gets pulled
    /// into reasoning. (A bare `</think>` immediately after real content
    /// with no other close in between — e.g. real text written right
    /// before a tool call, then the model reasons again with no explicit
    /// tag — is NOT distinguishable from this splitter's text stream alone;
    /// see the note on `ThinkTagSplitter.consume`.)
    @Test func laterImplicitBlockDoesNotSweepUpContentProtectedByAnEarlierExplicitBlock() {
        let result = run(["uno</think>", "X", "<think>Y</think>", "Z", "reasoning</think>final"])
        #expect(result.reasoning == "unoYZreasoning")
        #expect(result.content == "Xfinal")
    }
}

/// The `<think>` the chat template leaves open in the prompt itself —
/// what `InferenceEngine` inspects to decide whether to replay an opening
/// tag into the stream.
struct PromptOpensThinkTests {
    @Test func detectsATemplateThatLeavesTheBlockOpen() {
        #expect(InferenceEngine.endsInsideThink("<|im_start|>assistant\n<think>\n"))
    }

    @Test func rejectsATemplateThatPreClosesTheBlock() {
        #expect(!InferenceEngine.endsInsideThink("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
    }

    @Test func rejectsATemplateWithNoThinkTagAtAll() {
        #expect(!InferenceEngine.endsInsideThink("<|im_start|>assistant\n"))
    }

    @Test func ignoresClosedBlocksQuotedEarlierInTheHistory() {
        #expect(InferenceEngine.endsInsideThink("<think>previo</think>respuesta<|im_start|>assistant\n<think>"))
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

struct DefaultModelTests {
    @Test func startsFromTheLastModelTheUserPicked() {
        #expect(DefaultModel.resolve(remembered: "a/b", downloaded: ["a/b", "c/d"]) == "a/b")
    }

    /// iOS may purge the cache, and the user can delete a model by hand —
    /// either way a new conversation shouldn't open on a missing model.
    @Test func fallsBackWhenTheRememberedModelIsGone() {
        #expect(DefaultModel.resolve(remembered: "a/b", downloaded: []) == DefaultModel.repoID)
    }

    @Test func fallsBackWhenNothingWasEverPicked() {
        #expect(DefaultModel.resolve(remembered: "", downloaded: ["a/b"]) == DefaultModel.repoID)
    }

    /// Apple's model never appears in the cache listing because it isn't
    /// on disk at all.
    @Test func keepsAppleFoundationWithoutAskingTheCache() {
        #expect(
            DefaultModel.resolve(remembered: AppleFoundationModel.id, downloaded: [])
                == AppleFoundationModel.id
        )
    }
}

struct VoiceSettingsTests {
    /// The exact bug this fixes: `AVSpeechSynthesisVoice(language:)` wants
    /// BCP-47, and `Locale.identifier` alone hands it ICU with an
    /// underscore, which it rejects.
    @Test func languageTagUsesHyphensNotUnderscores() {
        #expect(Locale(identifier: "es_ES").identifier(.bcp47) == "es-ES")
    }

    @Test func matchesTheExactLanguageTag() {
        #expect(VoiceSettings.matches(voiceLanguage: "es-ES", preferred: "es-ES"))
    }

    @Test func matchesTheSameLanguageInAnotherRegion() {
        #expect(VoiceSettings.matches(voiceLanguage: "es-MX", preferred: "es-ES"))
    }

    @Test func rejectsADifferentLanguage() {
        #expect(!VoiceSettings.matches(voiceLanguage: "en-US", preferred: "es-ES"))
    }
}

struct ReasoningCardTests {
    @Test func namesTheBlockBeforeItHasADuration() {
        #expect(ReasoningCard.durationLabel(nil) == "Pensamientos")
        #expect(ReasoningCard.durationLabel(0.4) == "Pensamientos")
    }

    @Test func reportsSecondsAndMinutes() {
        #expect(ReasoningCard.durationLabel(23) == "Razonó durante 23 s")
        #expect(ReasoningCard.durationLabel(95) == "Razonó durante 1 min 35 s")
    }

    @Test func countsUpFromTheStartOfThePhase() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(ReasoningCard.elapsedLabel(since: start, at: start.addingTimeInterval(7)) == "7 s")
        #expect(ReasoningCard.elapsedLabel(since: start, at: start.addingTimeInterval(65)) == "1 min 5 s")
    }
}

struct ArtifactParserTests {
    @Test func shortCodeBlockStaysInline() {
        let content = "texto\n```swift\nlet x = 1\n```\nfin"
        let segments = ArtifactParser.segments(content)
        #expect(segments.count == 1)
        if case .text(_, let text) = segments.first { #expect(text == content) } else { Issue.record("expected text") }
    }

    @Test func longCodeBlockIsPromoted() {
        let body = (1...10).map { "línea \($0)" }.joined(separator: "\n")
        let content = "antes\n```swift\n\(body)\n```\ndespués"
        let segments = ArtifactParser.segments(content)
        #expect(segments.count == 3)
        guard case .artifact(let artifact) = segments[1] else {
            Issue.record("expected artifact")
            return
        }
        #expect(artifact.language == "swift")
        #expect(artifact.content == body)
    }

    @Test func htmlIsPromotedRegardlessOfLength() {
        let content = "```html\n<p>hola</p>\n```"
        let segments = ArtifactParser.segments(content)
        #expect(segments.count == 1)
        guard case .artifact(let artifact) = segments.first else {
            Issue.record("expected artifact")
            return
        }
        #expect(artifact.isPreviewable)
        #expect(artifact.fileExtension == "html")
    }

    @Test func unclosedFenceStaysAsText() {
        let content = "algo\n```swift\nsin cerrar"
        let segments = ArtifactParser.segments(content)
        #expect(segments.count == 1)
        if case .text(_, let text) = segments.first { #expect(text == content) } else { Issue.record("expected text") }
    }

    @Test func titleComesFromTheInfoStringWhenPresent() {
        let content = "```swift Ordenar.swift\n" + (1...9).map(String.init).joined(separator: "\n") + "\n```"
        let segments = ArtifactParser.segments(content)
        guard case .artifact(let artifact) = segments.first else {
            Issue.record("expected artifact")
            return
        }
        #expect(artifact.title == "Ordenar.swift")
    }

    @Test func reassemblingSegmentsReproducesTheOriginalContent() {
        let body = (1...10).map { "línea \($0)" }.joined(separator: "\n")
        let content = "intro\n\n```html\n\(body)\n```\n\ncierre"
        let segments = ArtifactParser.segments(content)
        let rebuilt = segments.map { segment -> String in
            switch segment {
            case .text(_, let text): return text
            case .artifact(let artifact): return "```\(artifact.language)\n\(artifact.content)\n```"
            }
        }.joined(separator: "\n")
        #expect(rebuilt == content)
    }
}

// Serialized: every test in this suite reads and writes the same
// `UserDefaults` key, and Swift Testing otherwise runs them concurrently.
@Suite(.serialized)
struct SkillStoreTests {
    private func withCleanStore(_ body: () -> Void) {
        let saved = SkillStore.all
        SkillStore.all = []
        defer { SkillStore.all = saved }
        body()
    }

    @Test func toolNameIsSanitizedAndPrefixed() {
        let skill = Skill(name: "Revisión de código!", summary: "", instructions: "")
        #expect(skill.toolName == "skill_revisión_de_código_")
    }

    @Test func instructionsOnlyRouteAutomaticSkills() {
        withCleanStore {
            let automatic = Skill(name: "Auto", summary: "s", instructions: "haz A", mode: .automatic)
            let always = Skill(name: "Always", summary: "s", instructions: "haz B", mode: .always)
            SkillStore.all = [automatic, always]

            #expect(SkillStore.instructions(forTool: automatic.toolName) == "haz A")
            #expect(SkillStore.instructions(forTool: always.toolName) == nil)
        }
    }

    @Test func alwaysOnAndToolSpecsPartitionByMode() {
        withCleanStore {
            let automatic = Skill(name: "Auto", summary: "s", instructions: "haz A", mode: .automatic)
            let always = Skill(name: "Always", summary: "s", instructions: "haz B", mode: .always)
            let off = Skill(name: "Off", summary: "s", instructions: "haz C", mode: .off)
            SkillStore.all = [automatic, always, off]

            #expect(SkillStore.alwaysOnInstructions() == "haz B")
            #expect(SkillStore.toolSpecs().count == 1)
        }
    }

    @Test func parsesFrontmatterFromASkillMarkdownFile() {
        let text = """
        ---
        name: Revisión
        description: Revisa código en busca de bugs
        ---
        Instrucciones aquí.
        """
        let skill = SkillStore.parse(skillMarkdown: text, fallbackName: "fallback")
        #expect(skill.name == "Revisión")
        #expect(skill.summary == "Revisa código en busca de bugs")
        #expect(skill.instructions == "Instrucciones aquí.")
    }

    @Test func fallsBackToPlainTextWithoutFrontmatter() {
        let skill = SkillStore.parse(skillMarkdown: "solo instrucciones", fallbackName: "Mi skill")
        #expect(skill.name == "Mi skill")
        #expect(skill.instructions == "solo instrucciones")
    }
}

// Serialized: same reason as `SkillStoreTests` — shared `UserDefaults` state.
@Suite(.serialized)
struct PersonalizationTests {
    @Test func emptyProfileAndNormalStyleProduceAnEmptyPreamble() {
        let saved = (Personalization.name, Personalization.context, Personalization.preferences)
        Personalization.name = ""
        Personalization.context = ""
        Personalization.preferences = ""
        defer {
            Personalization.name = saved.0
            Personalization.context = saved.1
            Personalization.preferences = saved.2
        }
        #expect(Personalization.preamble(style: .normal).isEmpty)
    }

    @Test func filledProfileProducesLines() {
        let saved = (Personalization.name, Personalization.context, Personalization.preferences)
        Personalization.name = "Ada"
        Personalization.context = ""
        Personalization.preferences = ""
        defer {
            Personalization.name = saved.0
            Personalization.context = saved.1
            Personalization.preferences = saved.2
        }
        #expect(Personalization.preamble(style: .conciso) == "El usuario se llama Ada.\nResponde de forma breve y directa, sin rodeos.")
    }
}

struct ToolCallRecordTests {
    @Test func statusRoundTripsThroughJSON() throws {
        let calls = [
            ToolCallRecord(id: UUID(), name: "tavily_search", isSkill: false, status: .running),
            ToolCallRecord(id: UUID(), name: "Revisión de código", isSkill: true, status: .succeeded(preview: "ok")),
            ToolCallRecord(id: UUID(), name: "tavily_search", isSkill: false, status: .failed("timeout")),
        ]
        let data = try JSONEncoder().encode(calls)
        let decoded = try JSONDecoder().decode([ToolCallRecord].self, from: data)
        #expect(decoded == calls)
    }

    @Test func chatMessageDefaultsToNoToolCalls() {
        let message = ChatMessage(role: .assistant, content: "")
        #expect(message.toolCalls.isEmpty)
    }

    @Test func chatMessageToolCallsRoundTripThroughTheStoredRawString() {
        let message = ChatMessage(role: .assistant, content: "")
        let id = UUID()
        message.toolCalls = [ToolCallRecord(id: id, name: "search_web", isSkill: false, status: .running)]
        #expect(message.toolCalls == [ToolCallRecord(id: id, name: "search_web", isSkill: false, status: .running)])

        message.toolCalls[0].status = .succeeded(preview: "3 resultados")
        #expect(message.toolCalls[0].status == .succeeded(preview: "3 resultados"))
    }
}

struct ProjectContextTests {
    @Test func isEmptyWithNoInstructionsAndNoDocuments() {
        let project = Project(name: "Sin nada")
        #expect(project.contextBlock.isEmpty)
    }

    @Test func carriesJustInstructionsWithNoTrailingSeparator() {
        let project = Project(name: "Solo instrucciones", instructions: "Responde en verso.")
        #expect(project.contextBlock == "Responde en verso.")
    }

    @Test func headersEachDocumentWithItsFileName() {
        let project = Project(name: "Con documentos")
        project.documents = [
            ProjectDocument(fileName: "apuntes.md", text: "notas", wasTruncated: false)
        ]
        #expect(project.contextBlock.contains("Documento del proyecto: apuntes.md"))
        #expect(project.contextBlock.contains("notas"))
    }

    /// The regression that matters: a project whose knowledge blows past
    /// the character budget must still fit inside it, with a visible notice
    /// instead of silently growing every prompt without bound.
    @Test func truncatesAtTheKnowledgeLimitWithANotice() {
        let project = Project(name: "Enorme")
        project.documents = [
            ProjectDocument(fileName: "grande.txt", text: String(repeating: "x", count: Project.knowledgeCharacterLimit + 500), wasTruncated: false)
        ]
        #expect(project.contextBlock.count <= Project.knowledgeCharacterLimit + 100)
        #expect(project.contextBlock.contains("se truncó por longitud"))
    }

    @Test func conversationPrependsItsProjectsContextBlock() {
        let project = Project(name: "Proyecto", instructions: "Usa tono formal.")
        let conversation = Conversation(modelID: "mlx-community/test", systemPrompt: "Sé breve.")
        conversation.project = project
        #expect(conversation.effectiveSystemPrompt == "Usa tono formal.\n\nSé breve.")
    }

    @Test func conversationWithoutAProjectKeepsJustItsOwnPrompt() {
        let conversation = Conversation(modelID: "mlx-community/test", systemPrompt: "Sé breve.")
        #expect(conversation.effectiveSystemPrompt == "Sé breve.")
    }
}

/// Pure composition logic only — `ModelPreflight.check` itself needs the
/// network, so it isn't covered here.
struct PreflightResultTests {
    @Test func noWarningsWhenEverythingChecksOut() {
        var result = PreflightResult()
        result.hasConfig = true
        result.hasWeights = true
        result.hasTokenizer = true
        result.supportsTools = true
        result.supportsReasoning = true
        #expect(result.softWarnings.isEmpty)
    }

    @Test func unknownCapabilityIsNotAWarning() {
        // A failed probe fetch (nil) must not read as "confirmed unsupported".
        var result = PreflightResult()
        result.hasConfig = true
        result.hasWeights = true
        result.hasTokenizer = true
        #expect(result.softWarnings.isEmpty)
    }

    @Test func flagsEachConfirmedGapSeparately() {
        var result = PreflightResult()
        result.hasConfig = true
        result.hasWeights = true
        result.hasTokenizer = true
        result.fitsRecommendedMemory = false
        result.supportsTools = false
        result.supportsReasoning = false
        #expect(result.softWarnings.count == 3)
    }
}
