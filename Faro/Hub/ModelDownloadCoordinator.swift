import Foundation
import Observation

/// Drives preflight + download for the model browser. Shared by every row
/// so switching tabs or re-opening the sheet doesn't lose progress.
@Observable
@MainActor
final class ModelDownloadCoordinator {
    private(set) var progress: [String: Double] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var ready: Set<String> = []

    func download(id: String) {
        guard progress[id] == nil else { return }
        errors[id] = nil
        progress[id] = 0

        Task {
            do {
                let preflight = try await ModelPreflight.check(repoID: id)
                guard preflight.isCompatible else {
                    errors[id] = preflight.summary
                    progress[id] = nil
                    return
                }

                _ = try await InferenceEngine.shared.loadContainer(modelID: id) { [weak self] value in
                    Task { @MainActor in
                        self?.progress[id] = value.fractionCompleted
                    }
                }
                ready.insert(id)
                progress[id] = nil
            } catch {
                errors[id] = error.localizedDescription
                progress[id] = nil
            }
        }
    }
}
