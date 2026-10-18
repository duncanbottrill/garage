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
});
