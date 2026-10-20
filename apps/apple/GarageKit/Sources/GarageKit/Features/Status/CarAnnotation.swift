import SwiftUI

extension EnvironmentValues {
    /// Whether Status screen views run their looping animations (the breathing halo, the pending ring).
    /// Snapshot renders turn it off so every frame is the same.
    @Entry var statusMotion: Bool = true
}

/// The car on the map: an accent dot with a breathing halo while the bridge is online, a solid dot
/// without one while it is offline, and a chevron pointing along `heading` while the car is moving.
struct CarAnnotation: View {
    /// The bridge checked in within 90 s.
    let online: Bool
    /// Degrees clockwise from north.
    let heading: Double?
    /// `speed_kph > 0`.
    let moving: Bool

    static let dotSize: CGFloat = 12
    /// The halo starts at twice the dot and breathes out to 1.8× that.
    static let haloSize: CGFloat = 24
    static let haloScale: CGFloat = 1.8

    @Environment(\.statusMotion) private var motion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false

    var body: some View {
        ZStack {
            if online {
                Circle()
                    .fill(Tokens.Colors.accent.opacity(Tokens.Opacity.accentFill))
                    .frame(width: Self.haloSize, height: Self.haloSize)
                    .scaleEffect(breathing ? Self.haloScale : 1)
            }
            if moving, let heading {
                // Lucide's navigation arrow points north-east, so north is 45° anticlockwise of it.
                Icon(.navigation)
                    .foregroundStyle(Tokens.Colors.accent)
                    .rotationEffect(.degrees(heading - 45))
            } else {
                Circle()
                    .fill(Tokens.Colors.accent)
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .overlay { Circle().strokeBorder(Tokens.Colors.background, lineWidth: 2) }
            }
        }
        .frame(width: Self.haloSize * Self.haloScale, height: Self.haloSize * Self.haloScale)
        .onAppear(perform: startBreathing)
        .onChange(of: online) { startBreathing() }
        .accessibilityElement()
        .accessibilityLabel(online ? "Car, live" : "Car, last known position")
    }

    private func startBreathing() {
        guard online, motion, !reduceMotion else {
            breathing = false
            return
        }
        withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { breathing = true }
    }
}
