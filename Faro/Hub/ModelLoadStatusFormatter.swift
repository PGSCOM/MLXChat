import Foundation

/// One compact status line, shared by the chat status band and the model
/// browser row so both read the same numbers the same way.
enum ModelLoadStatusFormatter {
    static func phaseLabel(_ status: ModelLoadStatus) -> String {
        switch status.phase {
        case .downloading: "Descargando"
        case .loadingIntoMemory: "Cargando en memoria…"
        }
    }

    /// e.g. "42 % · 2,1/4,9 GB · 12 MB/s · quedan 3 min", or just the
    /// percentage when the `Progress` carries no byte totals.
    static func line(_ status: ModelLoadStatus) -> String {
        let percent = "\(Int(status.fraction * 100)) %"
        guard status.hasByteInfo, status.phase == .downloading else { return percent }

        var parts = [percent]
        let completed = status.completedBytes.formatted(.byteCount(style: .memory))
        let total = status.totalBytes.formatted(.byteCount(style: .memory))
        parts.append("\(completed)/\(total)")

        if status.bytesPerSecond > 0 {
            parts.append(Int64(status.bytesPerSecond).formatted(.byteCount(style: .memory)) + "/s")
        }
        if let eta = status.eta, eta.isFinite, eta > 0 {
            let duration = Duration.seconds(eta)
            parts.append("quedan " + duration.formatted(.units(width: .narrow, maximumUnitCount: 1)))
        }
        return parts.joined(separator: " · ")
    }
}
