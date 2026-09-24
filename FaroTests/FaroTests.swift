import Foundation
import SwiftData
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

    /// Text written right before a tool call ("Voy a llamar a una
    /// herramienta.") must survive as content even when the *next* block
    /// reopens implicitly — `TurnRecorder.toolStarted` calls this exactly at
    /// the call boundary so the next implicit close doesn't sweep it up.
    @Test func commitContentPreventsThePreCallTextFromBeingReclaimed() {
        var splitter = ThinkTagSplitter()
        _ = splitter.consume("razono</think>Voy a llamar a una herramienta.")
        splitter.commitContent()
        let delta = splitter.consume("nueva razón</think>final")
        #expect(!delta.contentWasReasoning)
        #expect(delta.reasoning == "nueva razón")
        #expect(delta.content == "final")
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

    /// Gemma 4 marks the same span with its own channel delimiters, split
    /// across chunks the way real streaming does it — normalized to
    /// `<think>`/`</think>` before the rest of the splitter ever sees them.
    @Test func normalizesGemma4sChannelDelimitersSplitAcrossChunks() {
        let result = run(["<|chan", "nel>thought\nplan<chan", "nel|>respuesta"])
        #expect(result.reasoning == "\nplan")
        #expect(result.content == "respuesta")
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

/// Pure tree operations over a conversation's flat message array — no
/// SwiftData context needed, since these only read `parentID`/`createdAt`.
struct MessageTreeTests {
    private func message(_ role: MessageRole, parent: ChatMessage? = nil, offset: TimeInterval) -> ChatMessage {
        let message = ChatMessage(role: role, content: "", parentID: parent?.id)
        message.createdAt = Date(timeIntervalSince1970: offset)
        return message
    }

    @Test func pathFollowsParentLinksUpToTheRoot() {
        let root = message(.user, offset: 0)
        let reply = message(.assistant, parent: root, offset: 1)
        let followUp = message(.user, parent: reply, offset: 2)
        let all = [followUp, root, reply]

        #expect(MessageTree.path(to: followUp.id, in: all).map(\.id) == [root.id, reply.id, followUp.id])
    }

    @Test func siblingsComeOutOldestFirst() {
        let root = message(.user, offset: 0)
        let second = message(.assistant, parent: root, offset: 2)
        let first = message(.assistant, parent: root, offset: 1)
        let all = [root, second, first]

        #expect(MessageTree.siblings(of: second, in: all).map(\.id) == [first.id, second.id])
    }

    @Test func aMessageWithNoSiblingsReturnsJustItself() {
        let root = message(.user, offset: 0)
        #expect(MessageTree.siblings(of: root, in: [root]).map(\.id) == [root.id])
    }

    @Test func latestLeafDescendsThroughTheNewestChildAtEachStep() {
        let root = message(.user, offset: 0)
        let oldReply = message(.assistant, parent: root, offset: 1)
        let newReply = message(.assistant, parent: root, offset: 2)
        let grandchild = message(.user, parent: newReply, offset: 3)
        let all = [root, oldReply, newReply, grandchild]

        #expect(MessageTree.latestLeaf(from: root, in: all).id == grandchild.id)
    }

    @Test func threadLegacyChainsAFlatListByCreationOrder() {
        let first = message(.user, offset: 0)
        let second = message(.assistant, offset: 1)
        let third = message(.user, offset: 2)
        let all = [third, first, second]

        MessageTree.threadLegacy(all)

        #expect(first.parentID == nil)
        #expect(second.parentID == first.id)
        #expect(third.parentID == second.id)
    }

    @Test func threadLegacyLeavesAnAlreadyLinkedMessagesParentAlone() {
        // `reply` already has a real parent; threading only ever links
        // messages that are still roots (`parentID == nil`), so it's
        // never touched even though it sits between two of them by time.
        let root = message(.user, offset: 0)
        let reply = message(.assistant, parent: root, offset: 1)
        let laterRoot = message(.user, offset: 2)
        let all = [root, reply, laterRoot]

        MessageTree.threadLegacy(all)

        #expect(reply.parentID == root.id)
        #expect(laterRoot.parentID == root.id)
    }

    @Test func promptTextReproducesTheOldInlineFormatWhenThereIsAnAttachment() {
        let message = ChatMessage(
            role: .user, content: "Resúmelo",
            attachmentName: "notas.txt", attachmentText: "contenido del archivo"
        )
        #expect(message.promptText == "Archivo adjunto: notas.txt\n\ncontenido del archivo\n\n---\n\nResúmelo")
    }

    @Test func promptTextIsJustTheContentWithNoAttachment() {
        let message = ChatMessage(role: .user, content: "Hola")
        #expect(message.promptText == "Hola")
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

struct CuratedModelFamilyTests {
    @Test func familiesContainEveryModelExactlyOnce() {
        let flattened = CuratedModel.families.flatMap(\.models)
        #expect(flattened.map(\.id) == CuratedModel.all.map(\.id))
        #expect(Set(flattened.map(\.id)).count == flattened.count)
        #expect(CuratedModel.families.allSatisfy { !$0.models.isEmpty })
        #expect(DefaultModel.repoID == CuratedModel.families[0].models[0].id)
    }

    @Test func qwenFamilyContainsAllOfferedSizes() {
        let qwen = CuratedModel.families.first { $0.id == "qwen3.5" }
        #expect(qwen?.models.map(\.id) == [
            "mlx-community/Qwen3.5-2B-4bit",
            "mlx-community/Qwen3.5-4B-4bit",
            "mlx-community/Qwen3.5-9B-4bit",
            "mlx-community/Qwen3.5-0.8B-4bit",
        ])
        #expect(CuratedModel.families.map(\.id) == ["qwen3.5", "gemma4", "lfm2.5"])
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

    @Test func chatMessageDefaultsToNoSteps() {
        let message = ChatMessage(role: .assistant, content: "")
        #expect(message.steps.isEmpty)
    }

    @Test func chatMessageStepsRoundTripThroughTheStoredRawString() {
        let message = ChatMessage(role: .assistant, content: "")
        let id = UUID()
        let record = ToolCallRecord(id: id, name: "search_web", isSkill: false, status: .running)
        message.steps = [TurnStep(id: id, kind: .tool(record), contentOffset: 0)]
        guard case .tool(let stored) = message.steps[0].kind else {
            Issue.record("esperaba un paso de herramienta")
            return
        }
        #expect(stored == record)

        var steps = message.steps
        guard case .tool(var updated) = steps[0].kind else {
            Issue.record("esperaba un paso de herramienta")
            return
        }
        updated.status = .succeeded(preview: "3 resultados")
        steps[0].kind = .tool(updated)
        message.steps = steps
        guard case .tool(let final) = message.steps[0].kind else {
            Issue.record("esperaba un paso de herramienta")
            return
        }
        #expect(final.status == .succeeded(preview: "3 resultados"))
    }

    @Test func argumentsSummaryJoinsKeysAlphabetically() {
        let record = ToolCallRecord(
            id: UUID(), name: "tavily_search", isSkill: false, status: .running,
            arguments: #"{"query":"bitcoin","max_results":5}"#
        )
        #expect(record.argumentsSummary == "max_results: 5 · query: bitcoin")
    }

    @Test func argumentsSummaryIsNilWithoutArguments() {
        let record = ToolCallRecord(id: UUID(), name: "tavily_search", isSkill: false, status: .running)
        #expect(record.argumentsSummary == nil)
    }

    @Test func legacyMessageWithOnlyReasoningSynthesizesOneStep() {
        // Messages saved before steps existed (any conversation from
        // `master`) have `reasoning` but no `stepsRaw` — they must still
        // render their reasoning card instead of losing it.
        let message = ChatMessage(role: .assistant, content: "Respuesta", reasoning: "pensé esto")
        message.reasoningSeconds = 4.5
        #expect(message.steps.count == 1)
        guard case .reasoning(let start, let end) = message.steps[0].kind else {
            Issue.record("esperaba un paso de razonamiento")
            return
        }
        #expect(start == 0)
        #expect(end == "pensé esto".count)
        #expect(message.steps[0].seconds == 4.5)
    }
}

/// `TurnRecorder` is where a raw stream turns into `message.content` /
/// `message.reasoning` plus the ordered steps the UI replays — these check
/// the ordering directly through `TurnStep.timeline`, the same read the
/// chat bubble does.
struct TurnRecorderTests {
    @Test @MainActor func recordsReasoningToolReasoningAnswerInOrder() {
        let message = ChatMessage(role: .assistant, content: "")
        let recorder = TurnRecorder(message: message)
        _ = recorder.consume("<think>plan</think>")
        let call = ToolCallRecord(id: UUID(), name: "tavily_search", isSkill: false, status: .running)
        recorder.toolStarted(call)
        recorder.toolFinished(id: call.id, status: .succeeded(preview: "3 resultados"))
        _ = recorder.consume("<think>otra</think>Respuesta")
        recorder.finish()

        #expect(message.content == "Respuesta")
        let timeline = TurnStep.timeline(content: message.content, reasoning: message.reasoning ?? "", steps: message.steps)
        #expect(timeline.count == 4)
        guard case .step(_, let firstReasoning) = timeline[0] else {
            Issue.record("esperaba razonamiento")
            return
        }
        #expect(firstReasoning == "plan")
        guard case .step(let toolStep, _) = timeline[1], case .tool(let record) = toolStep.kind else {
            Issue.record("esperaba una herramienta")
            return
        }
        #expect(record.status == .succeeded(preview: "3 resultados"))
        guard case .step(_, let secondReasoning) = timeline[2] else {
            Issue.record("esperaba razonamiento")
            return
        }
        #expect(secondReasoning == "otra")
        guard case .text(let text) = timeline[3] else {
            Issue.record("esperaba texto")
            return
        }
        #expect(text == "Respuesta")
    }

    /// `toolStarted` draws an explicit segment boundary so text written
    /// right before the call ("Voy a buscar.") survives as content instead
    /// of being swept up when the post-tool reasoning reopens implicitly.
    @Test @MainActor func toolStartCommitsPendingContentBeforeTheNextImplicitBlock() {
        let message = ChatMessage(role: .assistant, content: "")
        let recorder = TurnRecorder(message: message)
        _ = recorder.consume("Voy a buscar.")
        let call = ToolCallRecord(id: UUID(), name: "tavily_search", isSkill: false, status: .running)
        recorder.toolStarted(call)
        recorder.toolFinished(id: call.id, status: .succeeded(preview: "ok"))
        _ = recorder.consume("pienso</think>Listo")
        recorder.finish()

        #expect(message.content == "Voy a buscar.Listo")
        let timeline = TurnStep.timeline(content: message.content, reasoning: message.reasoning ?? "", steps: message.steps)
        #expect(timeline.count == 4)
        guard case .text(let first) = timeline[0] else {
            Issue.record("esperaba texto")
            return
        }
        #expect(first == "Voy a buscar.")
        guard case .step(let toolStep, _) = timeline[1], case .tool = toolStep.kind else {
            Issue.record("esperaba una herramienta")
            return
        }
        guard case .step(_, let reasoning) = timeline[2] else {
            Issue.record("esperaba razonamiento")
            return
        }
        #expect(reasoning == "pienso")
        guard case .text(let last) = timeline[3] else {
            Issue.record("esperaba texto")
            return
        }
        #expect(last == "Listo")
    }

    /// A cancellation can land between a tool call starting and its own
    /// `.finished` event arriving — `finish()` is the safety net that keeps
    /// the card from spinning forever.
    @Test @MainActor func finishFailsAToolCallStillRunning() {
        let message = ChatMessage(role: .assistant, content: "")
        let recorder = TurnRecorder(message: message)
        let call = ToolCallRecord(id: UUID(), name: "tavily_search", isSkill: false, status: .running)
        recorder.toolStarted(call)
        recorder.finish()

        guard case .tool(let record) = message.steps[0].kind else {
            Issue.record("esperaba una herramienta")
            return
        }
        #expect(record.status == .failed("Cancelada"))
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
        result.capabilities = .init(supportsTools: true, supportsReasoning: true)
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
        result.capabilities = .init(supportsTools: false, supportsReasoning: false)
        #expect(result.softWarnings.count == 3)
    }
}

/// Fragments taken verbatim from real `mlx-community` chat templates —
/// the exact three cases a naive `contains("<think>")` gets backwards (see
/// the `ponytail:`-adjacent doc comments on `ModelCapabilityProbe`).
struct ModelCapabilityProbeTests {
    @Test func rejectsThinkInsideAHistoryRewriteConcatenation() {
        // Qwen3-4B-Instruct-2507: doesn't reason, but its template mentions
        // `<think>` only while stripping it back out of a prior turn.
        let template = #"""
            {%- if '</think>' in content %}
                {%- set reasoning_content = content.split('</think>')[0].rstrip('\n').split('<think>')[-1].lstrip('\n') %}
                {%- set content = content.split('</think>')[-1].lstrip('\n') %}
            {%- endif %}
            {{- '<|im_start|>' + message.role + '\n<think>\n' + reasoning_content.strip('\n') + '\n</think>\n\n' + content.lstrip('\n') }}
            """#
        #expect(ModelCapabilityProbe.supportsReasoning(chatTemplate: template) == false)
    }

    @Test func acceptsThinkEmittedAsALiteral() {
        // Qwen3-4B-Thinking-2507: the generation prompt opens `<think>` for
        // the model to write into.
        let template = #"{%- if add_generation_prompt %}{{- '<|im_start|>assistant\n<think>\n' }}{%- endif %}"#
        #expect(ModelCapabilityProbe.supportsReasoning(chatTemplate: template) == true)
    }

    @Test func acceptsEnableThinkingEvenWhenTheRenderInjectsNothing() {
        // Qwen3-1.7B/8B: with thinking left on (the default), the hybrid
        // template's rendered *prompt* injects nothing extra — a render-and-
        // check misses this the same way `contains("<think>")` on the raw
        // source does with thinking explicitly off.
        let template = #"""
            {%- if enable_thinking is defined and enable_thinking is false %}
                {{- '<think>\n\n</think>\n\n' }}
            {%- endif %}
            """#
        #expect(ModelCapabilityProbe.supportsReasoning(chatTemplate: template) == true)
    }

    @Test func neitherToolsNorThinkOnAPlainTemplate() {
        // Gemma 3: no `tools`, no `<think>`, anywhere.
        let template = "{%- for message in messages %}{{- message.content }}{%- endfor %}"
        #expect(ModelCapabilityProbe.supportsTools(chatTemplate: template) == false)
        #expect(ModelCapabilityProbe.supportsReasoning(chatTemplate: template) == false)
    }

    @Test func toolsWithoutReasoning() {
        // Llama 3.2: calls tools, never reasons.
        let template = "{%- if tools %}{{- 'Tools available' }}{%- endif %}"
        #expect(ModelCapabilityProbe.supportsTools(chatTemplate: template) == true)
        #expect(ModelCapabilityProbe.supportsReasoning(chatTemplate: template) == false)
    }

    @Test func toolsOnlyMentionedInPrintedTextDontCount() {
        // SmolLM3: prints `<tools>` but reads its list from `xml_tools`, so
        // a `tools` list handed to it never reaches the model.
        let template = #"{%- if xml_tools %}{{- 'function signatures within <tools></tools> XML tags' }}{%- endif %}"#
        #expect(ModelCapabilityProbe.supportsTools(chatTemplate: template) == false)
    }

    @Test func chatTemplateReadsThePlainStringForm() {
        let data = #"{"chat_template": "{{ messages }}"}"#.data(using: .utf8)!
        #expect(ModelCapabilityProbe.chatTemplate(fromTokenizerConfigData: data) == "{{ messages }}")
    }

    @Test func chatTemplateJoinsTheMultiTemplateListForm() {
        // Hugging Face's multi-template format: a list of named variants
        // instead of one plain string.
        let data = #"{"chat_template": [{"name": "default", "template": "{{ a }}"}, {"name": "tool_use", "template": "{{ b }}"}]}"#
            .data(using: .utf8)!
        let result = ModelCapabilityProbe.chatTemplate(fromTokenizerConfigData: data)
        #expect(result?.contains("{{ a }}") == true)
        #expect(result?.contains("{{ b }}") == true)
    }
}

/// The regression from issue #5: `AttributedString(markdown:)` parses
/// headings and paragraphs into `presentationIntent`, but rendering the
/// whole document in one `Text` drops that structure — a heading and the
/// paragraph after it collapsed into one run-on block with no separator.
struct MarkdownBlockTests {
    private func kinds(_ blocks: [MarkdownBlock]) -> [MarkdownBlock.Kind] {
        blocks.map(\.kind)
    }

    private func strings(_ blocks: [MarkdownBlock]) -> [String] {
        blocks.map { String($0.text.characters) }
    }

    @Test func splitsAHeadingFromTheParagraphAfterIt() {
        let blocks = MarkdownBlock.blocks(of: "# Título\n\nHola")
        #expect(kinds(blocks) == [.heading(level: 1), .paragraph])
        #expect(strings(blocks) == ["Título", "Hola"])
    }

    @Test func keepsConsecutiveParagraphsSeparate() {
        let blocks = MarkdownBlock.blocks(of: "Uno\n\nDos")
        #expect(kinds(blocks) == [.paragraph, .paragraph])
        #expect(strings(blocks) == ["Uno", "Dos"])
    }

    @Test func marksOrderedAndUnorderedListItems() {
        let ordered = MarkdownBlock.blocks(of: "1. Primero\n2. Segundo")
        #expect(kinds(ordered) == [.listItem(marker: "1.", depth: 1), .listItem(marker: "2.", depth: 1)])

        let unordered = MarkdownBlock.blocks(of: "- Uno\n- Dos")
        #expect(kinds(unordered) == [.listItem(marker: "•", depth: 1), .listItem(marker: "•", depth: 1)])
    }

    @Test func marksAFencedCodeBlock() {
        let blocks = MarkdownBlock.blocks(of: "```\nlet x = 1\n```")
        #expect(kinds(blocks) == [.code(language: nil)])
        #expect(strings(blocks) == ["let x = 1"])
    }

    @Test func capturesTheFencesLanguageHint() {
        let blocks = MarkdownBlock.blocks(of: "```swift\nlet x = 1\n```")
        #expect(kinds(blocks) == [.code(language: "swift")])
    }

    @Test func plainTextStaysOneUntouchedParagraph() {
        let blocks = MarkdownBlock.blocks(of: "sin formato")
        #expect(kinds(blocks) == [.paragraph])
        #expect(strings(blocks) == ["sin formato"])
    }

    @Test func rendersAFencedDisplayEquation() {
        let blocks = MarkdownBlock.blocks(of: "$$\nx^2\n$$")
        #expect(kinds(blocks) == [.equation("x^2")])
    }

    @Test func rendersASingleLineDoubleDollarEquation() {
        let blocks = MarkdownBlock.blocks(of: "$$ x^2 $$")
        #expect(kinds(blocks) == [.equation("x^2")])
    }

    @Test func rendersAWholeLineDollarEquationAsDisplay() {
        let blocks = MarkdownBlock.blocks(of: "$E = mc^2$")
        #expect(kinds(blocks) == [.equation("E = mc^2")])
    }

    @Test func aDollarSignInsideASentenceStaysLiteral() {
        let blocks = MarkdownBlock.blocks(of: "Cuesta $5 y también $10.")
        #expect(kinds(blocks) == [.paragraph])
    }

    private func plainText(_ cell: MarkdownBlock.TableCell) -> String? {
        if case .text(let attr) = cell { return String(attr.characters) }
        return nil
    }

    @Test func parsesAGfmTableWithAlignment() {
        let blocks = MarkdownBlock.blocks(of: "| A | B |\n| --- | ---: |\n| 1 | 2 |")
        #expect(blocks.count == 1)
        guard case .table(let header, let alignment, let rows) = blocks[0].kind else {
            Issue.record("se esperaba un bloque de tabla")
            return
        }
        #expect(header.map(plainText) == ["A", "B"])
        #expect(alignment == [.leading, .trailing])
        #expect(rows.map { row in row.map(plainText) } == [["1", "2"]])
    }

    @Test func rendersAWholeCellEquationInATable() {
        let blocks = MarkdownBlock.blocks(of: "| A | B |\n| --- | --- |\n| $x^2$ | normal |")
        guard case .table(_, _, let rows) = blocks[0].kind, let row = rows.first else {
            Issue.record("se esperaba una fila de tabla")
            return
        }
        #expect(row[0] == .equation("x^2"))
        #expect(plainText(row[1]) == "normal")
    }

    @Test func parsesARawLatexTabularEnvironment() {
        // The regression this covers: a model asked to write actual LaTeX
        // (not Markdown) reaches for \begin{tabular}, not | pipes — issue
        // reported as "funciona, pero en este caso no".
        let markdown = #"""
        \begin{tabular}{|c|c|}
        \hline
        Columna 1 & Columna 2 \\
        \hline
        Ecuación 1 & \( E = mc^2 \) \\
        \hline
        Ecuación 2 & \( F = ma \) \\
        \hline
        \end{tabular}
        """#
        let blocks = MarkdownBlock.blocks(of: markdown)
        guard case .table(let header, let alignment, let rows) = blocks[0].kind else {
            Issue.record("se esperaba un bloque de tabla")
            return
        }
        #expect(header.map(plainText) == ["Columna 1", "Columna 2"])
        #expect(alignment == [.center, .center])
        #expect(rows.count == 2)
        #expect(plainText(rows[0][0]) == "Ecuación 1")
        #expect(rows[0][1] == .equation("E = mc^2"))
        #expect(rows[1][1] == .equation("F = ma"))
    }

    @Test func doesNotTreatALatexTableInsideACodeFenceAsARealTable() {
        let markdown = "```latex\n\\begin{tabular}{|c|c|}\n\\hline\nA & B \\\\\n\\end{tabular}\n```"
        let blocks = MarkdownBlock.blocks(of: markdown)
        #expect(kinds(blocks) == [.code(language: "latex")])
    }

    @Test func doesNotTreatATableInsideACodeFenceAsARealTable() {
        let blocks = MarkdownBlock.blocks(of: "```\n| a | b |\n| - | - |\n```")
        #expect(kinds(blocks) == [.code(language: nil)])
    }
}

/// The regression that matters for a highlighter: it must recolor code,
/// never rewrite it — a broken HTML-entity decode or a dropped character
/// would silently corrupt what the copy button then puts on the pasteboard.
struct CodeHighlighterTests {
    @Test @MainActor func highlightingPreservesTheOriginalCodeText() {
        let code = "let x = 1 // a comment with <html> & \"quotes\""
        let result = CodeHighlighter.highlight(code, language: "swift")
        #expect(result.map { String($0.characters) } == code)
    }
}

/// "Restablecer Faro" has to leave the store truly empty — including a
/// message that lost its conversation, which the cascade alone would miss.
struct AppResetTests {
    @Test @MainActor func erasesEveryRecordFromTheStore() throws {
        let container = try ModelContainer(
            for: Conversation.self, ChatMessage.self, Project.self, MCPServerConfig.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = container.mainContext
        let project = Project(name: "Proyecto")
        let conversation = Conversation(modelID: "mlx-community/test")
        let message = ChatMessage(role: .user, content: "hola")
        context.insert(project)
        context.insert(conversation)
        context.insert(message)
        context.insert(ChatMessage(role: .assistant, content: "huérfano"))
        context.insert(MCPServerConfig(name: "Servidor", url: "https://example.com/mcp"))
        conversation.project = project
        conversation.messages.append(message)
        try context.save()

        try AppReset.eraseStore(in: context)

        #expect(try context.fetchCount(FetchDescriptor<Conversation>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<ChatMessage>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Project>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<MCPServerConfig>()) == 0)
    }
}

/// An MCP token is a credential for someone else's server: it belongs in
/// the Keychain, and one saved in the store before the move has to end up
/// there rather than be lost. If the Keychain refused it, the token would
/// stay in the store and the second expectation catches it.
struct MCPTokenTests {
    @Test func movesATokenSavedInTheStoreIntoTheKeychain() {
        let server = MCPServerConfig(name: "Servidor", url: "https://example.com/mcp")
        server.bearerToken = "de-antes"
        #expect(server.token == "de-antes")

        server.moveTokenToKeychain()
        #expect(server.bearerToken.isEmpty)
        #expect(server.token == "de-antes")

        server.token = ""
        #expect(server.token.isEmpty)
    }
}
