import Foundation

/// One row of `public.vehicle_state`: the car's latest known telemetry, written by the Home Assistant
/// bridge and read by the signed-in owner (RLS `owner_id = auth.uid()`).
///
/// Every column is optional. The bridge patches the row field by field, so a young row (or a Realtime
/// record) can carry nothing but its keys, and the app must render whatever is there. Each `*_at`
/// column stamps when its group of fields was last reported; feed it to ``Freshness/of(_:now:staleAfter:)``.
public struct VehicleState: Codable, Sendable, Equatable {
    public var vehicleId: UUID?
    public var ownerId: UUID?

    // Charge
    /// State of charge, percent (0–100, fractional).
    public var soc: Double?
    public var rangeKm: Double?
    /// Tesla charge state as reported, for example `"disconnected"`, `"charging"`, `"complete"`.
    public var chargeState: String?
    public var chargerPowerKw: Double?
    /// Charge limit, percent.
    public var chargeLimitSoc: Int?
    public var chargePortOpen: Bool?
    public var scheduledChargeAt: Date?
    public var chargeAmps: Double?
    public var chargeAt: Date?

    // Climate
    public var insideC: Double?
    public var outsideC: Double?
    public var hvacOn: Bool?
    /// Tesla climate keeper mode as reported, for example `"ClimateKeeperModeStateOff"`.
    public var climateKeeper: String?
    public var climateAt: Date?

    // Location and drive
    public var lat: Double?
    public var lng: Double?
    /// Degrees clockwise from north.
    public var heading: Double?
    public var speedKph: Double?
    /// Gear as reported, for example `"P"`, `"D"`, `"R"`, `"N"`.
    public var gear: String?
    public var odometerKm: Double?
    public var locationAt: Date?

    // Body
    public var locked: Bool?
    public var doors: Doors?
    public var windows: Windows?
    public var frunkOpen: Bool?
    public var trunkOpen: Bool?
    public var sentry: Bool?
    public var tpmsBar: Tpms?
    public var bodyAt: Date?

    // Vehicle and bridge
    /// `"online"`, `"asleep"` or `"offline"` as the bridge last saw it.
    public var sleepState: String?
    /// Firmware version; the car can report a blank string (`" "`) before it is known.
    public var softwareVersion: String?
    /// When the bridge last checked in. Drives ``Freshness/bridge(seenAt:now:)``.
    public var bridgeSeenAt: Date?
    public var bridgeHealth: BridgeHealth?
    public var updatedAt: Date?

    /// An empty row; every field nil.
    public init() {}

    enum CodingKeys: String, CodingKey {
        case vehicleId = "vehicle_id"
        case ownerId = "owner_id"
        case soc
        case rangeKm = "range_km"
        case chargeState = "charge_state"
        case chargerPowerKw = "charger_power_kw"
        case chargeLimitSoc = "charge_limit_soc"
        case chargePortOpen = "charge_port_open"
        case scheduledChargeAt = "scheduled_charge_at"
        case chargeAmps = "charge_amps"
        case chargeAt = "charge_at"
        case insideC = "inside_c"
        case outsideC = "outside_c"
        case hvacOn = "hvac_on"
        case climateKeeper = "climate_keeper"
        case climateAt = "climate_at"
        case lat, lng, heading
        case speedKph = "speed_kph"
        case gear
        case odometerKm = "odometer_km"
        case locationAt = "location_at"
        case locked, doors, windows
        case frunkOpen = "frunk_open"
        case trunkOpen = "trunk_open"
        case sentry
        case tpmsBar = "tpms_bar"
        case bodyAt = "body_at"
        case sleepState = "sleep_state"
        case softwareVersion = "software_version"
        case bridgeSeenAt = "bridge_seen_at"
        case bridgeHealth = "bridge_health"
        case updatedAt = "updated_at"
    }
}

/// Open/closed per door (`doors` jsonb). `true` means open.
public struct Doors: Codable, Sendable, Equatable {
    public var driverFront: Bool?
    public var passengerFront: Bool?
    public var driverRear: Bool?
    public var passengerRear: Bool?

    public init(driverFront: Bool? = nil, passengerFront: Bool? = nil, driverRear: Bool? = nil, passengerRear: Bool? = nil) {
        self.driverFront = driverFront
        self.passengerFront = passengerFront
        self.driverRear = driverRear
        self.passengerRear = passengerRear
    }

