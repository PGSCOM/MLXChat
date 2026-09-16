import SwiftUI

/// Faro's signature artifact: a lighthouse beam sweeping with real light
/// falloff (cyan core → blue → violet, fading to nothing at the tip).
/// Rotation speeds up while a model is generating and pulses once per
/// incoming API request — motion tied to real state, never decorative.
struct BeamView: View {
    /// 0 = idle sweep, 1 = a model is actively generating.
    var intensity: Double = 0
    /// Bump this value to trigger a one-shot pulse (e.g. a server request).
    var pulseToken: Int = 0

    @State private var pulseScale: CGFloat = 1
    private let startDate = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(startDate)
            let degreesPerSecond = 10.0 + intensity * 50.0
            let baseDegrees = elapsed * degreesPerSecond
            let spreadDegrees = 16.0
            let baseRadians = baseDegrees * .pi / 180

            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let length = max(size.width, size.height) * 0.75

                var wedge = Path()
                wedge.move(to: center)
                wedge.addArc(
                    center: center,
                    radius: length,
                    startAngle: .degrees(baseDegrees - spreadDegrees / 2),
                    endAngle: .degrees(baseDegrees + spreadDegrees / 2),
                    clockwise: false
                )
                wedge.closeSubpath()

                let tip = CGPoint(
                    x: center.x + cos(baseRadians) * length,
                    y: center.y + sin(baseRadians) * length
                )

                context.fill(
                    wedge,
                    with: .linearGradient(
                        Gradient(stops: [
                            .init(color: FaroColor.beamCore.opacity(0.85), location: 0),
                            .init(color: FaroColor.beamMid.opacity(0.45), location: 0.55),
                            .init(color: FaroColor.beamFar.opacity(0), location: 1),
                        ]),
                        startPoint: center,
                        endPoint: tip
                    )
                )
            }
            .blur(radius: 6)
            .scaleEffect(pulseScale)
        }
        .onChange(of: pulseToken) { _, _ in
            withAnimation(.easeOut(duration: 0.15)) { pulseScale = 1.06 }
            withAnimation(.easeIn(duration: 0.35).delay(0.15)) { pulseScale = 1 }
        }
        .accessibilityHidden(true)
    }
}

#Preview {
    BeamView(intensity: 0.4)
        .frame(width: 280, height: 280)
        .background(FaroColor.ink)
}
