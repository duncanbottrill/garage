import { describe, it, expect } from "vitest";
import { decodePayload } from "../src/decode";
import { sanitizeStatePatch, toSignalRow, toStateClears, toStatePatch, type BridgeEvent } from "../src/state";
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

describe("toStatePatch: null and Unknown values carry no information", () => {
  const field = (name: string, value: unknown): BridgeEvent => ({ kind: "field", vin: "VIN1", name, value, at: AT });

  for (const name of ["ChargeState", "DetailedChargeState", "Gear", "SoftwareUpdateVersion", "ClimateKeeperMode", "DoorState", "HvacPower", "SentryMode", "FdWindow", "Locked"]) {
    it(`${name} with a null value → {}`, () => expect(toStatePatch(field(name, null))).toEqual({}));
    it(`${name} decoded from "invalid" → {}`, () => expect(toStatePatch(field(name, decodePayload('"invalid"')))).toEqual({}));
    it(`${name} decoded from {"invalid":true} → {}`, () => expect(toStatePatch(field(name, decodePayload('{"invalid":true}')))).toEqual({}));
  }

  it("WindowStateUnknown → {} (not 'open')", () => expect(toStatePatch(field("RpWindow", "WindowStateUnknown"))).toEqual({}));
  it("DoorStateUnknown → {} (not 'all closed' with a fresh body_at)", () => expect(toStatePatch(field("DoorState", "DoorStateUnknown"))).toEqual({}));
  it("ShiftStateSNA → {}", () => expect(toStatePatch(field("Gear", "ShiftStateSNA"))).toEqual({}));
  it("a wrapped Unknown enum ({\"windowStateValue\":\"WindowStateUnknown\"}) → {}", () =>
    expect(toStatePatch(field("FdWindow", decodePayload('{"windowStateValue":"WindowStateUnknown"}')))).toEqual({}));
});

describe("toStatePatch / sanitizeStatePatch: type validation drops bad keys, not the whole patch", () => {
  const field = (name: string, value: unknown): BridgeEvent => ({ kind: "field", vin: "VIN1", name, value, at: AT });

  it("drops a non-finite number but keeps the rest of the patch", () => {
    expect(sanitizeStatePatch({ soc: Infinity, charge_at: AT.toISOString() })).toEqual({ charge_at: AT.toISOString() });
    expect(sanitizeStatePatch({ inside_c: Number.NaN, climate_at: AT.toISOString() })).toEqual({ climate_at: AT.toISOString() });
  });

  it("a Soc of '1e400' (Infinity after coercion) keeps charge_at only", () => {
    expect(toStatePatch(field("Soc", "1e400"))).toEqual({ charge_at: AT.toISOString() });
  });

  it("drops lat/lng/location_at together when latitude is outside [-90, 90]", () => {
    expect(toStatePatch(field("Location", { latitude: 95, longitude: -1.7 }))).toEqual({});
    expect(sanitizeStatePatch({ lat: -90.01, lng: 10, location_at: AT.toISOString(), speed_kph: 0 })).toEqual({ speed_kph: 0 });
  });

  it("drops lat/lng/location_at together when longitude is outside [-180, 180]", () => {
    expect(toStatePatch(field("Location", { latitude: 54.4, longitude: 181 }))).toEqual({});
  });

  it("drops lat/lng/location_at when either coordinate is not a number", () => {
    expect(sanitizeStatePatch({ lat: "54.4" as unknown as number, lng: -1.7, location_at: AT.toISOString() })).toEqual({});
  });

  it("keeps a valid location, including the boundary values", () => {
    expect(toStatePatch(field("Location", { latitude: -90, longitude: 180 }))).toEqual({ lat: -90, lng: 180, location_at: AT.toISOString() });
  });

  it("keeps charge_limit_soc only when it is an integer in [0, 100]", () => {
    expect(toStatePatch(field("ChargeLimitSoc", 80))).toEqual({ charge_limit_soc: 80 });
    expect(toStatePatch(field("ChargeLimitSoc", 0))).toEqual({ charge_limit_soc: 0 });
    expect(toStatePatch(field("ChargeLimitSoc", 100))).toEqual({ charge_limit_soc: 100 });
    expect(toStatePatch(field("ChargeLimitSoc", 80.5))).toEqual({});
    expect(toStatePatch(field("ChargeLimitSoc", 101))).toEqual({});
    expect(toStatePatch(field("ChargeLimitSoc", -1))).toEqual({});
  });

  it("drops non-finite tpms_bar entries, and the key itself when nothing is left", () => {
    expect(sanitizeStatePatch({ tpms_bar: { fl: Infinity, fr: 2.9 } as never })).toEqual({ tpms_bar: { fr: 2.9 } });
    expect(toStatePatch(field("TpmsPressureFl", "1e400"))).toEqual({});
  });

  it("leaves a fully valid patch unchanged", () => {
    const patch = { soc: 72.5, charge_at: AT.toISOString(), locked: true, body_at: AT.toISOString(), gear: "D" };
    expect(sanitizeStatePatch(patch)).toEqual(patch);
  });
});

describe("toStateClears: an invalid value that means 'no value' clears its state keys", () => {
  const field = (name: string, value: unknown): BridgeEvent => ({ kind: "field", vin: "VIN1", name, value, at: AT });

  it("ScheduledChargingStartTime null → clears scheduled_charge_at", () =>
    expect(toStateClears(field("ScheduledChargingStartTime", null))).toEqual(["scheduled_charge_at"]));
  it('ScheduledChargingStartTime decoded from "invalid" → clears scheduled_charge_at', () =>
    expect(toStateClears(field("ScheduledChargingStartTime", decodePayload('"invalid"')))).toEqual(["scheduled_charge_at"]));
  it("ScheduledChargingStartTime with a value clears nothing (and patches the time)", () => {
    const ev = field("ScheduledChargingStartTime", 1_760_000_000);
    expect(toStateClears(ev)).toEqual([]);
    expect(toStatePatch(ev)).toEqual({ scheduled_charge_at: new Date(1_760_000_000 * 1000).toISOString() });
  });
  it("other signals clear nothing on null", () => {
    for (const name of ["Soc", "Locked", "VehicleSpeed", "Gear"]) expect(toStateClears(field(name, null))).toEqual([]);
  });
  it("non-field events clear nothing", () => {
    expect(toStateClears({ kind: "connectivity", vin: "VIN1", status: "DISCONNECTED", at: AT })).toEqual([]);
    expect(toStateClears({ kind: "alert", vin: "VIN1", name: "x", active: true, at: AT })).toEqual([]);
  });
});
