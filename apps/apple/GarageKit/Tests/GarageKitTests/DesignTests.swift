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

    /// Line spacing is the token line height (a multiple of the size) less the face's own line height.
    @Test func lineSpacingComesFromTheLineHeightMultiplier() {
        for scale in TypeScale.allCases {
            let target = scale.style.lineHeight * scale.style.size
            #expect(abs(scale.lineSpacing - (target - scale.defaultLineHeight)) < 1e-6)
            #expect(scale.defaultLineHeight > scale.style.size * 0.9) // resolved the bundled face, not a fallback stub
        }
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
