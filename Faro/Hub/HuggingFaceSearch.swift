import Foundation
import HuggingFace

struct HuggingFaceSearchResult: Identifiable, Sendable {
    let id: String
    let downloads: Int
    let tags: [String]
}

/// Searches Hugging Face for MLX-tagged repos — any repo, not a fixed
/// catalog. `ModelPreflight` decides afterward whether a given result is
/// actually loadable.
enum HuggingFaceSearch {
    static func search(_ query: String) async throws -> [HuggingFaceSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let response = try await HubClient.default.listModels(
            search: trimmed,
            filter: "mlx",
            sort: "downloads",
            direction: .descending,
            limit: 30
        )
        return response.items.map {
            HuggingFaceSearchResult(
                id: $0.id.rawValue,
                downloads: $0.downloads ?? 0,
                tags: $0.tags ?? []
            )
        }
    }
}
