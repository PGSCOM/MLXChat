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
/// `respectAnimationFrameRate` is off-limits here: this asset's automatic
/// engine selection resolves to Core Animation, which throws a fatal error
/// the moment that property is set (confirmed by a crashing CI run — don't
/// reintroduce it). Left playing behind a sheet (Settings, generation
/// settings, the model browser), the animation still visibly drags down the
/// sheet's own scroll framerate, so it's paused instead whenever one covers
/// this view.
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
            .resizable()
            .accessibilityHidden(true)
    }
}

#Preview {
    NuevaConversacionAnimationView()
        .frame(width: 220, height: 220)
        .background(FaroColor.ink)
}
