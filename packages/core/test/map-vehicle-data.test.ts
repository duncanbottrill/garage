import { describe, it, expect } from "vitest";
import fx from "./fixtures/vehicle_data.json";
import { vehicleDataToState } from "../src/tesla/map-vehicle-data";
const at = new Date("2026-10-18T15:00:00Z");
describe("vehicleDataToState", () => {
  it("maps charge, climate, position, body", () => {
    const s = vehicleDataToState(fx as any, at);
    expect(s.soc).toBe(72); expect(s.range_km).toBeCloseTo(344.9, 1); expect(s.charge_state).toBe("stopped");
    expect(s.inside_c).toBe(19.2); expect(s.lat).toBe(51.5013); expect(s.gear).toBe("P"); expect(s.speed_kph).toBe(0);
    expect(s.odometer_km).toBeCloseTo(8412.6, 1); expect(s.locked).toBe(true); expect(s.software_version).toBe("2026.32.5");
    expect(s.sleep_state).toBe("online"); expect(s.charge_at).toBe(at.toISOString());
  });
  it("omits missing groups", () => { expect(vehicleDataToState({ state: "asleep" }, at)).toEqual({ updated_at: at.toISOString(), sleep_state: "asleep" }); });
});
