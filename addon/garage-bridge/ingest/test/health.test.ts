import { describe, it, expect } from "vitest";
import { Health } from "../src/health";

describe("Health", () => {
  it("starts with zeroed counters and null fields", () => {
    const health = new Health();
    expect(health.payload()).toEqual({
      received: 0,
      flushed: 0,
      dropped: 0,
      patch_failures: 0,
      last_event_at: null,
      connectivity: null,
      active_alerts: [],
      last_error: null,
      last_vehicle_error: null,
    });
  });

  it("setDropped sets the absolute count, not a running total", () => {
    const health = new Health();
    health.setDropped(5);
    expect(health.payload().dropped).toBe(5);
    health.setDropped(5); // same cumulative total from the batcher, not +5 again
    expect(health.payload().dropped).toBe(5);
    health.setDropped(12);
    expect(health.payload().dropped).toBe(12);
  });

  it("vehicleError records last_vehicle_error without touching patch_failures or last_error", () => {
    const health = new Health();
    health.vehicleError("SomeError", "detail body");
    const payload = health.payload();
    expect(payload.last_vehicle_error).toBe("SomeError: detail body");
    expect(payload.patch_failures).toBe(0);
    expect(payload.last_error).toBeNull();
  });

  it("patchFailed still increments patch_failures and sets last_error, independent of vehicleError", () => {
    const health = new Health();
    health.vehicleError("SomeError", "detail");
    health.patchFailed(new Error("merge boom"));
    const payload = health.payload();
    expect(payload.patch_failures).toBe(1);
    expect(payload.last_error).toBe("merge boom");
    expect(payload.last_vehicle_error).toBe("SomeError: detail");
  });

  it("tracks received/flushed/connectivity/alerts/eventAt as before", () => {
    const health = new Health();
    health.received();
    health.received();
    health.flushed(3);
    health.connectivity("CONNECTED");
    health.alert("Service_Required", true);
    const at = new Date("2026-10-19T08:00:00.000Z");
    health.eventAt(at);

    const payload = health.payload();
    expect(payload.received).toBe(2);
    expect(payload.flushed).toBe(3);
    expect(payload.connectivity).toBe("CONNECTED");
    expect(payload.active_alerts).toEqual(["Service_Required"]);
    expect(payload.last_event_at).toBe(at.toISOString());

    health.alert("Service_Required", false);
    expect(health.payload().active_alerts).toEqual([]);
  });
});
