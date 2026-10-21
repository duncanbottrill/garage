import SwiftUI

/// A designed empty state for a tab whose data has not arrived yet: a 32 pt muted icon, a
/// title-scale heading and one muted line of body copy, centred on the app background.
///
/// The content sits in a `GeometryReader` so the screen's ideal height is not the content's. As the
/// detail of the Mac `NavigationSplitView`, a view whose ideal height comes from its content shifts
/// the sidebar list up by about that height (macOS 26), hiding the top rows under the title bar;
/// `StatusView` (a `GeometryReader`) and `MoreView` (a `ScrollView`) avoid it the same way.
struct EmptyState: View {
    let icon: Icon.Name
    let title: String
    let message: String

    var body: some View {
        GeometryReader { _ in
            content
        }
        .background(Tokens.Colors.background.ignoresSafeArea())
        .accessibilityElement(children: .combine)
    }

    private var content: some View {
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
    }
}
