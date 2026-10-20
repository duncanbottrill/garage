import Testing
@testable import GarageKit

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

@Suite struct IconsTests {
    static let names = ["lock", "lock-open", "thermometer", "snowflake", "flame", "battery-charging", "plug", "plug-zap",
                        "car-front", "navigation", "map-pin", "fan", "wind", "zap", "clock", "refresh-cw", "settings",
                        "chevron-right", "circle-alert", "wifi-off", "check", "x", "sun", "moon", "gauge", "route", "minus", "plus",
                        "key", "server", "link", "network", "user", "info"]

    /// Every Lucide icon the app names is in GarageKit's asset catalog, as a template image.
    @Test(arguments: names) func iconIsBundledAsTemplate(_ name: String) throws {
        #if canImport(UIKit)
        let image = try #require(UIImage(named: name, in: GarageKit.resources, with: nil))
        #expect(image.renderingMode == .alwaysTemplate)
        #else
        let image = try #require(GarageKit.resources.image(forResource: name))
        #expect(image.isTemplate)
        #endif
    }
}
