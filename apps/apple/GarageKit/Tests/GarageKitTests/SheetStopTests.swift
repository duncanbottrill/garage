import CoreGraphics
import Foundation
import Testing
@testable import GarageKit

@Suite struct SheetStopTests {
    /// A drag past the threshold (48 pt) moves to the other stop; a shorter one snaps back.
    @Test func dragPastThresholdChangesStop() {
        #expect(SheetStop.full.after(dragging: 60, predicted: 60) == .compact)
        #expect(SheetStop.full.after(dragging: 30, predicted: 30) == .full)
        #expect(SheetStop.compact.after(dragging: -60, predicted: -60) == .full)
        #expect(SheetStop.compact.after(dragging: -30, predicted: -30) == .compact)
    }

    /// A flick counts by where it would end (120 pt), even when the finger moved less than the threshold.
    @Test func flickCountsByPredictedEnd() {
        #expect(SheetStop.full.after(dragging: 20, predicted: 150) == .compact)
        #expect(SheetStop.compact.after(dragging: -20, predicted: -150) == .full)
        #expect(SheetStop.full.after(dragging: 20, predicted: 100) == .full)
    }

    /// Dragging the wrong way never changes the stop: there is nothing beyond full or below compact.
    @Test func wrongDirectionKeepsStop() {
        #expect(SheetStop.full.after(dragging: -200, predicted: -400) == .full)
        #expect(SheetStop.compact.after(dragging: 200, predicted: 400) == .compact)
    }

    /// From full the sheet follows the finger down (the map is behind it); every other direction is a
    /// quarter-rate rubber band so the bottom edge never lifts off the screen.
    @Test func offsetFollowsDownFromFullAndRubberBandsOtherwise() {
        #expect(SheetStop.full.offset(forDragging: 40) == 40)
        #expect(SheetStop.full.offset(forDragging: -40) == -10)
        #expect(SheetStop.compact.offset(forDragging: 40) == 10)
        #expect(SheetStop.compact.offset(forDragging: -40) == -10)
    }

    /// The stop the owner left the sheet at comes back on the next launch; nothing saved means full.
    @Test func savedStopRoundTrips() throws {
        let suite = "SheetStopTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SheetStop.saved(in: defaults) == .full)
        SheetStop.compact.save(to: defaults)
        #expect(SheetStop.saved(in: defaults) == .compact)
        defaults.set("sideways", forKey: SheetStop.defaultsKey)
        #expect(SheetStop.saved(in: defaults) == .full)
    }
}
