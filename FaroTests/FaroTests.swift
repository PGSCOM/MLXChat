import Foundation
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
