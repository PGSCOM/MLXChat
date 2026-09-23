import Foundation
import Observation

/// A model load in progress, as shown in the chat status band and the
/// model browser row. Derived from the raw `Progress` HubClient reports.
struct ModelLoadStatus {
    enum Phase { case downloading, loadingIntoMemory }

    var phase: Phase
    var fraction: Double
    var completedBytes: Int64
    var totalBytes: Int64
    var bytesPerSecond: Double

    var hasByteInfo: Bool { totalBytes > 0 }
}

/// Drives preflight + download for the model browser, and doubles as the
/// shared source of truth for the chat's own load/download status band so
/// both surfaces show the same numbers for the same in-flight load.
@Observable
@MainActor
final class ModelDownloadCoordinator {
    static let shared = ModelDownloadCoordinator()

    private(set) var status: [String: ModelLoadStatus] = [:]
    private(set) var errors: [String: String] = [:]
    /// Preflight's soft findings (`PreflightResult.softWarnings`) — memory
    /// fit, tool-calling, reasoning. None of them are fatal (the memory
    /// figure is conservative, the capability checks read a small probe
    /// file rather than the model actually running), so this is shown
    /// before the download and the download continues regardless.
    private(set) var warnings: [String: String] = [:]

    /// Last raw sample per model, to derive a smoothed transfer rate — a
    /// lone `fractionCompleted` reading says nothing about speed.
    private var lastSample: [String: (date: Date, bytes: Int64)] = [:]
    /// The in-flight download Task per model, so `cancel(id:)` has
    /// something to cancel.
    private var tasks: [String: Task<Void, Never>] = [:]

    func download(id: String) {
        guard status[id] == nil else { return }
        errors[id] = nil
        warnings[id] = nil
        beginLoad(id: id)

        tasks[id] = Task {
            do {
                let preflight = try await ModelPreflight.check(repoID: id)
                guard preflight.isCompatible else {
                    errors[id] = preflight.summary
                    status[id] = nil
                    return
                }
                let combined = preflight.softWarnings.joined(separator: " · ")
                if !combined.isEmpty { warnings[id] = combined.prefix(1).uppercased() + combined.dropFirst() }
                _ = try await InferenceEngine.shared.loadContainer(modelID: id) { [weak self] value in
                    Task { @MainActor in self?.record(id: id, value: value) }
                }
                status[id] = nil
                lastSample[id] = nil
            } catch {
                // A cancelled download isn't a failure — `cancel(id:)`
                // already reset the row itself, so don't overlay a spurious
                // error message on top of that (the underlying fetch can
                // surface cancellation as `CancellationError` or, from
                // URLSession, `URLError.cancelled` — `Task.isCancelled`
                // catches both instead of guessing the error type).
                guard !Task.isCancelled else { return }
                errors[id] = error.localizedDescription
                status[id] = nil
                lastSample[id] = nil
            }
        }
    }

    /// Cuts a download in progress. `HubCache` stores completed blobs as it
    /// goes, so a later re-download resumes rather than starting over.
    ///
    /// ponytail: doesn't clear `tasks[id]` once a download finishes on its
    /// own — only this and the next `download(id:)` call for the same id
    /// touch it. A finished `Task` is cheap to leave sitting in the
    /// dictionary; clearing it from inside the task itself would need a
    /// generation token to avoid a fast cancel-then-retry race clobbering a
    /// newer task's slot.
    func cancel(id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        status[id] = nil
        lastSample[id] = nil
        warnings[id] = nil
        errors[id] = nil
    }

    /// Called by the chat path, which loads on demand rather than through
    /// an explicit "download" tap — same bookkeeping, no preflight (the
    /// model was already chosen).
    func beginLoad(id: String) {
        if status[id] == nil {
            status[id] = ModelLoadStatus(
                phase: .loadingIntoMemory, fraction: 0,
                completedBytes: 0, totalBytes: 0, bytesPerSecond: 0
            )
        }
    }

    func finishLoad(id: String) {
        status[id] = nil
        lastSample[id] = nil
    }

    func record(id: String, value: Progress) {
        let total = value.totalUnitCount
        let completed = value.completedUnitCount
        let now = Date()

        var bytesPerSecond = status[id]?.bytesPerSecond ?? 0
        if let previous = lastSample[id] {
            let elapsed = now.timeIntervalSince(previous.date)
            // Ignore samples closer than 0.5s together so the rate doesn't
            // jitter on every tiny HubClient callback.
            if elapsed >= 0.5 {
                let instantRate = Double(completed - previous.bytes) / elapsed
                // EMA(α=0.3): smooths bursty chunk arrivals into one number.
                bytesPerSecond = bytesPerSecond == 0 ? instantRate : (0.3 * instantRate + 0.7 * bytesPerSecond)
                lastSample[id] = (now, completed)
            }
        } else {
            lastSample[id] = (now, completed)
        }

        status[id] = ModelLoadStatus(
            phase: total > 0 ? .downloading : .loadingIntoMemory,
            fraction: value.fractionCompleted,
            completedBytes: completed,
            totalBytes: total,
            bytesPerSecond: bytesPerSecond
        )
    }
}
