import SwiftUI

/// The More screen: a grouped list on the app background. Each group has a small-caps header and
/// its rows on one glass tile; a row is an icon, a title, a detail line and a trailing status dot
/// (healthy, warning, failed), with its controls under it.
///
/// Rows: Connection (with "Reconnect Tesla" when the token rotation failed), Bridge, Budget, Wake the
/// car (only while the car is asleep; "Wake" asks first, then sends one `wake_up`), Refresh
/// now (only while telemetry is stale and the car awake), Proxy URL (published value, editable
/// override, "Test"), Tailscale ("Open Tailscale"), Account ("Link Apple ID", "Sign out") and About
/// (version and licences). See ``MoreModel``.
public struct MoreView: View {
    /// What the buttons do. The app wires them to ``AppModel``; snapshots pass ``none``.
    struct Actions {
        var reconnectTesla: @MainActor () -> Void
        var linkApple: @MainActor () async throws -> Void
        var signOut: @MainActor () async -> Void

        static let none = Actions(reconnectTesla: {}, linkApple: {}, signOut: {})
    }

    private let app: AppModel?
    private let actions: Actions
    private let more: MoreModel
    @State private var tailscaleInstalled: Bool
    @State private var draft = ""
    @State private var draftRejected = false
    @State private var linking = false
    @State private var confirmingWake = false
    @State private var accountMessage: String?
    @State private var confirmingSignOut = false
    @State private var shownLicence: MoreModel.Licence?
    @Environment(\.openURL) private var openURL

    /// - Parameter model: The app model: backend, vehicle store, proxy reachability and account.
    public init(model: AppModel) {
        app = model
        more = model.moreModel
        _tailscaleInstalled = State(initialValue: false)
        actions = Actions(
            reconnectTesla: { [weak model] in model?.reconnectTesla() },
            linkApple: { [weak model] in try await model?.linkApple() },
            signOut: { [weak model] in await model?.signOut() }
        )
    }

    /// A fixed screen on `more` as given, for snapshots and previews.
    init(more: MoreModel, actions: Actions = .none, tailscaleInstalled: Bool = true) {
        app = nil
        self.actions = actions
        self.more = more
        _tailscaleInstalled = State(initialValue: tailscaleInstalled)
    }

