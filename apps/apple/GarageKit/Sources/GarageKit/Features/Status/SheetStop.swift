import CoreGraphics
import Foundation

/// Where the docked (iPhone) Status sheet rests: `full` shows everything; `compact` keeps the hero
/// numeral, the charge line and the quick actions and gives the rest of the screen to the map. The
/// owner drags the sheet between the two; the stop they leave it at comes back on the next launch.
enum SheetStop: String, CaseIterable, Sendable {
    case compact, full

    /// The `UserDefaults` key holding the stop the owner last left the sheet at.
    static let defaultsKey = "statusSheetStop"
    /// A drag this far (points) moves the sheet to the other stop; shorter drags snap back.
    static let dragThreshold: CGFloat = 48
    /// A flick: a drag predicted to end this far counts even when the finger moved less than the threshold.
    static let flickThreshold: CGFloat = 120
    /// How much of the finger's travel the sheet follows when it cannot go that way.
    static let rubberBand: CGFloat = 0.25

    /// The stop after a drag of `translation` points (down positive) that the gesture predicts would
    /// end at `predicted`. Only the way towards the other stop counts.
    func after(dragging translation: CGFloat, predicted: CGFloat) -> SheetStop {
        let down = translation >= Self.dragThreshold || predicted >= Self.flickThreshold
        let up = translation <= -Self.dragThreshold || predicted <= -Self.flickThreshold
        switch self {
        case .full: return down ? .compact : .full
        case .compact: return up ? .full : .compact
        }
    }

    /// How far the sheet moves while the finger drags it `translation` points: all the way down from
    /// `full` (the map is behind it); otherwise a ``rubberBand`` fraction, so the bottom edge never
    /// lifts off the screen and nothing opens past full.
    func offset(forDragging translation: CGFloat) -> CGFloat {
        if self == .full, translation > 0 { return translation }
        return translation * Self.rubberBand
    }

    /// The stop saved in `defaults`, or `full` when nothing valid is saved.
    static func saved(in defaults: UserDefaults) -> SheetStop {
        defaults.string(forKey: defaultsKey).flatMap(SheetStop.init(rawValue:)) ?? .full
    }

    /// Remembers this stop in `defaults` for the next launch.
    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
