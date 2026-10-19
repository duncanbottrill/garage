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
  it("window signal null → {}", () => expect(m("FdWindow", null, at)).toEqual({}));
  it("ChargeAmps", () => expect(m("ChargeAmps", "16", at)).toEqual({ charge_amps: 16 }));
  describe("no-information values → {}", () => {
    const fields = ["Soc", "ChargeState", "DetailedChargeState", "HvacPower", "ClimateKeeperMode", "Location", "Gear", "Locked", "SentryMode", "SoftwareUpdateVersion", "DoorState", "FdWindow", "TpmsPressureFl", "ChargeLimitSoc"];
    for (const f of fields) {
      it(`${f} null → {}`, () => expect(m(f, null, at)).toEqual({}));
      it(`${f} undefined → {}`, () => expect(m(f, undefined, at)).toEqual({}));
    }
    it("WindowStateUnknown → {}", () => expect(m("FdWindow", "WindowStateUnknown", at)).toEqual({}));
    it("DoorStateUnknown → {}", () => expect(m("DoorState", "DoorStateUnknown", at)).toEqual({}));
    it("ShiftStateUnknown → {}", () => expect(m("Gear", "ShiftStateUnknown", at)).toEqual({}));
    it("ShiftStateSNA → {}", () => expect(m("Gear", "ShiftStateSNA", at)).toEqual({}));
    it("bare SNA → {}", () => expect(m("Gear", "SNA", at)).toEqual({}));
    it("DetailedChargeStateUnknown → {}", () => expect(m("DetailedChargeState", "DetailedChargeStateUnknown", at)).toEqual({}));
    it("HvacPowerStateUnknown → {}", () => expect(m("HvacPower", "HvacPowerStateUnknown", at)).toEqual({}));
    it("SentryModeStateUnknown → {}", () => expect(m("SentryMode", "SentryModeStateUnknown", at)).toEqual({}));
    it("ClimateKeeperModeStateUnknown → {}", () => expect(m("ClimateKeeperMode", "ClimateKeeperModeStateUnknown", at)).toEqual({}));
    it("a real value still maps (WindowStateClosed → closed)", () => expect(m("FdWindow", "WindowStateClosed", at)).toEqual({ windows: { driver_front: false } }));
    it("HvacPowerStateOff still maps to false", () => expect(m("HvacPower", "HvacPowerStateOff", at)).toEqual({ hvac_on: false }));
    it("an out-of-range ScheduledChargingStartTime → {} rather than throwing", () => expect(m("ScheduledChargingStartTime", "1e400", at)).toEqual({}));
  });
});