    /// True when any reported door is open; false when all reported doors are shut; nil when none is known.
    public var anyOpen: Bool? { Self.any([driverFront, passengerFront, driverRear, passengerRear]) }

    static func any(_ values: [Bool?]) -> Bool? {
        let known = values.compactMap { $0 }
        return known.isEmpty ? nil : known.contains(true)
    }

    enum CodingKeys: String, CodingKey {
        case driverFront = "driver_front"
        case passengerFront = "passenger_front"
        case driverRear = "driver_rear"
        case passengerRear = "passenger_rear"
    }
}

/// Open/closed per window (`windows` jsonb). `true` means open (including vented).
public struct Windows: Codable, Sendable, Equatable {
    public var driverFront: Bool?
    public var passengerFront: Bool?
    public var driverRear: Bool?
    public var passengerRear: Bool?

    public init(driverFront: Bool? = nil, passengerFront: Bool? = nil, driverRear: Bool? = nil, passengerRear: Bool? = nil) {
        self.driverFront = driverFront
        self.passengerFront = passengerFront
        self.driverRear = driverRear
        self.passengerRear = passengerRear
    }

    /// True when any reported window is open; nil when none is known.
    public var anyOpen: Bool? { Doors.any([driverFront, passengerFront, driverRear, passengerRear]) }

    enum CodingKeys: String, CodingKey {
        case driverFront = "driver_front"
        case passengerFront = "passenger_front"
        case driverRear = "driver_rear"
        case passengerRear = "passenger_rear"
    }
}

/// Tyre pressures in bar (`tpms_bar` jsonb): front-left, front-right, rear-left, rear-right.
public struct Tpms: Codable, Sendable, Equatable {
    public var fl: Double?
    public var fr: Double?
    public var rl: Double?
    public var rr: Double?

    public init(fl: Double? = nil, fr: Double? = nil, rl: Double? = nil, rr: Double? = nil) {
        self.fl = fl
        self.fr = fr
        self.rl = rl
        self.rr = rr
    }
}

/// The JSON coding the app uses for Supabase rows, Realtime records and the snapshot cache.
public enum GarageJSON {
    /// Decodes snake_case rows through each type's explicit `CodingKeys`. Dates accept ISO-8601 with or
    /// without fractional seconds (any number of digits), with `Z`, `+00:00` or `+00` offsets (a missing
    /// offset is read as UTC, a space separator as `T`), and also plain numbers in the Foundation
    /// reference-date form the encoder writes, so cached snapshots round-trip exactly.
    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let seconds = try? container.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let string = try container.decode(String.self)
            guard let date = parseDate(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO-8601 timestamp: \(string)")
            }
            return date
        }
        return decoder
    }

    /// Encodes dates as reference-date seconds (lossless, unlike ISO-8601 with millisecond precision).
    public static var encoder: JSONEncoder {
        JSONEncoder()
    }

    /// Parses the timestamp forms PostgREST and Realtime emit. Returns nil for anything else.
    public static func parseDate(_ raw: String) -> Date? {
        var string = raw.trimmingCharacters(in: .whitespaces)
        guard string.count >= 19 else { return nil }
        // "2026-10-20 07:31:49+00" (Postgres text form) → "2026-10-20T07:31:49+00"
        if string[string.index(string.startIndex, offsetBy: 10)] == " " {
            string = String(string.prefix(10)) + "T" + String(string.dropFirst(11))
        }
        // Offset: "+00" → "+00:00"; none → "Z". Only the time part is searched (the date has dashes).
        let time = string.dropFirst(11)
        if let sign = time.lastIndex(where: { $0 == "+" || $0 == "-" }) {
            if string[sign...].count == 3 { string += ":00" }
        } else if !string.hasSuffix("Z") && !string.hasSuffix("z") {
            string += "Z"
        }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
            ?? (try? Date.ISO8601FormatStyle().parse(string))
    }

    /// Decodes a Realtime/PostgREST record (column → value) into a model.
    static func decode<T: Decodable>(_ type: T.Type, from object: some Encodable) throws -> T {
        try decoder.decode(type, from: JSONEncoder().encode(object))
    }
}
