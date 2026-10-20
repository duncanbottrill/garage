import SwiftUI

/// The Charges tab until charging history lands.
public struct ChargesPlaceholder: View {
    public init() {}

    public var body: some View {
        EmptyState(icon: .plugZap, title: "Charges", message: "Charging sessions appear here after the first charge with the bridge online")
    }
}
