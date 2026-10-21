import SwiftUI

/// The Status screen ("04 Hybrid"): the car on a dark map hero, with a glass sheet holding the state
/// of charge, the charge line, four tiles and the quick actions, and one banner pinned above it.
///
/// iPhone (narrow): the map fills the screen and the sheet is docked to the bottom edge, so about the
/// top half shows the map. The sheet has two stops (``SheetStop``): drag it down to `compact` (hero
/// numeral, charge line and quick actions) for more map, up to `full` for the tiles too; the stop is
/// remembered. Mac and wide windows: the map is full-bleed and the sheet floats as a panel on the
/// trailing side.
///
/// Commands go through ``AppModel/commandClient`` via a ``CommandRunner``, so an asleep car gets the
/// ``WakePrompt`` first and failures show a ``CommandToast``. Lock/Unlock flips the lock icon at once
/// (optimistic, ``OptimisticLock``) and reverts if the command fails; Frunk asks first.
///
/// The Climate and Charge pills present ``ClimateSheet`` and ``ChargeSheet`` (`.sheet(item:)`), whose
/// models live as long as this view so the sheets keep what they last sent; pass `onOpenClimate` or
/// `onOpenCharge` to handle a pill elsewhere instead.
public struct StatusView: View {
    /// Narrower than this, the sheet docks to the bottom; wider, it floats beside the map.
    /// 780 keeps the map at least 420 pt wide beside the widest (420 pt) panel and its margins.
    static let wideLayoutWidth: CGFloat = 780
    /// The least map the docked sheet leaves visible below the status bar when it grows.
    static let minimumMapHeight: CGFloat = 160

    private enum Source {
        case app(AppModel)
        /// A fixed screen for snapshots and previews: no clock, no commands, no network.
        case fixed(StatusModel, trail: [TrailPoint], pending: Set<String>)
    }

    /// Status's one alert: the frunk confirmation, then (if the car is asleep) the wake prompt. One
    /// `.alert` presents both, so the second waits for the first to go instead of being dropped.
    private enum StatusAlert {
        case frunk, wake
    }

    private enum ControlSheetKind: String, Identifiable {
        case climate, charge
        var id: String { rawValue }
    }

    private let source: Source
    /// `nil` for a fixed screen: the stop is shown as given and never saved.
    private let stopDefaults: UserDefaults?
    private let mapEnabled: Bool
    private let onOpenClimate: (() -> Void)?
    private let onOpenCharge: (() -> Void)?

    @State private var optimisticLock = OptimisticLock()
    @State private var runner: CommandRunner
    /// Where the docked sheet rests (iPhone); the Mac panel is always full.
    @State private var sheetStop: SheetStop
    /// How far the finger has dragged the docked sheet from its stop, in points.
    @State private var sheetDrag: CGFloat = 0
    @State private var confirmingFrunk = false
    @State private var presentedSheet: ControlSheetKind?
    @State private var climate: ClimateModel?
    @State private var charge: ChargeModel?
    @State private var trailLoader: TrailLoader?
    @Environment(\.openURL) private var openURL

