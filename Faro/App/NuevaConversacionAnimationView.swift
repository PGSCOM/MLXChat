import SwiftUI

/// The illustration shown before a conversation exists — a static PNG, not a
/// live animation. The source `.dotLottie` never actually animated (every
/// frame across its 10-second timeline was pixel-identical), and lottie-ios
/// rendered its colors wrong on-device, so it's baked to a bitmap once
/// instead: simpler, and it reads correctly in both light and dark mode with
/// no extra work.
struct NuevaConversacionAnimationView: View {
    var body: some View {
        Image("NuevaConversacion")
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }
}

#Preview {
    NuevaConversacionAnimationView()
        .frame(width: 220, height: 220)
        .background(FaroColor.ink)
}
