import type { VehicleStateRow } from "../types";
import { milesToKm } from "./map-vehicle-data";
const num = (v: unknown) => (typeof v === "number" ? v : typeof v === "string" && v.trim() !== "" && !isNaN(+v) ? +v : null);
const bool = (v: unknown) => (typeof v === "boolean" ? v : v === "true" ? true : v === "false" ? false : null);
export function telemetrySignalToState(name: string, value: unknown, at: Date): Partial<VehicleStateRow> {
  const iso = at.toISOString(); const n = num(value), b = bool(value);
  switch (name) {
    case "Soc": case "BatteryLevel": return n == null ? {} : { soc: n, charge_at: iso };
    case "EstBatteryRange": case "IdealBatteryRange": return n == null ? {} : { range_km: milesToKm(n) };
    case "ChargeState": case "DetailedChargeState": return { charge_state: String(value).replace(/^DetailedChargeState/, "").toLowerCase() };
    case "ACChargingPower": case "DCChargingPower": case "ChargerPower": return n == null ? {} : { charger_power_kw: n };
    case "ChargeLimitSoc": return n == null ? {} : { charge_limit_soc: n };
    case "ChargePortDoorOpen": return b == null ? {} : { charge_port_open: b };
    case "ScheduledChargingStartTime": return n == null ? {} : { scheduled_charge_at: new Date(n * 1000).toISOString() };
    case "InsideTemp": return n == null ? {} : { inside_c: n, climate_at: iso };
    case "OutsideTemp": return n == null ? {} : { outside_c: n };
    case "HvacPower": return { hvac_on: value === "HvacPowerStateOn" || value === true };
    case "ClimateKeeperMode": return { climate_keeper: String(value) };
    case "Location": { const v: any = value; return v && v.latitude != null && v.longitude != null ? { lat: v.latitude, lng: v.longitude, location_at: iso } : {}; }
    case "VehicleSpeed": return n == null ? {} : { speed_kph: milesToKm(n) };
    case "Odometer": return n == null ? {} : { odometer_km: milesToKm(n) };
    case "Gear": return { gear: String(value).replace(/^ShiftState/, "") || "P" };
    case "Locked": return b == null ? {} : { locked: b, body_at: iso };
    case "SentryMode": return { sentry: value === true || (typeof value === "string" && !/Off$/.test(value) && !/Unknown$/.test(value)) };
    case "TpmsPressureFl": case "TpmsPressureFr": case "TpmsPressureRl": case "TpmsPressureRr": {
      if (n == null) return {}; const k = name.slice(-2).toLowerCase(); return { tpms_bar: { [k]: n } as any }; // bar already in telemetry
    }
    case "SoftwareUpdateVersion": return { software_version: String(value) };
    case "DoorState": {
      const open = (k: string) => typeof value === "object" && value !== null ? !!(value as any)[k] : String(value).split("|").includes(k);
      return { doors: { driver_front: open("DriverFront"), passenger_front: open("PassengerFront"), driver_rear: open("DriverRear"), passenger_rear: open("PassengerRear") }, frunk_open: open("TrunkFront"), trunk_open: open("TrunkRear"), body_at: iso };
    }
    case "FdWindow": case "FpWindow": case "RdWindow": case "RpWindow": {
      const key = ({ Fd: "driver_front", Fp: "passenger_front", Rd: "driver_rear", Rp: "passenger_rear" } as const)[name.slice(0, 2) as "Fd" | "Fp" | "Rd" | "Rp"];
      return { windows: { [key]: value !== "WindowStateClosed" && value !== false } as any };
    }
    case "ChargeAmps": return n == null ? {} : { charge_amps: n };
    default: return {};
  }
}
