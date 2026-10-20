import SwiftUI

/// The Garage glass surface: `.ultraThinMaterial` tinted with the glass colour at the glass opacity,
/// in a continuous rounded rectangle with a white 8 % hairline border.
public struct GlassSurface: ViewModifier {
    /// How opaque the tint is.
    public enum Strength: Sendable {
        /// `Tokens.Opacity.glass`, for tiles and cards.
        case regular
        /// `Tokens.Opacity.glassStrong`, for sheets and anything over busy content such as the map.
        case strong

        /// The tint opacity token for this strength.
        public var opacity: Double {
            switch self {
            case .regular: Tokens.Opacity.glass
            case .strong: Tokens.Opacity.glassStrong
            }
        }
    }

    /// Corner radius; use a `Tokens.Radius` value.
    public let radius: CGFloat
    /// Tint strength.
    public let strength: Strength

    @Environment(\.displayScale) private var displayScale

    /// - Parameters:
    ///   - radius: Corner radius, a `Tokens.Radius` value (tile by default).
    ///   - strength: Tint strength (regular by default).
    public init(radius: CGFloat = Tokens.Radius.tile, strength: Strength = .regular) {
        self.radius = radius
        self.strength = strength
    }

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(Tokens.Colors.glass.opacity(strength.opacity))
                }
            }
            .overlay {
                shape.strokeBorder(Color.white.opacity(Tokens.Opacity.hairline), lineWidth: 1 / displayScale)
            }
    }
}

extension View {
    /// Puts this view on a Garage glass surface. See `GlassSurface`.
    public func glassSurface(radius: CGFloat = Tokens.Radius.tile, strength: GlassSurface.Strength = .regular) -> some View {
        modifier(GlassSurface(radius: radius, strength: strength))
    }
}
