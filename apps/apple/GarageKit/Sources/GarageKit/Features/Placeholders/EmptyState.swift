import SwiftUI

/// A designed empty state for a tab whose data has not arrived yet: a 32 pt muted icon, a
/// title-scale heading and one muted line of body copy, centred on the app background.
struct EmptyState: View {
    let icon: Icon.Name
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Tokens.Space.m) {
            Icon(icon, size: 32)
                .foregroundStyle(Tokens.Colors.muted)
                .padding(.bottom, Tokens.Space.xs)
            Text(title)
                .garage(.title)
                .foregroundStyle(Tokens.Colors.ink)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .garage(.body)
                .foregroundStyle(Tokens.Colors.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 320)
        .padding(.horizontal, Tokens.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Colors.background.ignoresSafeArea())
        .accessibilityElement(children: .combine)
    }
}
