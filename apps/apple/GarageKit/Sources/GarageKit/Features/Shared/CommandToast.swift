import SwiftUI

/// A command's error as a glass strip: the circle-alert icon in the danger colour and the
/// ``CommandError`` copy. Tapping it dismisses it; it also goes after ``duration``.
public struct CommandToast: View {
    /// How long a toast stays up.
    public static let duration: Duration = .seconds(5)

    private let message: String
    private let onDismiss: () -> Void

    /// - Parameters:
    ///   - message: The error copy.
    ///   - onDismiss: Clears the toast (tap).
    public init(message: String, onDismiss: @escaping () -> Void) {
        self.message = message
        self.onDismiss = onDismiss
    }

    public var body: some View {
        NoticeStrip(icon: .circleAlert, tint: Tokens.Colors.danger, message: message, action: onDismiss)
            .accessibilityHint("Dismisses the message")
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension View {
    /// Dismisses `runner`'s toast ``CommandToast/duration`` after it appears (unless a newer one has
    /// replaced it). Place the ``CommandToast`` itself where the surface wants it.
    func autoDismissingToast(_ runner: CommandRunner) -> some View {
        task(id: runner.toast?.id) {
            guard let id = runner.toast?.id else { return }
            try? await Task.sleep(for: CommandToast.duration)
            if !Task.isCancelled { runner.dismissToast(id: id) }
        }
    }
}
