import Lottie
import SwiftUI

/// The illustration shown before a conversation exists, rendered by Lottie's
/// own engine rather than flattened to a bitmap. lottie-ios has no support
/// for dotLottie's slot/theme system, so each appearance ships as its own
/// JSON with every slot already resolved: `NuevaConversacionOscuro` is the
/// source file's defaults, `NuevaConversacionClaro` its "Claro" theme. Both
/// come out of `scripts/bake_lottie.py`; regenerate them there, never by
/// hand. The export's inline fallback values are stale, so a hand-edited
/// file makes lottie-ios read leftover gradient stops as opacity and draw
/// the tower see-through.
///
/// This animation (2200×2200, ~117 shape groups, 17 trim paths, `Add` masks)
/// mixes trims and masks in a way the Core Animation engine can't render, so
/// Lottie falls back to its main-thread engine — real CPU work on every
/// frame it's on screen. Left playing behind a sheet (Settings, generation
/// settings, the model browser) that competes with it for the main thread,
/// it visibly drags the sheet's own scroll framerate down.
struct NuevaConversacionAnimationView: View {
    @Environment(\.colorScheme) private var colorScheme
    /// Set to `false` while a sheet covers this view — a paused Lottie still
    /// costs nothing, but a playing one keeps redrawing behind whatever is
    /// on top of it for no visible benefit.
    var isPlaying = true

    private var animation: LottieAnimation? {
        LottieAnimation.named(colorScheme == .light ? "NuevaConversacionClaro" : "NuevaConversacionOscuro")
    }

    var body: some View {
        LottieView(animation: animation)
            .playbackMode(isPlaying ? .playing(.fromProgress(nil, toProgress: 1, loopMode: .loop)) : .paused(at: .currentFrame))
            // The file is keyframed at 30fps but the main-thread engine
            // redraws on every screen refresh by default (60-120Hz) —
            // this caps real redraw work to the 30 frames that actually
            // change anything, cutting it roughly in half on most devices.
            .configure(\.respectAnimationFrameRate, to: true)
            .resizable()
            .accessibilityHidden(true)
    }
}

#Preview {
    NuevaConversacionAnimationView()
        .frame(width: 220, height: 220)
        .background(FaroColor.ink)
}
