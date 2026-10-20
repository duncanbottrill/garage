import SwiftUI

/// The Battery tab until there is enough history for battery insight.
public struct BatteryPlaceholder: View {
    public init() {}

    public var body: some View {
        EmptyState(icon: .batteryCharging, title: "Battery", message: "Battery insight needs a few weeks of history. It will appear here.")
    }
}
