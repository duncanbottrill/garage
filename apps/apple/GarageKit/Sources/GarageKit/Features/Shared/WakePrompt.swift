import SwiftUI

/// The confirmation shown before Garage wakes the car: "The car is asleep" with Cancel and Wake.
///
/// Attach it to the surface that sends through `runner` with ``SwiftUI/View/wakePrompt(_:)``. While
/// attached and on screen, the runner may ask; the Wake button is the only path to `wake_up`.
struct WakePrompt: ViewModifier {
    /// The alert title.
    static let title = "The car is asleep"
    /// The alert message.
    static let message = "Waking it costs a Tesla wake credit. Wake and send?"
    /// The confirming button.
    static let wakeButton = "Wake"

    let runner: CommandRunner

    func body(content: Content) -> some View {
        content
            .alert(
                Self.title,
                // Dismissal goes through the buttons; the setter must not race them.
                isPresented: Binding(get: { runner.isAskingToWake }, set: { _ in })
            ) {
                Button("Cancel", role: .cancel) { runner.cancelWake() }
                Button(Self.wakeButton) { runner.confirmWake() }
            } message: {
                Text(Self.message)
            }
            .onAppear { runner.hostsPrompt = true }
            .onDisappear {
                runner.hostsPrompt = false
                runner.cancelWake()
            }
    }
}

extension View {
    /// Asks before waking the car for `runner`'s commands. See ``CommandRunner``.
    public func wakePrompt(_ runner: CommandRunner) -> some View {
        modifier(WakePrompt(runner: runner))
    }
}
