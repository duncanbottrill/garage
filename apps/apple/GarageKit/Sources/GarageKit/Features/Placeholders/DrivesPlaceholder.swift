import SwiftUI

/// The Drives tab until drive history lands.
public struct DrivesPlaceholder: View {
    public init() {}

    public var body: some View {
        EmptyState(icon: .route, title: "Drives", message: "Drives appear here once the car has moved with the bridge online")
    }
}
