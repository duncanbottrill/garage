import SwiftUI
import Testing
@testable import GarageKit

#if os(macOS)
import AppKit

@Suite struct PlaceholdersTests {
    /// As the Mac split view's detail, a screen whose ideal height is its content's shifts the sidebar list
    /// up by about that height (macOS 26). The placeholders report a small, content-independent ideal
    /// size instead, as a `GeometryReader` does, so the sidebar keeps its rows.
    @Test @MainActor func placeholdersDoNotTakeTheirIdealHeightFromContent() {
        let screens: [(String, AnyView)] = [
            ("Drives", AnyView(DrivesPlaceholder())),
            ("Charges", AnyView(ChargesPlaceholder())),
            ("Battery", AnyView(BatteryPlaceholder())),
        ]
        for (name, screen) in screens {
            let ideal = NSHostingView(rootView: screen).fittingSize
            #expect(ideal.height < 40, "\(name) ideal height \(ideal.height) comes from its content")
        }
    }
}
#endif
