import SwiftUI

/// The Status screen ("04 Hybrid"): the car on a dark map hero, with a glass sheet holding the state
/// of charge, the charge line, four tiles and the quick actions, and one banner pinned above it.
///
/// iPhone (narrow): the map fills the screen and the sheet is docked to the bottom edge, so about the
/// top half shows the map. Mac and wide windows: the map is full-bleed and the sheet floats as a
/// panel on the trailing side.
///
/// Commands go through ``AppModel/commandClient``. Lock/Unlock flips the lock icon at once
/// (optimistic, ``OptimisticLock``) and reverts with the error's copy in a toast if the command fails;
/// Frunk asks first.
public struct StatusView: View {
    /// Narrower than this, the sheet docks to the bottom; wider, it floats beside the map.
    /// 780 keeps the map at least 420 pt wide beside the widest (420 pt) panel and its margins.
    static let wideLayoutWidth: CGFloat = 780
    /// The least map the docked sheet leaves visible below the status bar when it grows.
    static let minimumMapHeight: CGFloat = 160
    /// How long a command toast stays up.
    static let toastDuration: Duration = .seconds(5)

    private enum Source {
        case app(AppModel)
        /// A fixed screen for snapshots and previews: no clock, no commands, no network.
        case fixed(StatusModel, trail: [TrailPoint], pending: Set<String>)
    }

    private enum Placeholder: String, Identifiable {
        case climate, charge
        var id: String { rawValue }
    }

    private let source: Source
    private let mapEnabled: Bool
    private let onOpenClimate: (() -> Void)?
    private let onOpenCharge: (() -> Void)?

    @State private var optimisticLock = OptimisticLock()
    @State private var toast: String?
    @State private var confirmingFrunk = false
    @State private var placeholder: Placeholder?
    @State private var trailLoader: TrailLoader?
    @Environment(\.openURL) private var openURL

    /// - Parameters:
    ///   - model: The app model: the vehicle store, the command client and the Supabase client (trail).
    ///   - mapEnabled: False draws a flat ground instead of MapKit (deterministic snapshots).
    ///   - onOpenClimate: Opens the Climate sheet. Until one is supplied, a placeholder sheet shows.
    ///   - onOpenCharge: Opens the Charge sheet. Until one is supplied, a placeholder sheet shows.
    public init(
        model: AppModel,
        mapEnabled: Bool = true,
        onOpenClimate: (() -> Void)? = nil,
        onOpenCharge: (() -> Void)? = nil
    ) {
        source = .app(model)
        self.mapEnabled = mapEnabled
        self.onOpenClimate = onOpenClimate
        self.onOpenCharge = onOpenCharge
    }

    /// A fixed screen: `status` as given, with the commands in `pending` drawn in flight. Animations are off.
    init(status: StatusModel, trail: [TrailPoint] = [], pending: Set<String> = [], mapEnabled: Bool = false) {
        source = .fixed(status, trail: trail, pending: pending)
        self.mapEnabled = mapEnabled
        onOpenClimate = nil
        onOpenCharge = nil
    }

