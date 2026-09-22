import Lottie
import SwiftUI

/// The illustration shown before a conversation exists, rendered by Lottie's
/// own engine rather than flattened to a bitmap. lottie-ios has no support
/// for dotLottie's slot/theme system, so each appearance ships as its own
/// pre-baked JSON (`NuevaConversacionClaro`/`Oscuro`) with the file's real
/// "Claro" theme colors already applied — verified pixel-for-pixel against
/// the official dotlottie-web renderer's live `.setTheme()` output, so it's
/// not a guess at what those colors should be.
struct NuevaConversacionAnimationView: View {
    @Environment(\.colorScheme) private var colorScheme

    private var animation: LottieAnimation? {
        LottieAnimation.named(colorScheme == .light ? "NuevaConversacionClaro" : "NuevaConversacionOscuro")
    }

    var body: some View {
        LottieView(animation: animation)
            .playing(loopMode: .loop)
            .resizable()
            .accessibilityHidden(true)
    }
}

#Preview {
    NuevaConversacionAnimationView()
        .frame(width: 220, height: 220)
        .background(FaroColor.ink)
}
