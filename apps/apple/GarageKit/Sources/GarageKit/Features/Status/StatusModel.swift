import Foundation

/// Everything the Status screen shows, derived from the car's row, the vehicle, the clock and the
/// proxy's reachability. A plain value with no views or I/O, so every rule is testable on its own.
///
/// Missing values read as ``placeholder`` ("—"): a young row carries only a few fields, and the screen
/// must never show a zero it was not told.
public struct StatusModel: Sendable, Equatable {
    /// Shown wherever a value has not been reported.
    public static let placeholder = "—"

    /// The lock reading, after any optimistic overlay.
    public enum LockState: Sendable, Equatable {
        case locked, unlocked, unknown
    }

    /// The one banner pinned above the sheet. Priority: ``telemetryPaused(since:)`` over ``budget(_:)``
    /// over ``tailscaleOff``.
    public enum Banner: Sendable, Equatable {
        /// The bridge has not checked in for over 90 s; `since` is its last check-in, when known.
        case telemetryPaused(since: Date?)
        /// The backend is spending less of the Tesla budget (`.reduced` or `.minimal`).
        case budget(BudgetMode)
        /// The bridge's command proxy cannot be reached (Tailscale off or not on the tailnet).
        case tailscaleOff
    }

    /// A group of fields that share one `*_at` timestamp.
    public enum Field: Sendable, CaseIterable {
        /// `charge_at`: SoC, range, charge state, power, limit, port.
        case charge
        /// `climate_at`: inside and outside temperatures, HVAC.
        case climate
        /// `location_at`: position, heading, speed.
        case location
        /// `body_at`: locks, doors, windows, trunks.
        case body
    }

    /// The row this was built from (nil before the bridge has written one).
    public let state: VehicleState?
    /// The clock the freshness and schedule rules were evaluated against.
    public let now: Date

    /// State of charge, whole percent, or nil.
    public let soc: Double?
    /// `socText`: "34", or "—".
    public let socText: String
    /// Range in the locale's unit, rounded, or nil.
    public let range: Double?
    /// "182", or "—".
    public let rangeText: String
    /// "mi" or "km", for the locale.
    public let rangeUnit: String
    /// "Not charging", "Charging 7.2 kW · 90 % limit", "Scheduled 23:30", or "—" when nothing is known.
    public let chargeLine: String
    /// Inside temperature in the locale's unit, rounded, or nil.
    public let inside: Double?
    /// Outside temperature in the locale's unit, rounded, or nil.
    public let outside: Double?
    /// "°C" or "°F", for the locale.
    public let temperatureUnit: String
    /// "21 °C", or "—".
    public let insideText: String
    /// "12 °C", or "—".
    public let outsideText: String
    /// Locked, unlocked or unknown; ``optimisticLocked`` wins over the row while a command is pending.
    public let lockState: LockState
    /// "Locked", "Unlocked", or "—".
    public let lockLabel: String
    /// Whether the charge port is open, or nil.
    public let chargePortOpen: Bool?
    /// "Open", "Closed", or "—".
    public let chargePortText: String
    /// The bridge checked in within the last 90 s.
    public let bridgeOnline: Bool
    /// The banner to show, or nil.
    public let banner: Banner?
    /// The banner's one line of copy, or nil.
    public let bannerMessage: String?
    /// Offer "Refresh now" (in More): the newest telemetry is older than 10 min and the car is not asleep.
    public let showsRefreshNow: Bool
    /// The car's position, when reported.
    public let coordinate: Coordinate?
    /// Degrees clockwise from north, when reported.
    public let heading: Double?
    /// The car is moving (`speed_kph > 0`).
    public let isMoving: Bool

    private let timeZone: TimeZone

