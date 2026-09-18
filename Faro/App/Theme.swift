import SwiftUI

/// Design tokens for Faro. The whole app is one warm, near-black surface
/// lit by a single source — the lamp. `lamp`/`lampCore` belong to the
/// light (the beam, live state, the primary action); everything else is
/// tone: `bone` for what must be read, `ash` for what supports it.
enum FaroColor {
    static let ink = Color(hex: 0x100F0D)
    static let inkRaised = Color(hex: 0x1A1815)
    /// Self-coloured hairline: a lip catching the lamp, not a drawn outline.
    static let edge = Color(hex: 0x2B2620)
    static let lamp = Color(hex: 0xF5C15A)
    static let lampCore = Color(hex: 0xFFF1D6)
    static let bone = Color(hex: 0xEFE7DA)
    static let ash = Color(hex: 0x9C9488)
    /// Errors, exclusively. Muted brick rather than a poster-bright red,
    /// far enough from the lamp's amber to never read as "lit".
    static let error = Color(hex: 0xD4675A)
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

extension View {
    /// The one raised surface in the app: a fill a shade above the page
    /// plus a hairline in the surface's own colour — a lip catching the
    /// lamp, not a drawn outline. Every card used to hand-roll this with a
    /// different radius (14, 16, 18); that was drift, not intent.
    func faroCard(border: Color = FaroColor.edge) -> some View {
        background(FaroColor.inkRaised, in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16).strokeBorder(border, lineWidth: 1)
            }
    }
}
