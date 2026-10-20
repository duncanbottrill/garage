import Foundation

/// One slice-1 vehicle command, with its typed payload. ``name`` is the Fleet API command name
/// (the last path segment of `/api/1/vehicles/{vin}/command/{name}`) and ``body`` its JSON body.
public enum Command: Sendable, Hashable {
    case doorLock
    case doorUnlock
    /// Climate on.
    case autoConditioningStart
    /// Climate off.
    case autoConditioningStop
    /// Cabin target temperatures, °C.
    case setTemps(driver: Double, passenger: Double)
    /// Seat heater `level` 0 (off) to 3 for one front seat.
    case remoteSeatHeater(SeatHeater, level: Int)
    /// Defrost (max preconditioning) on or off.
    case setPreconditioningMax(on: Bool, manualOverride: Bool)
    case chargePortDoorOpen
    case chargePortDoorClose
    case chargeStart
    case chargeStop
    /// Charge limit, percent.
    case setChargeLimit(percent: Int)
    /// Scheduled charging; `time` is minutes after local midnight. `enable: false` clears it.
    case setScheduledCharging(enable: Bool, time: Int)
    /// Opens the frunk (`actuate_trunk` with `which_trunk: "front"`).
    case actuateFrunk
    case flashLights
    case honkHorn

    /// The seat a heater command targets, by Tesla's `heater` index.
    public enum SeatHeater: Int, Sendable, Hashable, CaseIterable {
        case driver = 0
        case passenger = 1
    }

    /// The Fleet API command name, verbatim. Also the key of ``CommandClient``'s in-flight guard.
    public var name: String {
        switch self {
        case .doorLock: "door_lock"
        case .doorUnlock: "door_unlock"
        case .autoConditioningStart: "auto_conditioning_start"
        case .autoConditioningStop: "auto_conditioning_stop"
        case .setTemps: "set_temps"
        case .remoteSeatHeater: "remote_seat_heater_request"
        case .setPreconditioningMax: "set_preconditioning_max"
        case .chargePortDoorOpen: "charge_port_door_open"
        case .chargePortDoorClose: "charge_port_door_close"
        case .chargeStart: "charge_start"
        case .chargeStop: "charge_stop"
        case .setChargeLimit: "set_charge_limit"
        case .setScheduledCharging: "set_scheduled_charging"
        case .actuateFrunk: "actuate_trunk"
        case .flashLights: "flash_lights"
        case .honkHorn: "honk_horn"
        }
    }

    /// The JSON body; empty for commands without parameters.
    public var body: [String: AnyCodable] {
        switch self {
        case let .setTemps(driver, passenger):
            ["driver_temp": .init(driver), "passenger_temp": .init(passenger)]
        case let .remoteSeatHeater(heater, level):
            ["heater": .init(heater.rawValue), "level": .init(level)]
        case let .setPreconditioningMax(on, manualOverride):
            ["on": .init(on), "manual_override": .init(manualOverride)]
        case let .setChargeLimit(percent):
            ["percent": .init(percent)]
        case let .setScheduledCharging(enable, time):
            ["enable": .init(enable), "time": .init(time)]
        case .actuateFrunk:
            ["which_trunk": "front"]
        case .doorLock, .doorUnlock, .autoConditioningStart, .autoConditioningStop, .chargePortDoorOpen,
             .chargePortDoorClose, .chargeStart, .chargeStop, .flashLights, .honkHorn:
            [:]
        }
    }
}

/// A JSON scalar (bool, integer, number or string) for command bodies.
public struct AnyCodable: Codable, Sendable, Hashable {
    public enum Value: Sendable, Hashable {
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
    }

    public let value: Value

    public init(_ value: Bool) { self.value = .bool(value) }
    public init(_ value: Int) { self.value = .int(value) }
    public init(_ value: Double) { self.value = .double(value) }
    public init(_ value: String) { self.value = .string(value) }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let bool = try? c.decode(Bool.self) {
            value = .bool(bool)
        } else if let int = try? c.decode(Int.self) {
            value = .int(int)
        } else if let double = try? c.decode(Double.self) {
            value = .double(double)
        } else {
            value = .string(try c.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let .bool(bool): try c.encode(bool)
        case let .int(int): try c.encode(int)
        case let .double(double): try c.encode(double)
        case let .string(string): try c.encode(string)
        }
    }
}

extension AnyCodable: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral {
    public init(booleanLiteral value: Bool) { self.init(value) }
    public init(integerLiteral value: Int) { self.init(value) }
    public init(floatLiteral value: Double) { self.init(value) }
    public init(stringLiteral value: String) { self.init(value) }
}
