import { describe, it, expect } from "vitest";
import { telemetrySignalToState as m } from "../src/tesla/map-telemetry";
const at = new Date("2026-10-18T15:00:00Z"), iso = at.toISOString();
describe("telemetrySignalToState", () => {
  it("Soc", () => expect(m("Soc", 72.4, at)).toEqual({ soc: 72.4, charge_at: iso }));
  it("range miles→km", () => expect(m("EstBatteryRange", "100", at).range_km).toBeCloseTo(160.93, 2));
  it("Location", () => expect(m("Location", { latitude: 1, longitude: 2 }, at)).toEqual({ lat: 1, lng: 2, location_at: iso }));
  it("Gear strips prefix", () => expect(m("Gear", "ShiftStateD", at)).toEqual({ gear: "D" }));
  it("DetailedChargeState", () => expect(m("DetailedChargeState", "DetailedChargeStateCharging", at)).toEqual({ charge_state: "charging" }));
  it("unknown → {}", () => expect(m("Nonsense", 1, at)).toEqual({}));
  it("bad numbers → {}", () => expect(m("Soc", "n/a", at)).toEqual({}));
  it("SentryMode armed → true", () => expect(m("SentryMode", "SentryModeStateArmed", at)).toEqual({ sentry: true }));
  it("SentryMode off → false", () => expect(m("SentryMode", "SentryModeStateOff", at)).toEqual({ sentry: false }));
  it("Location with only latitude → {}", () => expect(m("Location", { latitude: 1 }, at)).toEqual({}));
  it("DoorState object", () => expect(m("DoorState", { DriverFront: true, PassengerFront: false, DriverRear: false, PassengerRear: false, TrunkFront: true, TrunkRear: false }, at)).toEqual({ doors: { driver_front: true, passenger_front: false, driver_rear: false, passenger_rear: false }, frunk_open: true, trunk_open: false, body_at: iso }));
  it("DoorState string list", () => expect(m("DoorState", "PassengerRear|TrunkRear", at).doors?.passenger_rear).toBe(true));
  it("window signal", () => expect(m("FpWindow", "WindowStatePartiallyOpen", at)).toEqual({ windows: { passenger_front: true } }));
  it("ChargeAmps", () => expect(m("ChargeAmps", "16", at)).toEqual({ charge_amps: 16 }));
});
