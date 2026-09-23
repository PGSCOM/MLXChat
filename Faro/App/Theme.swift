import SwiftUI
import UIKit

/// Design tokens for Faro. One warm surface lit by a single source — the
/// lamp — in either appearance: near-black in dark mode, warm paper in
/// light. Every token follows the system setting (see `adaptive(dark:light:)`)
/// so the whole app repaints together. `lamp`/`lampCore` belong to the
/// light (the beam, live state, the primary action); everything else is
/// tone: `bone` for what must be read, `ash` for what supports it.
enum FaroColor {
    static let ink = adaptive(dark: 0x100F0D, light: 0xF6F1E6)
    static let inkRaised = adaptive(dark: 0x1A1815, light: 0xFFFDF7)
    /// Self-coloured hairline: a lip catching the lamp, not a drawn outline.
    static let edge = adaptive(dark: 0x2B2620, light: 0xE2D8C4)
    static let lamp = adaptive(dark: 0xF5C15A, light: 0x8F5710)
    static let lampCore = adaptive(dark: 0xFFF1D6, light: 0xC9862A)
    static let bone = adaptive(dark: 0xEFE7DA, light: 0x1C1712)
    static let ash = adaptive(dark: 0x9C9488, light: 0x6B6156)
    /// Errors, exclusively. Muted brick rather than a poster-bright red,
    /// far enough from the lamp's amber to never read as "lit".
    static let error = adaptive(dark: 0xD4675A, light: 0xB3392A)

    /// A `Color` that resolves per trait collection, so it repaints with
    /// the system appearance (or an in-app override) with no extra state.
    private static func adaptive(dark: UInt32, light: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
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
