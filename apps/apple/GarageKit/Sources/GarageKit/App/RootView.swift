import SwiftUI

/// The app once onboarding is done: Status, Drives, Charges, Battery and More.
///
/// iPhone: the system iOS 26 glass tab bar (`TabView` with `Tab`), minimising as content scrolls down,
/// tinted with the accent. Mac: a `NavigationSplitView` whose sidebar (220–260 pt) lists the same five
/// destinations, with Status as the detail; Status draws its own two columns there (map left, panel
/// right, see ``StatusView``).
public struct RootView: View {
    /// The five destinations, in tab order.
    public enum Destination: String, CaseIterable, Hashable, Identifiable, Sendable {
        case status, drives, charges, battery, more

        public var id: String { rawValue }

        /// The tab or sidebar title.
        public var title: String {
            switch self {
            case .status: "Status"
            case .drives: "Drives"
            case .charges: "Charges"
            case .battery: "Battery"
            case .more: "More"
            }
        }

        /// The Lucide icon.
        public var icon: Icon.Name {
            switch self {
            case .status: .gauge
            case .drives: .route
            case .charges: .plugZap
            case .battery: .batteryCharging
            case .more: .settings
            }
        }
    }

    /// Tabs (iPhone) or sidebar (Mac). Snapshots render the Mac layout on the iOS simulator.
    enum Layout {
        case tabs, sidebar

        static var platform: Layout {
            #if os(iOS)
            .tabs
            #else
            .sidebar
            #endif
        }
    }

    private enum Source {
        case app(AppModel)
        /// Fixed screens for snapshots: no clock, no commands, no network.
        case fixed(status: StatusModel, more: MoreModel)
    }

    private let source: Source
    private let layout: Layout
    @State private var selection: Destination

    /// - Parameter model: The app model every screen reads from.
    public init(model: AppModel) {
        source = .app(model)
        layout = .platform
        _selection = State(initialValue: .status)
    }

    /// Fixed screens: Status on `status` (flat map), More on `more`, opening on `selection`.
    init(status: StatusModel, more: MoreModel, selection: Destination = .status, layout: Layout = .platform) {
        source = .fixed(status: status, more: more)
        self.layout = layout
        _selection = State(initialValue: selection)
    }

    public var body: some View {
        switch layout {
        case .tabs: tabs
        case .sidebar: sidebar
        }
    }

    // MARK: iPhone

    private var tabs: some View {
        TabView(selection: $selection) {
            ForEach(Destination.allCases) { destination in
                Tab(value: destination) {
                    screen(destination)
                } label: {
                    Label {
                        Text(destination.title)
                    } icon: {
                        // The system tab bar takes an `Image`; GarageKit's `Icon` wraps one in a frame.
                        Image(decorative: destination.icon.rawValue, bundle: .module)
                            .renderingMode(.template)
                    }
                }
            }
        }
        #if os(iOS)
        .tabBarMinimizeBehavior(.onScrollDown)
        #endif
        .tint(Tokens.Colors.accent)
    }

    // MARK: Mac

    private var sidebar: some View {
        NavigationSplitView {
            // Rows are drawn here rather than by the list's selection, so the selected one is the
            // accent tint on glass (as Status's active pills) on every platform, not the system highlight.
            List(Destination.allCases) { destination in
                SidebarRow(destination: destination, selected: destination == selection) {
                    selection = destination
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Tokens.Colors.background)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 260)
        } detail: {
            screen(selection)
        }
        .tint(Tokens.Colors.accent)
    }

    // MARK: Screens

    @ViewBuilder
    private func screen(_ destination: Destination) -> some View {
        switch destination {
        case .status:
            switch source {
            case let .app(model): StatusView(model: model)
            case let .fixed(status, _): StatusView(status: status, mapEnabled: false)
            }
        case .drives:
            DrivesPlaceholder()
        case .charges:
            ChargesPlaceholder()
        case .battery:
            BatteryPlaceholder()
        case .more:
            switch source {
            case let .app(model): MoreView(model: model)
            case let .fixed(_, more): MoreView(more: more)
            }
        }
    }
}

/// One sidebar destination: icon and body-scale title, in the accent on an accent-tinted capsule
/// while selected.
private struct SidebarRow: View {
    let destination: RootView.Destination
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Space.m) {
                Icon(destination.icon)
                Text(destination.title)
                    .garage(.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Tokens.Colors.accent : Tokens.Colors.ink)
            .padding(.horizontal, Tokens.Space.m)
            .frame(minHeight: 36)
            .background {
                if selected {
                    Capsule(style: .continuous).fill(Tokens.Colors.accent.opacity(Tokens.Opacity.accentFill))
                    Capsule(style: .continuous).strokeBorder(Tokens.Colors.accent.opacity(Tokens.Opacity.accentStroke), lineWidth: 1)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(DimWhenPressed())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
