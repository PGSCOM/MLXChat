import SwiftUI

/// Faro's signature artifact: a lighthouse lamp with its beam sweeping
/// out of it — one warm light with real falloff, never a decorative
/// gradient. The sweep speeds up while a model is generating and pulses
/// once per incoming API request, so the motion always reports real state.
struct BeamView: View {
    /// 0 = idle sweep, 1 = a model is actively generating.
    var intensity: Double = 0
    /// Bump this value to trigger a one-shot pulse (e.g. a server request).
    var pulseToken: Int = 0

    @State private var pulseScale: CGFloat = 1
    private let startDate = Date()

    var body: some View {
        ZStack {
            sweep
            lamp
        }
        .scaleEffect(pulseScale)
        .onChange(of: pulseToken) { _, _ in
            withAnimation(.easeOut(duration: 0.15)) { pulseScale = 1.06 }
            withAnimation(.easeIn(duration: 0.35).delay(0.15)) { pulseScale = 1 }
        }
        .accessibilityHidden(true)
    }

    /// Idle sweeps at half the frame rate: this view sits on screen for as
    /// long as a conversation is empty, and a still beam doesn't need 30fps.
    private var frameInterval: Double { intensity > 0.3 ? 1.0 / 30.0 : 1.0 / 15.0 }

    private var sweep: some View {
        TimelineView(.animation(minimumInterval: frameInterval)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(startDate)
            let degreesPerSecond = 10.0 + intensity * 50.0
            let baseDegrees = elapsed * degreesPerSecond
            let baseRadians = baseDegrees * .pi / 180

            Canvas { context, size in
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                // Just under half the shortest side: the light has to
                // reach nothing before it reaches the canvas edge, or the
                // sweep gets sliced off square in the corners.
                let length = min(size.width, size.height) * 0.47
                let spreadDegrees = 16.0

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
                            .init(color: FaroColor.lampCore.opacity(0.75), location: 0),
                            .init(color: FaroColor.lamp.opacity(0.32), location: 0.5),
                            .init(color: FaroColor.lamp.opacity(0), location: 1),
                        ]),
                        startPoint: center,
                        endPoint: tip
                    )
                )
            }
            .blur(radius: 7)
        }
    }

    /// The source itself, left crisp above the blurred beam so the light
    /// reads as coming from somewhere instead of hanging in the air.
    private var lamp: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [FaroColor.lampCore, FaroColor.lamp.opacity(0.35)],
                    center: .center, startRadius: 0, endRadius: 7
                )
            )
            .frame(width: 10, height: 10)
    }
}

#Preview {
    BeamView(intensity: 0.4)
        .frame(width: 280, height: 280)
        .background(FaroColor.ink)
}
