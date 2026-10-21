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
    /// The message for More's "Wake the car", where no command follows.
    static let wakeOnlyMessage = "Waking it costs a Tesla wake credit and starts live updates. Wake it?"
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
                Self.buttons(runner)
            } message: {
                Text(Self.message)
            }
            .modifier(WakePromptHost(runner: runner))
    }

    /// Cancel and Wake, for a surface that folds the prompt into its own alert (Status).
    @ViewBuilder
    static func buttons(_ runner: CommandRunner) -> some View {
        Button("Cancel", role: .cancel) { runner.cancelWake() }
        Button(wakeButton) { runner.confirmWake() }
    }
}

/// Marks `runner`'s prompt as shown by this surface while it is on screen, and cancels a waiting
/// prompt when it goes away.
struct WakePromptHost: ViewModifier {
    let runner: CommandRunner

    func body(content: Content) -> some View {
        content
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
