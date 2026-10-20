import SwiftUI

/// A one-pixel divider in white at the hairline opacity (8 %).
public struct Hairline: View {
    /// The direction the line runs.
    public let axis: Axis

    @Environment(\.displayScale) private var displayScale

    /// - Parameter axis: `.horizontal` (default) spans the width; `.vertical` spans the height.
    public init(_ axis: Axis = .horizontal) {
        self.axis = axis
    }

    public var body: some View {
        let pixel = 1 / displayScale
        Rectangle()
            .fill(Color.white.opacity(Tokens.Opacity.hairline))
            .frame(width: axis == .vertical ? pixel : nil, height: axis == .horizontal ? pixel : nil)
            .frame(maxWidth: axis == .horizontal ? .infinity : nil, maxHeight: axis == .vertical ? .infinity : nil)
            .accessibilityHidden(true)
    }
}