    public var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                list
            }
            .padding(.horizontal, Tokens.Space.l)
            .padding(.vertical, Tokens.Space.xl)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .refreshable { await more.loadConnection() }
        .background(Tokens.Colors.background.ignoresSafeArea())
        .confirmationDialog("Sign out of Garage on this device?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await actions.signOut() } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(WakePrompt.title, isPresented: $confirmingWake, titleVisibility: .visible) {
            Button(WakePrompt.wakeButton) { Task { await more.wakeNow() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(WakePrompt.wakeOnlyMessage)
        }
        .sheet(item: $shownLicence) { LicenceSheet(licence: $0) }
        .modifier(LiveInputs(app: app, more: more))
        .task {
            if app != nil {
                tailscaleInstalled = TailscaleLink.isInstalled()
                await more.loadConnection()
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xxl) {
            Text("More")
                .garage(.title)
                .foregroundStyle(Tokens.Colors.ink)
                .accessibilityAddTraits(.isHeader)
            ForEach(more.sections) { section in
                VStack(alignment: .leading, spacing: Tokens.Space.s) {
                    SmallCapsLabel(section.title)
                        .padding(.horizontal, Tokens.Space.xs)
                        .accessibilityAddTraits(.isHeader)
                    VStack(spacing: 0) {
                        ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                            if index > 0 { Hairline().padding(.leading, MoreRowMetrics.textInset) }
                            VStack(alignment: .leading, spacing: Tokens.Space.m) {
                                MoreRow(row: row) { trailing(for: row) }
                                controls(for: row)
                                    .padding(.leading, MoreRowMetrics.textInset)
                            }
                            .padding(.horizontal, Tokens.Space.l)
                            .padding(.vertical, Tokens.Space.m)
                        }
                    }
                    .glassSurface(radius: Tokens.Radius.tile)
                }
            }
        }
    }

    // MARK: Row controls

    @ViewBuilder
    private func trailing(for row: MoreModel.Row) -> some View {
        if row.id == .refresh {
            MoreButton(title: "Refresh", isWorking: more.refreshPhase == .refreshing) {
                Task { await more.refreshNow() }
            }
        } else if row.id == .wake {
            MoreButton(title: WakePrompt.wakeButton, isWorking: more.wakePhase == .waking) { confirmingWake = true }
        } else {
            StatusDot(tone: row.tone)
        }
    }

    @ViewBuilder
    private func controls(for row: MoreModel.Row) -> some View {
        switch row.id {
        case .connection where more.showsReconnect:
            MoreButton(title: "Reconnect Tesla", action: actions.reconnectTesla)
        case .proxy:
            proxyControls
        case .tailscale:
            MoreButton(title: tailscaleInstalled ? "Open Tailscale" : "Get Tailscale", icon: .chevronRight) {
                openURL(TailscaleLink.destination(installed: TailscaleLink.isInstalled()))
            }
        case .account:
            accountControls
        case .about:
            licences
        default:
            EmptyView()
        }
    }

    private var proxyControls: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            if more.isUsingOverride {
                Text("Override in use · published: \(more.publishedProxyURL?.absoluteString ?? "none")")
                    .garage(.caption)
                    .foregroundStyle(Tokens.Colors.muted)
            }
            // A verbatim prompt: a localized key would turn the example URL into a blue link.
            TextField(
                text: $draft,
                prompt: Text(verbatim: "Override: https://garage-bridge.example.ts.net:4443").foregroundStyle(Tokens.Colors.muted)
            ) {
                Text("Proxy URL override")
            }
                .font(TypeScale.body.font)
                .foregroundStyle(Tokens.Colors.ink)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .textFieldStyle(.plain)
                .padding(.horizontal, Tokens.Space.m)
                .frame(minHeight: 44)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                        .strokeBorder(Color.white.opacity(Tokens.Opacity.hairline), lineWidth: 1)
                }
                .onSubmit(saveDraft)
                .accessibilityLabel("Proxy URL override")
            if draftRejected {
                Text("Use an https URL with a host name")
                    .garage(.caption)
                    .foregroundStyle(Tokens.Colors.danger)
            }
            HStack(spacing: Tokens.Space.s) {
                MoreButton(title: "Save", action: saveDraft)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                MoreButton(title: "Test", isWorking: more.proxyTest == .testing) {
                    Task { draftRejected = !(await more.testProxy(candidate: draft)) }
                }
                if more.isUsingOverride {
                    MoreButton(title: "Use published") {
                        draft = ""
                        draftRejected = false
                        more.clearProxyOverride()
                    }
                }
            }
            if let result = proxyTestText {
                Text(result.text)
                    .garage(.caption)
                    .foregroundStyle(result.color)
            }
        }
    }

    private var proxyTestText: (text: String, color: Color)? {
        guard case let .finished(state, url) = more.proxyTest else { return nil }
        let host = url?.host() ?? "the proxy"
        return switch state {
        case .reachable: ("Reachable: \(host) answered the handshake", Tokens.Colors.charging)
        case .unreachable: ("Unreachable: \(host). Check Tailscale and the bridge", Tokens.Colors.danger)
        case .unknown: ("No proxy URL to test yet", Tokens.Colors.muted)
        }
    }

    private func saveDraft() {
        if more.saveProxyOverride(draft) {
            draftRejected = false
            draft = ""
        } else {
            draftRejected = true
        }
    }

    private var accountControls: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.s) {
            if let accountMessage {
                Text(accountMessage)
                    .garage(.caption)
                    .foregroundStyle(Tokens.Colors.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Tokens.Space.s) {
                if !more.hasAppleIdentity {
                    MoreButton(title: "Link Apple ID", isWorking: linking) {
                        Task { await linkApple() }
                    }
                }
                MoreButton(title: "Sign out", tint: Tokens.Colors.danger) { confirmingSignOut = true }
            }
        }
    }

    private func linkApple() async {
        linking = true
        defer { linking = false }
        do {
            try await actions.linkApple()
            accountMessage = nil
        } catch {
            if !AppleCredential.isCancellation(error) { accountMessage = OnboardingFlow.message(for: error) }
        }
    }

    private var licences: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.xs) {
            ForEach(MoreModel.licences) { item in
                Button { shownLicence = item } label: {
                    HStack(spacing: Tokens.Space.s) {
                        Text(item.name)
                            .garage(.caption)
                            .foregroundStyle(Tokens.Colors.ink)
                        Spacer(minLength: Tokens.Space.s)
                        Text(item.licence)
                            .garage(.caption)
                            .foregroundStyle(Tokens.Colors.muted)
                        Icon(.chevronRight, size: 12)
                            .foregroundStyle(Tokens.Colors.muted)
                            .opacity(item.file == nil ? 0 : 1)
                    }
                    .frame(minHeight: 28)
                    .contentShape(.rect)
                }
                .buttonStyle(DimWhenPressed())
                .disabled(item.file == nil)
                .accessibilityElement(children: .combine)
                .accessibilityHint(item.file == nil ? "" : "Shows the licence text")
            }
        }
    }
}