    /// A latitude/longitude pair (kept free of CoreLocation so the model stays a plain value).
    public struct Coordinate: Sendable, Equatable {
        /// Degrees north.
        public let latitude: Double
        /// Degrees east.
        public let longitude: Double

        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    /// - Parameters:
    ///   - state: The car's latest row, or nil.
    ///   - vehicle: The car (budget mode), or nil.
    ///   - now: The clock for freshness, schedules and the bridge window.
    ///   - reachability: The proxy probe's last result.
    ///   - optimisticLocked: The lock state a pending lock/unlock command is heading for; wins over the row.
    ///   - locale: Picks miles or kilometres and °C or °F (``Units``).
    ///   - timeZone: For clock times ("Scheduled 23:30", "Stale · 14:02").
    public init(
        state: VehicleState?,
        vehicle: Vehicle?,
        now: Date,
        reachability: ProxyReachability.State,
        optimisticLocked: Bool? = nil,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) {
        let dash = Self.placeholder
        self.state = state
        self.now = now
        self.timeZone = timeZone

        soc = state?.soc.map { $0.rounded() }
        socText = soc.map { String(Int($0)) } ?? dash

        let distance = Units.distance(km: 1, locale: locale)
        rangeUnit = distance.unit == .miles ? "mi" : "km"
        range = state?.rangeKm.map { Units.distance(km: $0, locale: locale).value.rounded() }
        rangeText = range.map { String(Int($0)) } ?? dash

        temperatureUnit = Units.temperature(c: 0, locale: locale).unit == .fahrenheit ? "°F" : "°C"
        inside = state?.insideC.map { Units.temperature(c: $0, locale: locale).value.rounded() }
        outside = state?.outsideC.map { Units.temperature(c: $0, locale: locale).value.rounded() }
        let unit = temperatureUnit
        insideText = inside.map { "\(Int($0)) \(unit)" } ?? dash
        outsideText = outside.map { "\(Int($0)) \(unit)" } ?? dash

        chargeLine = Self.chargeLine(state, now: now, timeZone: timeZone)

        switch optimisticLocked ?? state?.locked {
        case true?: lockState = .locked
        case false?: lockState = .unlocked
        case nil: lockState = .unknown
        }
        lockLabel = switch lockState {
        case .locked: "Locked"
        case .unlocked: "Unlocked"
        case .unknown: dash
        }

        chargePortOpen = state?.chargePortOpen
        chargePortText = chargePortOpen.map { $0 ? "Open" : "Closed" } ?? dash

        bridgeOnline = Freshness.bridge(seenAt: state?.bridgeSeenAt, now: now)
        banner = Self.banner(state: state, bridgeOnline: bridgeOnline, vehicle: vehicle, reachability: reachability)
        bannerMessage = banner.map { Self.message(for: $0, timeZone: timeZone) }

        let newest = [state?.chargeAt, state?.climateAt, state?.locationAt, state?.bodyAt].compactMap { $0 }.max()
        let asleep = state?.sleepState?.lowercased() == "asleep"
        if state != nil, !asleep, case .stale = Freshness.of(newest, now: now) {
            showsRefreshNow = true
        } else {
            // No telemetry at all (`.unknown`) is a young row, not an old one: nothing to refresh yet.
            showsRefreshNow = false
        }

        if let lat = state?.lat, let lng = state?.lng {
            coordinate = Coordinate(latitude: lat, longitude: lng)
        } else {
            coordinate = nil
        }
        heading = state?.heading
        isMoving = (state?.speedKph ?? 0) > 0
    }

    /// How recent a field group is.
    public func fieldFreshness(_ field: Field) -> Freshness {
        Freshness.of(stamp(field), now: now)
    }

    /// "now" (live), "2 min ago" (aging), "Stale · 14:02" (stale), or "—" (never reported).
    public func freshnessCaption(_ field: Field) -> String {
        switch fieldFreshness(field) {
        case .live:
            "now"
        case let .aging(age):
            "\(max(1, Int(age / 60))) min ago"
        case .stale:
            stamp(field).map { "Stale · \(CommandError.clockTime($0, timeZone: timeZone))" } ?? Self.placeholder
        case .unknown:
            Self.placeholder
        }
    }

    private func stamp(_ field: Field) -> Date? {
        switch field {
        case .charge: state?.chargeAt
        case .climate: state?.climateAt
        case .location: state?.locationAt
        case .body: state?.bodyAt
        }
    }

    private static func chargeLine(_ state: VehicleState?, now: Date, timeZone: TimeZone) -> String {
        guard let state else { return placeholder }
        if state.chargeState?.lowercased() == "charging" {
            var line = "Charging"
            if let power = state.chargerPowerKw {
                line += " " + power.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US_POSIX"))) + " kW"
            }
            if let limit = state.chargeLimitSoc { line += " · \(limit) % limit" }
            return line
        }
        if let scheduled = state.scheduledChargeAt, scheduled > now {
            return "Scheduled \(CommandError.clockTime(scheduled, timeZone: timeZone))"
        }
        return state.chargeState == nil ? placeholder : "Not charging"
    }

    private static func banner(state: VehicleState?, bridgeOnline: Bool, vehicle: Vehicle?, reachability: ProxyReachability.State) -> Banner? {
        // Before the bridge has written a row there is nothing paused, only nothing yet.
        if let state, !bridgeOnline { return .telemetryPaused(since: state.bridgeSeenAt) }
        if let mode = vehicle?.budgetMode, mode != .normal { return .budget(mode) }
        if reachability == .unreachable { return .tailscaleOff }
        return nil
    }

    private static func message(for banner: Banner, timeZone: TimeZone) -> String {
        switch banner {
        case let .telemetryPaused(since?):
            "Telemetry paused since \(CommandError.clockTime(since, timeZone: timeZone))"
        case .telemetryPaused(nil):
            "Telemetry paused"
        case .budget(.minimal):
            "Minimal updates: budget nearly used"
        case .budget:
            "Reduced update rate to stay in budget"
        case .tailscaleOff:
            "Connect Tailscale to control the car"
        }
    }
}
