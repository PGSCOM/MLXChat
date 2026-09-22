import SwiftUI
import Lottie

/// The empty-state animation shown before a conversation exists. Bundled as
/// two plain-JSON Lottie exports rather than the original `.dotLottie` —
/// lottie-ios has no runtime support for dotLottie's "theme" slots, so the
/// light-mode recolor (originally the file's "Claro" theme) is baked in
/// once, offline. That also skips the zip-decompress-to-temp-file dance
/// `DotLottieFile` would otherwise do on every launch.
struct NuevaConversacionAnimationView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LottieView {
            LottieAnimation.named(colorScheme == .light ? "NuevaConversacionClaro" : "NuevaConversacionOscuro")
        }
        .reloadAnimationTrigger(colorScheme)
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