/// A bundled licence notice, in full, on the app background.
private struct LicenceSheet: View {
    let licence: MoreModel.Licence

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.l) {
            HStack {
                SmallCapsLabel("\(licence.name) · \(licence.licence)")
                Spacer(minLength: Tokens.Space.s)
                GlassIconButton(icon: .x, accessibilityLabel: "Close") { dismiss() }
            }
            ScrollView {
                Text(verbatim: licence.text ?? "")
                    .garage(.caption)
                    .foregroundStyle(Tokens.Colors.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(Tokens.Space.xl)
        .background(Tokens.Colors.background.ignoresSafeArea())
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 480, idealHeight: 600)
        #endif
    }
}

/// Keeps the model's inputs in step with the app: the car, its row, the proxy and the account.
private struct LiveInputs: ViewModifier {
    let app: AppModel?
    let more: MoreModel

    func body(content: Content) -> some View {
        if let app {
            content
                .onChange(of: app.vehicleStore.state, initial: true) { more.state = app.vehicleStore.state }
                .onChange(of: app.vehicleStore.vehicle, initial: true) { more.vehicle = app.vehicleStore.vehicle }
                .onChange(of: app.commandClient.reachability, initial: true) { more.reachability = app.commandClient.reachability }
                .onChange(of: app.accountEmail, initial: true) { more.accountEmail = app.accountEmail }
                .onChange(of: app.hasAppleIdentity, initial: true) { more.hasAppleIdentity = app.hasAppleIdentity }
        } else {
            content
        }
    }
}

/// One More row: a muted icon, a body-scale title over a caption detail (red when failed), and the
/// trailing state.
struct MoreRow<Trailing: View>: View {
    let row: MoreModel.Row
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Space.m) {
            Icon(row.icon)
                .foregroundStyle(Tokens.Colors.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .garage(.body)
                    .foregroundStyle(Tokens.Colors.ink)
                Text(row.detail)
                    .garage(.caption)
                    .foregroundStyle(row.tone == .failed ? Tokens.Colors.danger : Tokens.Colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Tokens.Space.s)
            trailing
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityValue(row.tone.accessibilityText)
    }
}

enum MoreRowMetrics {
    /// Where a row's title starts: the icon's width plus the gap, so hairlines and controls line up with it.
    static let textInset: CGFloat = Icon.strokeTrueSize + Tokens.Space.m
}

/// The trailing status dot: green healthy, amber warning, red failed; nothing when neutral.
struct StatusDot: View {
    let tone: MoreModel.Row.Tone

    var body: some View {
        if let color = tone.color {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        }
    }
}

extension MoreModel.Row.Tone {
    /// The status colour, or nil for neutral.
    var color: Color? {
        switch self {
        case .healthy: Tokens.Colors.charging
        case .warning: Tokens.Colors.warning
        case .failed: Tokens.Colors.danger
        case .neutral: nil
        }
    }

    var accessibilityText: String {
        switch self {
        case .healthy: "OK"
        case .warning: "Warning"
        case .failed: "Needs attention"
        case .neutral: ""
        }
    }
}

/// A small action in a More row: a glass capsule with a body-scale label in the accent (or `tint`),
/// 36 pt tall inside a 44 pt target, with a spinner while `isWorking`.
struct MoreButton: View {
    let title: String
    var icon: Icon.Name?
    var tint: Color = Tokens.Colors.accent
    var isWorking = false
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.xs) {
                Text(title)
                    .garage(.body)
                    .lineLimit(1)
                if let icon { Icon(icon, size: 14) }
            }
            .opacity(isWorking ? 0 : 1)
            .overlay {
                if isWorking { ProgressView().controlSize(.small).tint(tint) }
            }
            .foregroundStyle(tint)
            .padding(.horizontal, Tokens.Space.m)
            .frame(minHeight: 36)
            .glassCapsule()
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(DimWhenPressed())
        .disabled(isWorking)
        .opacity(isEnabled ? 1 : 0.45)
    }
}
