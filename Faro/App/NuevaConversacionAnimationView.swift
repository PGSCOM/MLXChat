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
