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

    /// e.g. "42 % · 2,1/4,9 GB · 12 MB/s", or just the percentage when
    /// the `Progress` carries no byte totals. No estimated time left: the
    /// transfer rate on a phone swings too much for that number to ever
    /// have been honest.
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
        return parts.joined(separator: " · ")
    }
}
