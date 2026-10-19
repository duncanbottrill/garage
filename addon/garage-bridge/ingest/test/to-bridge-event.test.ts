import { describe, it, expect } from "vitest";
import { toBridgeEvent } from "../src/decode";
import { toStatePatch, type BridgeEvent } from "../src/state";
import fixtures from "./fixtures/mqtt-samples.json";

function byId(id: string) {
  const f = fixtures.find((f) => f.id === id);
  if (!f) throw new Error(`fixture not found: ${id}`);
  return f;
}

const BASE = "garage";
const VIN = "XP7YGCEL9PB123456";
// Used whenever the payload itself carries no usable timestamp.
const RECEIVED_AT = new Date("2026-10-19T09:00:00.000Z");

describe("toBridgeEvent", () => {
  const cases: Array<[string, BridgeEvent]> = [
    ["soc-plain", { kind: "field", vin: VIN, name: "Soc", value: 72.5, at: RECEIVED_AT }],
    [
      // Tesla-shaped connectivity object: {ConnectionId, Status, CreatedAt}.
      // This is the real fleet-telemetry dispatcher shape, not a bare string.
      "connectivity-connected",
      { kind: "connectivity", vin: VIN, status: "CONNECTED", at: new Date("2026-10-19T08:00:00Z") },
    ],
    [
      "connectivity-disconnected",
      { kind: "connectivity", vin: VIN, status: "DISCONNECTED", at: new Date("2026-10-19T08:05:00Z") },
    ],
    [
      // Not a connectivity-shaped payload at all (a bare number) -- must
      // normalize to UNKNOWN rather than throw.
      "connectivity-malformed",
      { kind: "connectivity", vin: VIN, status: "UNKNOWN", at: RECEIVED_AT },
    ],
    [
      // {Name, StartedAt, EndedAt: null, Audiences}: an alert that hasn't ended yet.
      "alert-service-required",
      { kind: "alert", vin: VIN, name: "Service_Required", active: true, at: new Date("2026-10-19T07:00:00Z") },
    ],
    [
      // Same alert with a real EndedAt timestamp: no longer active.
      "alert-service-required-cleared",
      { kind: "alert", vin: VIN, name: "Service_Required", active: false, at: new Date("2026-10-19T07:00:00Z") },
    ],
    [
      // {Name, Body, Tags, CreatedAt}.
      "error-some-error",
      { kind: "error", vin: VIN, name: "SomeError", body: "detail", at: new Date("2026-10-19T07:30:00Z") },
    ],
  ];

  for (const [id, expected] of cases) {
    it(`maps ${id} to the expected BridgeEvent`, () => {
      const fixture = byId(id);
      const ev = toBridgeEvent(fixture.topic, fixture.payload, BASE, RECEIVED_AT);
      expect(ev).toEqual(expected);
    });
  }

  it("does not crash on a payload that isn't JSON at all, and falls back to UNKNOWN", () => {
    const ev = toBridgeEvent(`garage/${VIN}/connectivity`, "definitely not json", BASE, RECEIVED_AT);
    expect(ev).toEqual({ kind: "connectivity", vin: VIN, status: "UNKNOWN", at: RECEIVED_AT });
  });

  it("accepts a Buffer payload the same as a string", () => {
    const fixture = byId("connectivity-connected");
    const ev = toBridgeEvent(fixture.topic, Buffer.from(fixture.payload), BASE, RECEIVED_AT);
    expect(ev).toEqual({ kind: "connectivity", vin: VIN, status: "CONNECTED", at: new Date("2026-10-19T08:00:00Z") });
  });

  it("still accepts a bare status string (older/synthetic payload shape)", () => {
    const ev = toBridgeEvent(`garage/${VIN}/connectivity`, JSON.stringify("CONNECTED"), BASE, RECEIVED_AT);
    expect(ev).toEqual({ kind: "connectivity", vin: VIN, status: "CONNECTED", at: RECEIVED_AT });
  });

  it("returns null for a topic outside base", () => {
    expect(toBridgeEvent(`other-base/${VIN}/v/Soc`, "1", BASE, RECEIVED_AT)).toBeNull();
  });

  it("returns null for a v/ topic missing its field name", () => {
    expect(toBridgeEvent(`garage/${VIN}/v`, "1", BASE, RECEIVED_AT)).toBeNull();
  });

  it("feeds a Tesla-shaped CONNECTED connectivity event's status through to toStatePatch's sleep_state", () => {
    const fixture = byId("connectivity-connected");
    const ev = toBridgeEvent(fixture.topic, fixture.payload, BASE, RECEIVED_AT);
    expect(ev).not.toBeNull();
    expect(toStatePatch(ev!)).toEqual({ sleep_state: "online" });
  });

  it("feeds a Tesla-shaped DISCONNECTED connectivity event's status through to toStatePatch's sleep_state", () => {
    const fixture = byId("connectivity-disconnected");
    const ev = toBridgeEvent(fixture.topic, fixture.payload, BASE, RECEIVED_AT);
    expect(ev).not.toBeNull();
    expect(toStatePatch(ev!)).toEqual({ sleep_state: "asleep" });
  });
});
