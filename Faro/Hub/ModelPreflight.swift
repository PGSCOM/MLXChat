import Foundation
import HuggingFace
import MLX
import MLXLMCommon

/// Checked before downloading: a Hugging Face repo can hold valid-looking
/// files and still not be an MLX model, and even a real one can be too
/// big for this device. Better to say so than to pull several GB first.
struct PreflightResult: Sendable {
    var hasConfig = false
    var hasWeights = false
    var hasTokenizer = false
    var totalBytes = 0
    var fitsRecommendedMemory = true
    /// `nil` when it couldn't be determined (the tiny probe fetch below
    /// failed, or the repo just doesn't publish the file it needs) — a
    /// network hiccup on a few KB shouldn't produce a false warning about
    /// several GB of weights nobody's downloaded yet.
    var supportsTools: Bool?
    var supportsReasoning: Bool?

    var isCompatible: Bool { hasConfig && hasWeights && hasTokenizer }

    var summary: String {
        if !hasConfig { return "No se encontró config.json: no parece un modelo MLX." }
        if !hasWeights { return "No hay pesos .safetensors en este repositorio." }
        if !hasTokenizer { return "Falta el tokenizer del modelo." }
        return "Compatible."
    }

    /// Doesn't block the download — same spirit as the memory-fit check
    /// used to be: a heads-up, not a hard stop, since none of these are
    /// certain (a small probe file, not the model actually running).
    var softWarnings: [String] {
        var messages: [String] = []
        if !fitsRecommendedMemory { messages.append("puede no caber en la memoria recomendada de este dispositivo") }
        if supportsTools == false { messages.append("no parece admitir llamadas a herramientas") }
        if supportsReasoning == false { messages.append("no parece admitir razonamiento") }
        return messages
    }
}

enum ModelPreflight {
    enum PreflightError: LocalizedError {
        case invalidRepoID
        var errorDescription: String? { "ID de repositorio no válido." }
    }

    static func check(repoID: String) async throws -> PreflightResult {
        guard let id = Repo.ID(rawValue: repoID) else {
            throw PreflightError.invalidRepoID
        }

        let entries = try await HubClient.default.modelTree(id)
        var result = PreflightResult()
        var hasChatTemplateFile = false
        var hasTokenizerConfigFile = false

        for entry in entries where entry.type == .file {
            switch entry.path {
            case "config.json":
                result.hasConfig = true
            case "tokenizer.json", "tokenizer_config.json":
                result.hasTokenizer = true
                if entry.path == "tokenizer_config.json" { hasTokenizerConfigFile = true }
            case "chat_template.jinja":
                hasChatTemplateFile = true
            default:
                if entry.path.hasSuffix(".safetensors") {
                    result.hasWeights = true
                    result.totalBytes += entry.size ?? 0
                }
            }
        }

        if let recommended = GPU.maxRecommendedWorkingSetBytes(), recommended > 0 {
            result.fitsRecommendedMemory = result.totalBytes < recommended
        }

        // Only worth probing a repo that's already confirmed to look like a
        // real MLX model — no point spending two more small fetches on one
        // that's about to fail preflight anyway.
        if result.isCompatible {
            async let tools = supportsTools(id)
            async let reasoning = supportsReasoning(
                id, hasChatTemplateFile: hasChatTemplateFile, hasTokenizerConfigFile: hasTokenizerConfigFile)
            (result.supportsTools, result.supportsReasoning) = await (tools, reasoning)
        }
        return result
    }

    /// `ToolCallFormat.infer` (mlx-swift-lm) maps a repo's real
    /// `model_type` to a recognized tool-calling dialect — the exact same
    /// resolution `LLMModelFactory` runs at load time, just run early on a
    /// few KB of `config.json` instead of after the weights are already on
    /// disk. Never a name guessed on Faro's side.
    private static func supportsTools(_ id: Repo.ID) async -> Bool? {
        guard let data = try? await HubClient.default.resolveModelFile(id, path: "config.json"),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let modelType = json["model_type"] as? String
        else { return nil }
        return ToolCallFormat.infer(from: modelType, configData: data) != nil
    }

    /// Whether the model's own chat template ever mentions `<think>` —
    /// mirrors `InferenceEngine.ModelCapabilities.supportsReasoning`, just
    /// read straight from the template source instead of rendering it
    /// (there's no loaded tokenizer to render with yet, before a download).
    private static func supportsReasoning(
        _ id: Repo.ID, hasChatTemplateFile: Bool, hasTokenizerConfigFile: Bool
    ) async -> Bool? {
        if hasChatTemplateFile {
            guard let data = try? await HubClient.default.resolveModelFile(id, path: "chat_template.jinja"),
                let template = String(data: data, encoding: .utf8)
            else { return nil }
            return template.contains("<think>")
        }
        guard hasTokenizerConfigFile,
            let data = try? await HubClient.default.resolveModelFile(id, path: "tokenizer_config.json"),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let template = json["chat_template"] as? String
        else { return nil }
        return template.contains("<think>")
    }
}
