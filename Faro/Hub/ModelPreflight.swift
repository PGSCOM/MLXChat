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

    var isCompatible: Bool { hasConfig && hasWeights && hasTokenizer }

    var summary: String {
        if !hasConfig { return "No se encontró config.json: no parece un modelo MLX." }
        if !hasWeights { return "No hay pesos .safetensors en este repositorio." }
        if !hasTokenizer { return "Falta el tokenizer del modelo." }
        if !fitsRecommendedMemory { return "Puede no caber en la memoria recomendada de este dispositivo." }
        return "Compatible."
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
        return result
    }
}
