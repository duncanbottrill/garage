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

    /// - Parameters:
    ///   - radius: Corner radius, a `Tokens.Radius` value (tile by default).
    ///   - strength: Tint strength (regular by default).
    public init(radius: CGFloat = Tokens.Radius.tile, strength: Strength = .regular) {
        self.radius = radius
        self.strength = strength
    }

    public func body(content: Content) -> some View {
        content.modifier(GlassShapeSurface(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), strength: strength))
    }
}

/// The glass fill and hairline border in any insettable shape; ``GlassSurface`` uses a rounded
/// rectangle, ``SwiftUI/View/glassCapsule(strength:)`` a continuous capsule.
struct GlassShapeSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let strength: GlassSurface.Strength

    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
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

    /// Puts this view on Garage glass in a continuous capsule, for pills and strips whose corner
    /// radius (`Tokens.Radius.pill`) is half their height.
    public func glassCapsule(strength: GlassSurface.Strength = .regular) -> some View {
        modifier(GlassShapeSurface(shape: Capsule(style: .continuous), strength: strength))
    }
}

extension Tokens.Opacity {
    /// White at this opacity outlines a near-black control on the app background (the Sign in with
    /// Apple button), where the 8 % ``hairline`` is too faint to read as an edge. Not part of
    /// `tokens.json` yet; move it there if the web needs the same edge.
    public static let controlEdge: Double = 0.24
}
