#if os(iOS)
import SnapshotTesting
import UIKit

extension ViewImageConfig {
    /// iPhone 17 Pro in portrait at dark appearance: 402 × 874 pt at @3x, Dynamic Island safe area.
    /// swift-snapshot-testing 1.19 stops at the iPhone 13 family, so the device is described here.
    @MainActor static let iPhone17ProDark = ViewImageConfig(
        safeArea: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0),
        size: CGSize(width: 402, height: 874),
        traits: UITraitCollection { traits in
            traits.displayScale = 3
            traits.userInterfaceIdiom = .phone
            traits.horizontalSizeClass = .compact
            traits.verticalSizeClass = .regular
            traits.userInterfaceStyle = .dark
            traits.preferredContentSizeCategory = .large
        }
    )
}

/// The tolerances every Garage snapshot uses.
enum SnapshotTolerance {
    static let precision: Float = 0.98
    static let perceptualPrecision: Float = 0.98
}
#endif
