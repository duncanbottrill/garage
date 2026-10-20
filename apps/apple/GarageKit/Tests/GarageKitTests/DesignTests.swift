import CoreGraphics
import SwiftUI
import Testing
@testable import GarageKit

@Suite struct DesignTests {
    /// Big Shoulders Display sets the four numeral scales only, never below 22 pt; Instrument Sans sets
    /// everything else. `GarageFont.display(_:)` traps on any other scale, so the table is what is tested.
    @Test func displayFontIsBigShouldersOnlyAtOrAbove22() {
        #expect(TypeScale.allCases.filter(\.isDisplay) == [.numeralHero, .numeralL, .numeralM, .numeralS])
        for scale in TypeScale.allCases {
            if scale.isDisplay {
                #expect(scale.style.family == "Big Shoulders Display")
                #expect(scale.style.weight == .semibold)
                #expect(scale.style.size >= 22)
            } else {
                #expect(scale.style.family == "Instrument Sans")
            }
        }
        #expect(Icon.strokeWidth == 1.5)
    }

    /// Each scale reads its own generated token, not a neighbour's.
    @Test func scalesMapToTheirTokens() {
        #expect(TypeScale.numeralHero.style.size == Tokens.Typography.numeralHero.size)
        #expect(TypeScale.numeralS.style.size == Tokens.Typography.numeralS.size)
        #expect(TypeScale.title.style.size == Tokens.Typography.title.size)
        #expect(TypeScale.body.style.size == Tokens.Typography.body.size)
        #expect(TypeScale.caption.style.size == Tokens.Typography.caption.size)
        #expect(TypeScale.label.style.size == Tokens.Typography.label.size)
        #expect(TypeScale.labelS.style.size == Tokens.Typography.labelS.size)
    }

    /// Labels track at +12 %: 0.12 × 11 pt for `label`, 0.12 × 10 pt for `labelS`; the hero tightens by 2 %.
    @Test func trackingIsAFractionOfTheSize() {
        #expect(abs(TypeScale.label.trackingPoints - 1.32) < 1e-9)
        #expect(abs(TypeScale.labelS.trackingPoints - 1.2) < 1e-9)
        #expect(abs(TypeScale.numeralHero.trackingPoints - (-1.68)) < 1e-9)
        #expect(TypeScale.body.trackingPoints == 0)
    }

    /// A line is `lineHeight × size` tall when rendered: 0.84 × 84 = 70.56 pt for the hero numeral
    /// (well under the face's own ~100 pt) and 1.4 × 14 = 19.6 pt for body.
    @MainActor @Test func renderedLineHeightMatchesTheToken() throws {
        GarageKit.registerFonts()
        func height(_ text: some View) throws -> CGFloat {
            let renderer = ImageRenderer(content: text)
            renderer.scale = 1
            renderer.proposedSize = .unspecified
            let image = try #require(renderer.cgImage)
            return CGFloat(image.height)
        }
        let hero = try height(Text("84").garage(.numeralHero))
        #expect(abs(hero - 70.56) <= 2, "hero line is \(hero) pt")
        let body = try height(Text("Locked").garage(.body))
        #expect(abs(body - 19.6) <= 2, "body line is \(body) pt")
        let twoLines = try height(Text("Locked\nLocked").garage(.body))
        #expect(abs(twoLines - 39.2) <= 2, "two body lines are \(twoLines) pt")
        #expect(TypeScale.numeralHero.lineHeight == .exact(points: 0.84 * 84))
        #expect(TypeScale.body.lineHeight == .multiple(factor: 1.4))
        // The numeral view keeps the same line box, with and without its unit.
        let numeral = try height(Numeral(value: 84, unit: "%", scale: .numeralHero))
        #expect(abs(numeral - 70.56) <= 2, "hero numeral with unit is \(numeral) pt")
        let bare = try height(Numeral(value: 84, scale: .numeralHero))
        #expect(abs(bare - 70.56) <= 2, "hero numeral without unit is \(bare) pt")
    }

    /// The hero's glyphs sit inside its 70.56 pt line box the way Figma lays them out (half-leading: the
    /// reduction comes off the top and bottom equally), not hanging ~13 pt out of the bottom as SwiftUI
    /// places them by default. Measured on the rendered ink: cap tops at the top edge, and at least 1 pt
    /// clear at the bottom (baseline ~3 pt up, less the round "8" overshoot); uncorrected, the ink starts
    /// 16 pt down and is clipped at the bottom edge.
    @MainActor @Test func heroGlyphsSitInsideTheLineBox() throws {
        GarageKit.registerFonts()
        for view in [AnyView(Text("84").garage(.numeralHero)), AnyView(Numeral(value: 84, unit: "%", scale: .numeralHero))] {
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            let ink = try #require(Self.inkRows(image))
            let height = CGFloat(image.height)
            #expect(ink.top <= 4, "ink starts \(ink.top) pt below the top of the box")
            #expect(height - 1 - ink.bottom >= 1, "ink reaches \(ink.bottom) pt in a \(height) pt box")
        }
    }

    /// First and last pixel rows with any coverage.
    private static func inkRows(_ image: CGImage) -> (top: CGFloat, bottom: CGFloat)? {
        let width = image.width, height = image.height
        var alpha = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &alpha, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Bitmap memory is top row first.
        let rows = (0..<height).filter { row in (0..<width).contains { alpha[row * width + $0] > 64 } }
        guard let first = rows.first, let last = rows.last else { return nil }
        return (CGFloat(first), CGFloat(last))
    }

    /// Lucide draws on a 24-unit grid with a 2-unit stroke, so 18 pt is the size whose stroke is 1.5 pt.
    @Test func iconStrokeTrueSizeIs18() {
        #expect(Icon.strokeTrueSize == 18)
    }

    /// Every icon name points at an asset Task 2 bundled, and every bundled asset has a name.
    @Test func iconNamesMatchTheAssetCatalog() {
        #expect(Set(Icon.Name.allCases.map(\.rawValue)) == Set(IconsTests.names))
        #expect(Icon.Name.allCases.count == IconsTests.names.count)
        #expect(Icon.Name.lockOpen.rawValue == "lock-open")
    }

    /// Glass uses the regular token opacity by default and the strong one when asked.
    @MainActor @Test func glassStrengthReadsTheOpacityTokens() {
        #expect(GlassSurface.Strength.regular.opacity == Tokens.Opacity.glass)
        #expect(GlassSurface.Strength.strong.opacity == Tokens.Opacity.glassStrong)
        #expect(GlassSurface().radius == Tokens.Radius.tile)
    }
}
