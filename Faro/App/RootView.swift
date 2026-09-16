import SwiftUI

/// Placeholder home screen for the Fase 0 skeleton build. Chat, model
/// management and the rest arrive in later phases; this only proves the
/// app boots, renders the signature beam, and links against every
/// declared dependency.
struct RootView: View {
    var body: some View {
        ZStack {
            FaroColor.ink.ignoresSafeArea()

            BeamView(intensity: 0.35)
                .frame(width: 320, height: 320)
                .offset(y: -40)

            VStack(spacing: 12) {
                Text("Faro")
                    .font(.system(size: 44, weight: .semibold, design: .serif))
                    .foregroundStyle(.white)
                Text("Modelos locales, sin límites de catálogo.")
                    .font(.system(size: 15))
                    .foregroundStyle(FaroColor.ash)
            }
        }
    }
}

#Preview {
    RootView()
}