    public var body: some View {
        content
            .alert("Open the frunk?", isPresented: $confirmingFrunk) {
                Button("Open frunk") { send(.actuateFrunk) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The lid pops up. Check nothing is resting on it.")
            }
            .sheet(item: $placeholder) { PlaceholderSheet(kind: $0) }
            .task(id: toast) {
                guard toast != nil else { return }
                try? await Task.sleep(for: Self.toastDuration)
                if !Task.isCancelled { toast = nil }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch source {
        case let .app(app):
            let store = app.vehicleStore
            TimelineView(.periodic(from: .now, by: 15)) { context in
                layout(
                    StatusModel(
                        state: store.state,
                        vehicle: store.vehicle,
                        now: context.date,
                        reachability: app.commandClient.reachability,
                        optimisticLocked: optimisticLock.target
                    ),
                    trail: trailLoader?.points ?? [],
                    pending: app.commandClient.pending,
                    actionsEnabled: store.vehicle != nil
                )
            }
            .task(id: store.vehicle?.id) { await loadTrail(app) }
            .onChange(of: store.state?.locationAt) { appendTrailPoint(store.state) }
            .onChange(of: store.state?.locked) { optimisticLock.rowChanged(locked: store.state?.locked) }
        case let .fixed(status, trail, pending):
            layout(status, trail: trail, pending: pending, actionsEnabled: true)
                .environment(\.statusMotion, false)
        }
    }

    // MARK: Layout

    private func layout(_ status: StatusModel, trail: [TrailPoint], pending: Set<String>, actionsEnabled: Bool) -> some View {
        GeometryReader { geometry in
            let actions = QuickActions.Actions(
                toggleLock: { toggleLock(status) },
                openClimate: { if let onOpenClimate { onOpenClimate() } else { placeholder = .climate } },
                openCharge: { if let onOpenCharge { onOpenCharge() } else { placeholder = .charge } },
                openFrunk: { confirmingFrunk = true }
            )
            if geometry.size.width >= Self.wideLayoutWidth {
                wide(status, trail: trail, pending: pending, actionsEnabled: actionsEnabled, actions: actions, size: geometry.size)
            } else {
                docked(status, trail: trail, pending: pending, actionsEnabled: actionsEnabled, actions: actions, size: geometry.size, safeArea: geometry.safeAreaInsets)
            }
        }
        .background(Tokens.Colors.background.ignoresSafeArea())
    }

    /// iPhone: map full-screen behind, sheet docked to the bottom edge, notices just above the sheet.
    private func docked(
        _ status: StatusModel, trail: [TrailPoint], pending: Set<String>, actionsEnabled: Bool,
        actions: QuickActions.Actions, size: CGSize, safeArea: EdgeInsets
    ) -> some View {
        // The sheet runs from the bottom edge; it may grow (then scroll) until this much map is left.
        let maxSheet = max(0, size.height + safeArea.bottom - Self.minimumMapHeight)
        return DockedStatusLayout(maxSheetHeight: maxSheet) { sheetHeight in
            CarMap(model: status, trail: trail, mapEnabled: mapEnabled, obscured: EdgeInsets(top: safeArea.top, leading: 0, bottom: sheetHeight, trailing: 0))
        } visible: {
            ZStack(alignment: .bottom) {
                flatCar(status)
                notices(status)
                    .padding(.horizontal, Tokens.Space.l)
                    .padding(.bottom, Tokens.Space.m)
            }
        } sheet: {
            StatusSheet(model: status, pending: pending, actionsEnabled: actionsEnabled, actions: actions, docked: true, bottomInset: safeArea.bottom)
        }
    }

    /// Mac and wide windows: map full-bleed, sheet as a floating panel on the trailing side.
    private func wide(
        _ status: StatusModel, trail: [TrailPoint], pending: Set<String>, actionsEnabled: Bool,
        actions: QuickActions.Actions, size: CGSize
    ) -> some View {
        let panel = min(420, max(320, size.width * 0.32))
        let covered = panel + Tokens.Space.xl * 2
        return ZStack(alignment: .topTrailing) {
            CarMap(model: status, trail: trail, mapEnabled: mapEnabled, obscured: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: covered))
                .ignoresSafeArea()
            flatCar(status)
                .padding(.trailing, covered)
            VStack(alignment: .leading, spacing: Tokens.Space.m) {
                notices(status)
                StatusSheet(model: status, pending: pending, actionsEnabled: actionsEnabled, actions: actions, docked: false)
                    .layoutPriority(1)
                Spacer(minLength: 0)
            }
            .frame(width: panel)
            .padding(Tokens.Space.xl)
        }
    }

    /// Without MapKit the layout places the car itself, centred in the visible map.
    @ViewBuilder
    private func flatCar(_ status: StatusModel) -> some View {
        if !mapEnabled, status.coordinate != nil {
            CarAnnotation(online: status.bridgeOnline, heading: status.heading, moving: status.isMoving)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The banner (at most one), then a command toast.
    private func notices(_ status: StatusModel) -> some View {
        VStack(spacing: Tokens.Space.s) {
            if let banner = status.banner, let message = status.bannerMessage {
                StatusBanner(banner: banner, message: message) {
                    openURL(TailscaleLink.destination(installed: TailscaleLink.isInstalled()))
                }
            }
            if let toast {
                NoticeStrip(icon: .circleAlert, tint: Tokens.Colors.danger, message: toast) { self.toast = nil }
                    .accessibilityHint("Dismisses the message")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: toast)
    }

    // MARK: Commands

    private func toggleLock(_ status: StatusModel) {
        guard case let .app(app) = source else { return }
        // One lock command at a time: a second tap while one is in flight would flip the icon back.
        let pending = app.commandClient.pending
        guard !pending.contains(Command.doorLock.name), !pending.contains(Command.doorUnlock.name) else { return }
        let target = status.lockState != .locked
        guard let intent = optimisticLock.begin(target: target) else { return }
        Task {
            switch await perform(target ? .doorLock : .doorUnlock) {
            case true?:
                await optimisticLock.sent(intent, rowLocked: app.vehicleStore.state?.locked)
            case false?, nil:
                // Failed (the toast says why), or the same command was already in flight.
                optimisticLock.failed(intent)
            }
        }
    }

    private func send(_ command: Command) {
        Task { _ = await perform(command) }
    }

    /// Sends a command; a failure is shown as a toast. Returns the client's result, or nil on failure.
    private func perform(_ command: Command) async -> Bool? {
        guard case let .app(app) = source else { return true }
        guard let vin = app.vehicleStore.vehicle?.vin else { return nil }
        do {
            return try await app.commandClient.send(command, vin: vin)
        } catch let error as CommandError {
            toast = error.errorDescription
        } catch is CancellationError {
            // The screen went away; nothing to tell.
        } catch {
            toast = error.localizedDescription
        }
        return nil
    }

    // MARK: Trail

    private func loadTrail(_ app: AppModel) async {
        guard let id = app.vehicleStore.vehicle?.id else {
            trailLoader = nil
            return
        }
        let loader = TrailLoader(fetcher: SupabaseTrailFetcher(client: app.client))
        trailLoader = loader
        await loader.load(vehicleID: id)
    }

    private func appendTrailPoint(_ state: VehicleState?) {
        guard let state, let lat = state.lat, let lng = state.lng, let at = state.locationAt else { return }
        trailLoader?.append(TrailPoint(latitude: lat, longitude: lng, recordedAt: at))
    }
}

/// Lays out the docked (iPhone) Status screen: the map behind everything, the visible part of the map
/// above the sheet (for notices and the flat-map car), and the sheet on the bottom edge. Measures the
/// sheet so the map can centre the car in what stays visible, and caps it at ``maxSheetHeight``.
private struct DockedStatusLayout<Map: View, Visible: View, Sheet: View>: View {
    /// The tallest the sheet may be before its content scrolls.
    let maxSheetHeight: CGFloat
    @ViewBuilder let map: (CGFloat) -> Map
    @ViewBuilder let visible: Visible
    @ViewBuilder let sheet: Sheet

    @State private var sheetHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            visible
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            HeightCap(maxHeight: maxSheetHeight) { sheet }
                // Sized before the map region, so it gets its whole height (up to the cap) first.
                .layoutPriority(1)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sheetHeight = $0 }
        }
        .ignoresSafeArea(edges: .bottom)
        .background { map(sheetHeight).ignoresSafeArea() }
    }
}

/// Offers its content at most `maxHeight` without growing to it (unlike `frame(maxHeight:)`, which
/// expands to the proposal): the sheet keeps its natural height, and only content taller than the
/// cap sees the cap, which is when ``StatusSheet`` switches to scrolling.
private struct HeightCap: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        return child.sizeThatFits(capped(proposal))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }

    private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
        ProposedViewSize(width: proposal.width, height: min(proposal.height ?? maxHeight, maxHeight))
    }
}

/// Stands in for the Climate and Charge sheets until they are wired in.
private struct PlaceholderSheet<Kind: RawRepresentable<String>>: View {
    let kind: Kind
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Tokens.Space.l) {
            Text(kind.rawValue.capitalized)
                .garage(.title)
                .foregroundStyle(Tokens.Colors.ink)
            Text("These controls arrive in the next build.")
                .garage(.body)
                .foregroundStyle(Tokens.Colors.muted)
            Button("Done") { dismiss() }
                .garageButtonFont()
        }
        .padding(Tokens.Space.xxl)
        .frame(minWidth: 320, minHeight: 200)
        .presentationDetents([.medium])
        .background(Tokens.Colors.background.ignoresSafeArea())
    }
}

private extension View {
    func garageButtonFont() -> some View {
        font(TypeScale.body.font).foregroundStyle(Tokens.Colors.accent)
    }
}
