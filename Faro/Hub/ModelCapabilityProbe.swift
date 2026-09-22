import Foundation
import HuggingFace

/// Decides whether a model supports reasoning or tool-calling by reading its
/// own chat template — never by comparing the repo id against a name. Two
/// entry points share the same decision logic: `remote` (a few KB fetched
/// before the multi-GB weight download starts) and `onDisk` (the same files
/// already sitting in `HubCache` for a model that's downloaded).
enum ModelCapabilityProbe {
    struct Capabilities: Sendable, Equatable {
        /// `nil` when it couldn't be determined (template unreadable) — a
        /// probe hiccup on a few KB shouldn't read as a confirmed gap.
        var supportsTools: Bool?
        var supportsReasoning: Bool?

        /// Same wording `ModelDownloadCoordinator` already shows for the
        /// memory-fit warning — one voice for every soft warning, wherever
        /// it's surfaced (pre-download, or a row for a model already on disk).
        var warnings: [String] {
            var messages: [String] = []
            if supportsTools == false { messages.append("no parece admitir llamadas a herramientas") }
            if supportsReasoning == false { messages.append("no parece admitir razonamiento") }
            return messages
        }
    }

    /// The Apple Foundation model isn't a Hugging Face repo — it's an id
    /// Faro itself reserves (`AppleFoundationModel.id`), not a community
    /// name being guessed at, and neither capability is wired up for it.
    static let appleFoundation = Capabilities(supportsTools: false, supportsReasoning: false)

    /// A `{{ ... }}` output whose entire content is one string literal: the
    /// template is *emitting* that literal text verbatim, not recomputing it
    /// from a variable. Chat templates that rewrite `<think>` back out of an
    /// assistant turn in the history always do it by concatenation
    /// (`'<|im_start|>' + message.role + '\n<think>\n' + reasoning_content + ...`),
    /// which never matches this — extra content (the `+ message.role + ...`)
    /// sits between the literal and the closing `}}`. Only a template that
    /// actually opens a reasoning block for the model to write into matches.
    private static let literalOutput = try! NSRegularExpression(
        pattern: #"\{\{-?\s*(?:'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*")\s*-?\}\}"#
    )

    /// True when the template emits `<think>` as a literal (see above), or
    /// declares `enable_thinking` (the standard Hugging Face variable for
    /// hybrid templates, which inject nothing extra once thinking is left
    /// on — the render-and-check the app used to do would call those "no").
    ///
    /// Verified against 18 real `mlx-community` chat templates. A plain
    /// `contains("<think>")` on the template source gets three of them
    /// backwards: a false positive on Qwen3-Instruct-2507 (the tag only
    /// ever appears inside the history-rewrite concatenation above) and a
    /// false negative on the Qwen3-1.7B/8B hybrid template when rendered
    /// with thinking on (nothing gets injected into that render at all).
    static func supportsReasoning(chatTemplate: String) -> Bool {
        if chatTemplate.contains("enable_thinking") { return true }
        let range = NSRange(chatTemplate.startIndex..., in: chatTemplate)
        return literalOutput.matches(in: chatTemplate, range: range).contains { match in
            guard let matchRange = Range(match.range, in: chatTemplate) else { return false }
            return chatTemplate[matchRange].contains("<think>")
        }
    }

    /// True when the template reads a `tools` variable — the model was
    /// trained to call them, whatever dialect it emits them in.
    ///
    /// Deliberately NOT `ToolCallFormat.infer(from:) != nil`
    /// (mlx-swift-lm): that function's own doc comment on
    /// `ModelConfiguration.toolCallFormat` says "nil = default JSON
    /// format" — `nil` means "this model uses the common
    /// `<tool_call>{...}</tool_call>` dialect", not "no tool support".
    /// `infer` only returns non-nil for the handful of architectures that
    /// use a *different* dialect (LFM2, GLM4, Gemma, Llama, Mistral,
    /// Qwen3.5...); reading it as "supports tools" reports Qwen, Phi and
    /// SmolLM3 — which all use the default dialect — as unsupported.
    static func supportsTools(chatTemplate: String) -> Bool {
        chatTemplate.range(of: #"\btools\b"#, options: .regularExpression) != nil
    }

    /// Downloads just the chat template — not the model — used before the
    /// weight download starts (`ModelPreflight`).
    static func remote(repoID: Repo.ID) async -> Capabilities? {
        guard let template = await remoteTemplate(repoID) else { return nil }
        return Capabilities(
            supportsTools: supportsTools(chatTemplate: template),
            supportsReasoning: supportsReasoning(chatTemplate: template)
        )
    }

    private static func remoteTemplate(_ id: Repo.ID) async -> String? {
        if let data = try? await HubClient.default.resolveModelFile(id, path: "chat_template.jinja"),
            let text = String(data: data, encoding: .utf8)
        {
            return text
        }
        guard let data = try? await HubClient.default.resolveModelFile(id, path: "tokenizer_config.json")
        else { return nil }
        return chatTemplate(fromTokenizerConfigData: data)
    }

    /// Reads the chat template straight from `HubCache` — no network, no
    /// loaded tokenizer. `nil` for a model not actually on disk.
    ///
    /// ponytail: re-reads the file (up to ~1MB for a `tokenizer_config.json`
    /// with no separate `.jinja`) on every call rather than caching — every
    /// caller already only calls this from a throttled point (a browser
    /// refresh, a model switch), never from a view's `body`. Add a cache if
    /// that stops being true; a shared mutable one would need actor
    /// isolation to stay Swift 6 concurrency-safe, which isn't worth it yet.
    static func onDisk(modelID: String) -> Capabilities? {
        guard !AppleFoundationModel.isAppleFoundation(modelID) else { return appleFoundation }
        guard let template = onDiskTemplate(modelID: modelID) else { return nil }
        return Capabilities(
            supportsTools: supportsTools(chatTemplate: template),
            supportsReasoning: supportsReasoning(chatTemplate: template)
        )
    }

    private static func onDiskTemplate(modelID: String) -> String? {
        guard let id = Repo.ID(rawValue: modelID) else { return nil }
        let cache = HubCache.default
        if let url = cache.cachedFilePath(
            repo: id, kind: .model, revision: "main", filename: "chat_template.jinja"),
            let data = try? Data(contentsOf: url),
            let text = String(data: data, encoding: .utf8)
        {
            return text
        }
        guard
            let url = cache.cachedFilePath(
                repo: id, kind: .model, revision: "main", filename: "tokenizer_config.json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return chatTemplate(fromTokenizerConfigData: data)
    }

    /// `chat_template` in `tokenizer_config.json` can be a plain string, or
    /// (Hugging Face's multi-template format) a list of `{name, template}`
    /// objects — join every variant so a reader that only handled the plain
    /// string doesn't silently miss a repo that only ships named variants.
    static func chatTemplate(fromTokenizerConfigData data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let raw = json["chat_template"]
        else { return nil }
        if let text = raw as? String { return text }
        if let list = raw as? [[String: Any]] {
            let joined = list.compactMap { $0["template"] as? String }.joined(separator: "\n")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }
}
