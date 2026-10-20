import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Step 4: reach the home bridge over Tailscale. Commands go to the bridge's proxy on the tailnet,
/// so this device must be on the same tailnet as the bridge.
public struct TailscaleStep: View {
    private let proxyState: ProxyReachability.State
    private let isChecking: Bool
    private let tailscaleInstalled: Bool
    private let onOpenTailscale: () -> Void
    private let onCheckAgain: () -> Void

    /// - Parameters:
    ///   - proxyState: The last probe: `.unreachable` (Tailscale off or not set up) or `.unknown`
    ///     (the bridge has not published its address yet).
    ///   - isChecking: A probe is running.
    ///   - tailscaleInstalled: Whether the Tailscale app can be opened (names the button).
    ///   - onOpenTailscale: Opens Tailscale, or its App Store page (``TailscaleLink/destination(installed:)``).
    ///   - onCheckAgain: Probes the proxy again.
    public init(
        proxyState: ProxyReachability.State,
        isChecking: Bool,
        tailscaleInstalled: Bool,
        onOpenTailscale: @escaping () -> Void,
        onCheckAgain: @escaping () -> Void
    ) {
        self.proxyState = proxyState
        self.isChecking = isChecking
        self.tailscaleInstalled = tailscaleInstalled
        self.onOpenTailscale = onOpenTailscale
        self.onCheckAgain = onCheckAgain
    }

    public var body: some View {
        OnboardingStepLayout(
            step: .tailscale,
            title: "Reach your home bridge",
            message: "Install Tailscale and sign in with the same account as your home bridge.",
            errorMessage: nil
        ) {
            VStack(spacing: Tokens.Space.l) {
                OnboardingNotice(icon: .wifiOff, text: statusText, tint: Tokens.Colors.warning)
                Button(tailscaleInstalled ? "Open Tailscale" : "Get Tailscale", action: onOpenTailscale)
                    .onboarding(.primary)
                Button("Check again", action: onCheckAgain)
                    .onboarding(.secondary, isWorking: isChecking)
            }
        }
    }

    private var statusText: String {
        switch proxyState {
        case .unknown:
            "The bridge hasn't published its address yet. Check that the Garage add-on is running at home."
        case .unreachable, .reachable:
            "Garage can't reach the bridge from this device yet."
        }
    }
}

/// Where the Tailscale button goes.
public enum TailscaleLink {
    /// The Tailscale app's URL scheme (listed in `LSApplicationQueriesSchemes` on iOS).
    public static let app = URL(string: "tailscale://")!

    /// Tailscale on the App Store.
    public static var appStore: URL {
        #if os(iOS)
        URL(string: "https://apps.apple.com/app/id1470499037")!
        #else
        // The Mac App Store listing has its own id.
        URL(string: "https://apps.apple.com/app/id1475387142")!
        #endif
    }

    /// Whether the Tailscale app is installed and can be opened.
    @MainActor
    public static func isInstalled() -> Bool {
        #if os(iOS)
        UIApplication.shared.canOpenURL(app)
        #else
        NSWorkspace.shared.urlForApplication(toOpen: app) != nil
        #endif
    }

    /// The app when installed, its App Store page otherwise.
    public static func destination(installed: Bool) -> URL {
        installed ? app : appStore
    }
}
