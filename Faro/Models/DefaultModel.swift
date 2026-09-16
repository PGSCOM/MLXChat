enum DefaultModel {
    /// Used when a brand new conversation is created, before the user
    /// picks one from the model browser (Fase 2). Any valid HF repo id
    /// works here — the engine doesn't consult a fixed registry.
    static let repoID = CuratedModel.all.first?.id ?? "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
}
