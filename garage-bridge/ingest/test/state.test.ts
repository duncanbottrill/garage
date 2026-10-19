import { describe, it, expect } from "vitest";
import { decodePayload } from "../src/decode";
import { toSignalRow, toStatePatch, type BridgeEvent } from "../src/state";
import fixtures from "./fixtures/mqtt-samples.json";

function payloadFor(id: string): unknown {
  const f = fixtures.find((f) => f.id === id);
  if (!f) throw new Error(`fixture not found: ${id}`);
  return decodePayload(f.payload);
}

const AT = new Date("2026-10-19T08:00:00.000Z");

describe("toSignalRow", () => {
  it("places a numeric field value into value_num", () => {
    const ev: BridgeEvent = { kind: "field", vin: "VIN1", name: "Soc", value: payloadFor("soc-plain"), at: AT };
    const row = toSignalRow(ev, "veh-1", "owner-1");
    expect(row).toEqual({
      vehicle_id: "veh-1",
      owner_id: "owner-1",
      name: "Soc",
      value_num: 72.5,
      value_text: null,
      value_json: null,
      recorded_at: AT.toISOString(),
    });
  });

  it("places a string field value into value_text", () => {
    const ev: BridgeEvent = { kind: "field", vin: "VIN1", name: "Gear", value: payloadFor("gear-plain-string"), at: AT };
    const row = toSignalRow(ev, "veh-1", "owner-1");
    expect(row.value_text).toBe("ShiftStateD");
    expect(row.value_num).toBeNull();
    expect(row.value_json).toBeNull();
  });

  it("places an object field value into value_json", () => {
    const ev: BridgeEvent = {
      kind: "field",
      vin: "VIN1",
      name: "Location",
      value: payloadFor("location-wrapped"),
      at: AT,
    };
    const row = toSignalRow(ev, "veh-1", "owner-1");
    expect(row.value_json).toEqual({ latitude: 54.41, longitude: -1.72 });
    expect(row.value_num).toBeNull();
    expect(row.value_text).toBeNull();
  });

  it("places a boolean field value into value_text as 'true'/'false'", () => {
    const ev: BridgeEvent = { kind: "field", vin: "VIN1", name: "Locked", value: payloadFor("locked-plain-bool"), at: AT };
    const row = toSignalRow(ev, "veh-1", "owner-1");
    expect(row.value_text).toBe("true");
    expect(row.value_num).toBeNull();
    expect(row.value_json).toBeNull();
  });

  it("sets recorded_at from the event's at timestamp", () => {
    const ev: BridgeEvent = { kind: "field", vin: "VIN1", name: "Soc", value: 50, at: AT };
    const row = toSignalRow(ev, "veh-1", "owner-1");
    expect(row.recorded_at).toBe("2026-10-19T08:00:00.000Z");
  });
});

describe("toStatePatch", () => {
  it("maps a Soc field event to soc + charge_at", () => {
    const ev: BridgeEvent = { kind: "field", vin: "VIN1", name: "Soc", value: payloadFor("soc-plain"), at: AT };
    expect(toStatePatch(ev)).toEqual({ soc: 72.5, charge_at: AT.toISOString() });
  });

  it("maps a Location field event to lat/lng/location_at", () => {
    const ev: BridgeEvent = {
      kind: "field",
      vin: "VIN1",
      name: "Location",
      value: payloadFor("location-wrapped"),
      at: AT,
    };
    expect(toStatePatch(ev)).toEqual({ lat: 54.41, lng: -1.72, location_at: AT.toISOString() });
  });

  it("maps a DoorState field event to doors + frunk/trunk open flags", () => {
    const ev: BridgeEvent = { kind: "field", vin: "VIN1", name: "DoorState", value: payloadFor("door-state"), at: AT };
    expect(toStatePatch(ev)).toEqual({
      doors: { driver_front: false, passenger_front: true, driver_rear: false, passenger_rear: false },
      frunk_open: false,
      trunk_open: false,
      body_at: AT.toISOString(),
    });
  });

  it("maps an FpWindow field event to windows.passenger_front", () => {
    const ev: BridgeEvent = {
      kind: "field",
      vin: "VIN1",
      name: "FpWindow",
      value: payloadFor("window-plain-string"),
      at: AT,
    };
    expect(toStatePatch(ev)).toEqual({ windows: { passenger_front: true } });
  });

  it("maps CONNECTED connectivity to sleep_state online", () => {
    const ev: BridgeEvent = { kind: "connectivity", vin: "VIN1", status: "CONNECTED", at: AT };
    expect(toStatePatch(ev)).toEqual({ sleep_state: "online" });
  });

  it("maps DISCONNECTED connectivity to sleep_state asleep", () => {
    const ev: BridgeEvent = { kind: "connectivity", vin: "VIN1", status: "DISCONNECTED", at: AT };
    expect(toStatePatch(ev)).toEqual({ sleep_state: "asleep" });
  });

  it("maps UNKNOWN connectivity to an empty patch", () => {
    const ev: BridgeEvent = { kind: "connectivity", vin: "VIN1", status: "UNKNOWN", at: AT };
    expect(toStatePatch(ev)).toEqual({});
  });

  it("maps alert events to an empty patch (they go to health)", () => {
    const ev: BridgeEvent = { kind: "alert", vin: "VIN1", name: "Service_Required", active: true, at: AT };
    expect(toStatePatch(ev)).toEqual({});
  });

  it("maps error events to an empty patch (they go to health)", () => {
    const ev: BridgeEvent = { kind: "error", vin: "VIN1", name: "SomeError", body: "detail", at: AT };
    expect(toStatePatch(ev)).toEqual({});
  });

  it("maps a VehicleSpeed field event decoded from 'invalid' to an empty patch", () => {
    const ev: BridgeEvent = {
      kind: "field",
      vin: "VIN1",
      name: "VehicleSpeed",
      value: payloadFor("speed-invalid-string"),
      at: AT,
    };
    expect(toStatePatch(ev)).toEqual({});
  });
});