    /// - Parameters:
    ///   - model: The app model: the vehicle store, the command client and the Supabase client (trail).
    ///   - mapEnabled: False draws a flat ground instead of MapKit (deterministic snapshots).
    ///   - onOpenClimate: Replaces the Climate pill's action; by default it presents ``ClimateSheet``.
    ///   - onOpenCharge: Replaces the Charge pill's action; by default it presents ``ChargeSheet``.
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
        let commands = Self.commands(model)
        let runner = CommandRunner(send: commands.send, wake: commands.wake, awaitAwake: commands.awaitAwake)
        runner.isAsleep = { [weak model] in model?.vehicleStore.state?.sleepState?.lowercased() == "asleep" }
        _runner = State(initialValue: runner)
        stopDefaults = .standard
        _sheetStop = State(initialValue: SheetStop.saved(in: .standard))
    }

    /// A fixed screen: `status` as given, with the commands in `pending` drawn in flight and the docked
    /// sheet at `sheetStop`. Animations are off.
    init(status: StatusModel, trail: [TrailPoint] = [], pending: Set<String> = [], mapEnabled: Bool = false, sheetStop: SheetStop = .full) {
        source = .fixed(status, trail: trail, pending: pending)
        self.mapEnabled = mapEnabled
        onOpenClimate = nil
        onOpenCharge = nil
        _runner = State(initialValue: CommandRunner(send: { _ in true }, wake: { true }))
        stopDefaults = nil
        _sheetStop = State(initialValue: sheetStop)
    }

    public var body: some View {
        content
            .alert(alertTitle, isPresented: alertShown) {
                switch activeAlert {
                case .frunk:
                    Button("Open frunk") {
                        confirmingFrunk = false
                        openFrunk()
                    }
                    Button("Cancel", role: .cancel) { confirmingFrunk = false }
                case .wake:
                    WakePrompt.buttons(runner)
                case nil:
                    EmptyView()
                }
            } message: {
                switch activeAlert {
                case .frunk: Text("The lid pops up. Check nothing is resting on it.")
                case .wake: Text(WakePrompt.message)
                case nil: EmptyView()
                }
            }
            .modifier(WakePromptHost(runner: runner))
            .autoDismissingToast(runner)
            .sheet(item: $presentedSheet) { controlSheet($0) }
            // A sheet over Status hides Status's wake prompt: its commands that need a wake are
            // declined rather than left waiting for a prompt nobody can see.
            .onChange(of: presentedSheet, initial: true) { runner.isCovered = presentedSheet != nil }
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
                    pending: app.commandClient.pending.union(runner.pending),
                    actionsEnabled: store.vehicle != nil
                )
            }
            .task(id: store.vehicle?.id) { await loadTrail(app) }
            .onChange(of: store.vehicle?.id) {
                // A different car: the sheets' remembered target, seats and schedule belong to the old
                // one. Close any open sheet first so it never renders without its model.
                presentedSheet = nil
                climate = nil
                charge = nil
            }
            .onChange(of: store.state?.locationAt) { appendTrailPoint(store.state) }
            .onChange(of: store.state?.locked) { optimisticLock.rowChanged(locked: store.state?.locked) }
        case let .fixed(status, trail, pending):
            layout(status, trail: trail, pending: pending, actionsEnabled: true)
                .environment(\.statusMotion, false)
        }
    }

    // MARK: Layout

    /// `actionsEnabled`: a car is linked to send to; the proxy rule (``StatusModel/quickActionsEnabled``)
    /// is applied here on top.
    private func layout(_ status: StatusModel, trail: [TrailPoint], pending: Set<String>, actionsEnabled linked: Bool) -> some View {
        let actionsEnabled = linked && status.quickActionsEnabled
        return GeometryReader { geometry in
            let actions = QuickActions.Actions(
                toggleLock: { toggleLock(status) },
                openClimate: { if let onOpenClimate { onOpenClimate() } else { present(.climate) } },
                openCharge: { if let onOpenCharge { onOpenCharge() } else { present(.charge) } },
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
            StatusSheet(
                model: status, pending: pending, actionsEnabled: actionsEnabled, actions: actions,
                docked: true, stop: sheetStop, bottomInset: safeArea.bottom,
                onToggleStop: { move(to: sheetStop == .full ? .compact : .full) }
            )
            .offset(y: sheetDrag)
            .gesture(sheetDragGesture)
        }
    }

    // MARK: Sheet stops

    /// Dragging the docked sheet: it follows the finger (``SheetStop/offset(forDragging:)``), then snaps
    /// to the stop the drag ends at (``SheetStop/after(dragging:predicted:)``).
    private var sheetDragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { sheetDrag = sheetStop.offset(forDragging: $0.translation.height) }
            .onEnded { value in
                let next = sheetStop.after(dragging: value.translation.height, predicted: value.predictedEndTranslation.height)
                withAnimation(.snappy) {
                    sheetDrag = 0
                    move(to: next)
                }
            }
    }

    /// Rests the docked sheet at `stop` and remembers it for the next launch.
    private func move(to stop: SheetStop) {
        guard stop != sheetStop else { return }
        withAnimation(.snappy) { sheetStop = stop }
        if let stopDefaults { stop.save(to: stopDefaults) }
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
            if let toast = runner.toast {
                CommandToast(message: toast.message) { runner.dismissToast() }
            }
        }
        .animation(.snappy, value: runner.toast)
    }

    // MARK: Commands

    private func toggleLock(_ status: StatusModel) {
        guard case let .app(app) = source else { return }
        // One lock command at a time: a second tap while one is in flight would flip the icon back.
        let pending = app.commandClient.pending.union(runner.pending)
        guard !pending.contains(Command.doorLock.name), !pending.contains(Command.doorUnlock.name) else { return }
        let target = status.lockState != .locked
        Task {
            await optimisticLock.toggle(to: target, with: runner) { app.vehicleStore.state?.locked }
        }
    }

    private var activeAlert: StatusAlert? {
        if confirmingFrunk { return .frunk }
        return runner.isAskingToWake ? .wake : nil
    }

    private var alertTitle: String {
        activeAlert == .wake ? WakePrompt.title : "Open the frunk?"
    }

    /// Dismissal goes through the buttons, which clear the frunk flag or answer the prompt.
    private var alertShown: Binding<Bool> {
        Binding(get: { activeAlert != nil }, set: { _ in })
    }

    private func openFrunk() {
        guard case .app = source else { return }
        Task { await runner.run(.actuateFrunk) }
    }

    /// `send`, `wake` and `awaitAwake` for the app's car, read at call time (the client is replaced on sign-out).
    private static func commands(_ app: AppModel) -> (send: CommandRunner.Send, wake: CommandRunner.Wake, awaitAwake: CommandRunner.AwaitAwake) {
        let send: CommandRunner.Send = { [weak app] command in
            guard let app, let vin = app.vehicleStore.vehicle?.vin else { throw CommandError.unreachable }
            return try await app.commandClient.send(command, vin: vin)
        }
        let wake: CommandRunner.Wake = { [weak app] in
            guard let app, let vin = app.vehicleStore.vehicle?.vin else { throw CommandError.unreachable }
            return try await app.commandClient.wake(vin: vin)
        }
        let awaitAwake: CommandRunner.AwaitAwake = { [weak app] in
            await app?.vehicleStore.waitUntilAwake(timeout: CommandRunner.onlineWait) ?? true
        }
        return (send, wake, awaitAwake)
    }

    // MARK: Sheets

    private func present(_ kind: ControlSheetKind) {
        guard case let .app(app) = source else { return }
        let commands = Self.commands(app)
        switch kind {
        case .climate where climate == nil:
            climate = ClimateModel(send: commands.send, wake: commands.wake, awaitAwake: commands.awaitAwake)
        case .charge where charge == nil:
            charge = ChargeModel(send: commands.send, wake: commands.wake, awaitAwake: commands.awaitAwake)
        default:
            break
        }
        presentedSheet = kind
    }

    @ViewBuilder
    private func controlSheet(_ kind: ControlSheetKind) -> some View {
        if case let .app(app) = source {
            switch kind {
            case .climate:
                if let climate {
                    ClimateSheet(model: climate)
                        .modifier(LiveCar(app: app) { climate.state = $0; climate.reachability = $1 })
                }
            case .charge:
                if let charge {
                    ChargeSheet(model: charge)
                        .modifier(LiveCar(app: app) { charge.state = $0; charge.reachability = $1 })
                }
            }
        }
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
        // A parked car sends no new positions, so the window is also enforced on a timer.
        while !Task.isCancelled {
            try? await Task.sleep(for: TrailLoader.pruneInterval)
            loader.prune()
        }
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

/// Keeps a sheet model's row and reachability current while the sheet is up.
private struct LiveCar: ViewModifier {
    let app: AppModel
    let apply: (VehicleState?, ProxyReachability.State) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: app.vehicleStore.state, initial: true) { apply(app.vehicleStore.state, app.commandClient.reachability) }
            .onChange(of: app.commandClient.reachability) { apply(app.vehicleStore.state, app.commandClient.reachability) }
    }
}
