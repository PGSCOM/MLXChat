import SwiftUI

/// Design tokens for Faro. Colors only ever combine inside the beam artifact
/// (see `BeamView`); everywhere else the UI stays monochrome on `ink` with
/// `beamCore` as the single tonal accent.
enum FaroColor {
    static let ink = Color(hex: 0x0B0D1A)
    static let inkRaised = Color(hex: 0x12152B)
    static let beamCore = Color(hex: 0x7FE6FF)
    static let beamMid = Color(hex: 0x3B6FF0)
    static let beamFar = Color(hex: 0x6B3BD8)
    static let ash = Color(hex: 0xA8AEC8)
    /// Errors, exclusively. Never the beam's violet — that color belongs
    /// only inside `BeamView`, and violet doesn't read as "wrong" anyway.
    /// A tonal terracotta, muted rather than a poster-bright red.
    static let error = Color(hex: 0xE0654F)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
