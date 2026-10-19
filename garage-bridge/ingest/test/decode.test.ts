import { describe, it, expect } from "vitest";
import { decodePayload, parseTopic } from "../src/decode";
import fixtures from "./fixtures/mqtt-samples.json";

function byId(id: string) {
  const f = fixtures.find((f) => f.id === id);
  if (!f) throw new Error(`fixture not found: ${id}`);
  return f;
}

describe("decodePayload", () => {
  const cases: Array<[string, unknown]> = [
    ["soc-plain", 72.5],
    ["battery-double-wrapped", 72],
    ["gear-plain-string", "ShiftStateD"],
    ["gear-shiftstate-wrapped", "ShiftStateP"],
    ["location-plain-object", { latitude: 54.41, longitude: -1.72 }],
    ["location-wrapped", { latitude: 54.41, longitude: -1.72 }],
    [
      "door-state",
      {
        DriverFront: false,
        PassengerFront: true,
        DriverRear: false,
        PassengerRear: false,
        TrunkFront: false,
        TrunkRear: false,
      },
    ],
    ["locked-plain-bool", true],
    ["window-plain-string", "WindowStatePartiallyOpen"],
    ["tpms-fl-plain", 2.9],
    ["speed-invalid-string", null],
    ["sentry-plain-string", "SentryModeStateArmed"],
    ["charge-amps-int-wrapped", 32],
    ["charge-port-bool-wrapped", true],
    ["generic-invalid-object", null],
  ];

  for (const [id, expected] of cases) {
    it(`decodes ${id}`, () => {
      const fixture = byId(id);
      expect(decodePayload(fixture.payload)).toEqual(expected);
    });
  }

  it("decodes from a Buffer the same as a string", () => {
    const fixture = byId("soc-plain");
    expect(decodePayload(Buffer.from(fixture.payload))).toEqual(72.5);
  });

  it("maps the literal string invalid (no wrapper) to null", () => {
    expect(decodePayload('"invalid"')).toBeNull();
  });
});

describe("parseTopic", () => {
  const base = "garage";

  it("parses a v/ field topic", () => {
    expect(parseTopic("garage/XP7YGCEL9PB123456/v/Soc", base)).toEqual({
      vin: "XP7YGCEL9PB123456",
      section: "v",
      rest: ["Soc"],
    });
  });

  it("parses a connectivity topic with no rest segments", () => {
    expect(parseTopic("garage/XP7YGCEL9PB123456/connectivity", base)).toEqual({
      vin: "XP7YGCEL9PB123456",
      section: "connectivity",
      rest: [],
    });
  });

  it("parses an alerts topic with name + current", () => {
    expect(parseTopic("garage/XP7YGCEL9PB123456/alerts/Service_Required/current", base)).toEqual({
      vin: "XP7YGCEL9PB123456",
      section: "alerts",
      rest: ["Service_Required", "current"],
    });
  });

  it("parses an errors topic", () => {
    expect(parseTopic("garage/XP7YGCEL9PB123456/errors/SomeError", base)).toEqual({
      vin: "XP7YGCEL9PB123456",
      section: "errors",
      rest: ["SomeError"],
    });
  });

  it("rejects a topic under a foreign base", () => {
    expect(parseTopic("other-base/XP7YGCEL9PB123456/v/Soc", base)).toBeNull();
  });

  it("rejects an unknown section", () => {
    expect(parseTopic("garage/XP7YGCEL9PB123456/bogus/Soc", base)).toBeNull();
  });

  it("rejects a topic missing a vin/section", () => {
    expect(parseTopic("garage", base)).toBeNull();
  });
});
