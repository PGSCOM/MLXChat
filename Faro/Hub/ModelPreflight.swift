import Foundation
import HuggingFace
import MLX

/// Checked before downloading: a Hugging Face repo can hold valid-looking
/// files and still not be an MLX model, and even a real one can be too
/// big for this device. Better to say so than to pull several GB first.
struct PreflightResult: Sendable {
    var hasConfig = false
    var hasWeights = false
    var hasTokenizer = false
    var totalBytes = 0
    var fitsRecommendedMemory = true
    /// `nil` when it couldn't be determined (the tiny chat-template fetch
    /// failed, or the repo doesn't publish one) — see
    /// `ModelCapabilityProbe.remote`.
    var capabilities: ModelCapabilityProbe.Capabilities?

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
        messages.append(contentsOf: capabilities?.warnings ?? [])
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

        for entry in entries where entry.type == .file {
            switch entry.path {
            case "config.json":
                result.hasConfig = true
            case "tokenizer.json", "tokenizer_config.json":
                result.hasTokenizer = true
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
        // real MLX model — no point spending another fetch on one that's
        // about to fail preflight anyway.
        if result.isCompatible {
            result.capabilities = await ModelCapabilityProbe.remote(repoID: id)
        }
        return result
    }
}
