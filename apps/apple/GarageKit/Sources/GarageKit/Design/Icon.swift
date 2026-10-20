import SwiftUI

/// A Lucide icon from GarageKit's asset catalog, drawn as a template image in the current foreground
/// style (set it with `.foregroundStyle`).
///
/// Lucide draws on a 24-unit grid with a 2-unit stroke, so the stroke is `size / 12`: the design's
/// 1.5 pt stroke (`strokeWidth`) is exact at 18 pt (`strokeTrueSize`), the default. Icons are decorative
/// to VoiceOver; label the control that holds one.
public struct Icon: View {
    /// The bundled icon names; each raw value is the asset name.
    public enum Name: String, CaseIterable, Sendable {
        case lock, lockOpen = "lock-open", thermometer, snowflake, flame
        case batteryCharging = "battery-charging", plug, plugZap = "plug-zap", carFront = "car-front"
        case navigation, mapPin = "map-pin", fan, wind, zap, clock, refreshCw = "refresh-cw", settings
        case chevronRight = "chevron-right", circleAlert = "circle-alert", wifiOff = "wifi-off"
        case check, x, sun, moon, gauge, route, minus, plus
    }

    /// The design stroke width for icons, in points.
    nonisolated public static let strokeWidth: CGFloat = 1.5
    /// The point size at which a Lucide glyph (2 units on a 24-unit grid) has exactly `strokeWidth`.
    nonisolated public static let strokeTrueSize: CGFloat = strokeWidth * 24 / 2

    private let name: Name
    private let size: CGFloat

    /// - Parameters:
    ///   - name: The icon.
    ///   - size: Edge length in points; 18 (the default) keeps the 1.5 pt stroke exact.
    public init(_ name: Name, size: CGFloat = Icon.strokeTrueSize) {
        self.name = name
        self.size = size
    }

    public var body: some View {
        Image(decorative: name.rawValue, bundle: .module)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
    }
}
