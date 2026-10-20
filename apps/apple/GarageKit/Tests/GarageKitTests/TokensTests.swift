import CoreText
import SwiftUI
import Testing
@testable import GarageKit

#if canImport(UIKit)
import UIKit
private typealias PlatformColor = UIColor
#else
import AppKit
private typealias PlatformColor = NSColor
#endif

@Suite struct TokensTests {
    /// The accent token, the sheet radius and the hero numeral match the Figma values, and the bundled
    /// display face resolves by family name once registered.
    @Test func accentMatchesFigma() throws {
        var (r, g, b, a): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        #if canImport(UIKit)
        let resolved = PlatformColor(Tokens.Colors.accent)
        #expect(resolved.getRed(&r, green: &g, blue: &b, alpha: &a))
        #else
        let resolved = try #require(PlatformColor(Tokens.Colors.accent).usingColorSpace(.sRGB))
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        // #4FE3FF
        #expect(abs(r - 0x4F / 255.0) < 1e-3)
        #expect(abs(g - 0xE3 / 255.0) < 1e-3)
        #expect(abs(b - 0xFF / 255.0) < 1e-3)
        #expect(abs(a - 1) < 1e-3)

        #expect(Tokens.Radius.sheet == 28)
        #expect(Tokens.Typography.numeralHero.size == 84)

        GarageKit.registerFonts()
        GarageKit.registerFonts() // idempotent: a second call must not fail or double-register
        _ = Font.custom("Big Shoulders Display", size: 22)
        let display = CTFontCreateWithName("Big Shoulders Display" as CFString, 22, nil)
        #expect(CTFontCopyFamilyName(display) as String == "Big Shoulders Display")
        let ui = CTFontCreateWithName("Instrument Sans" as CFString, 14, nil)
        #expect(CTFontCopyFamilyName(ui) as String == "Instrument Sans")
    }
}
