#if os(iOS)
import SnapshotTesting
import SwiftUI
import Testing
@testable import GarageKit

@MainActor @Suite struct DesignSnapshotTests {
    /// The primitives together on the app background: hero numeral, label, glass tile with an icon, hairline.
    @Test func primitivesDark() {
        GarageKit.registerFonts()
        let view = VStack(alignment: .leading, spacing: Tokens.Space.l) {
            SmallCapsLabel("Charge")
            Numeral(value: 84, unit: "%", scale: .numeralHero)
            Hairline()
            HStack(spacing: Tokens.Space.m) {
                Icon(.lock)
                    .foregroundStyle(Tokens.Colors.accent)
                VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                    SmallCapsLabel("Doors", scale: .labelS)
                    Text("Locked").garage(.title).foregroundStyle(Tokens.Colors.ink)
                }
                Spacer()
                Numeral(value: 21.5, unit: "°C", scale: .numeralS, fractionDigits: 1)
            }
            .padding(Tokens.Space.l)
            .glassSurface()
            Hairline()
            Text("Updated 2 min ago").garage(.caption).foregroundStyle(Tokens.Colors.muted)
        }
        .padding(.horizontal, Tokens.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, Tokens.Space.xxl)
        .background(Tokens.Colors.background)
        .environment(\.colorScheme, .dark)

        assertSnapshot(
            of: view,
            as: .image(
                precision: SnapshotTolerance.precision,
                perceptualPrecision: SnapshotTolerance.perceptualPrecision,
                layout: .device(config: .iPhone17ProDark)
            )
        )
    }
}
#endif
