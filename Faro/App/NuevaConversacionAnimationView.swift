import SwiftUI
import Lottie

/// The empty-state animation shown before a conversation exists, loaded
/// from the bundled dotLottie asset (`Resources/NuevaConversacion.lottie`).
/// `LottieView`'s async source loads and caches the file off the main
/// thread, so this stays smooth on first appearance.
struct NuevaConversacionAnimationView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LottieView {
            try await DotLottieFile.named("NuevaConversacion")
        }
        .resizable()
        .playbackMode(reduceMotion ? .paused(at: .frame(0)) : .playing(.fromProgress(0, toProgress: 1, loopMode: .loop)))
        .accessibilityHidden(true)
    }
}

#Preview {
    NuevaConversacionAnimationView()
        .frame(width: 220, height: 220)
        .background(FaroColor.ink)
}
