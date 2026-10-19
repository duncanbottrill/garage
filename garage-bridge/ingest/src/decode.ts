import type { BridgeEvent } from "./state";

export type Section = "v" | "connectivity" | "alerts" | "errors";

export interface ParsedTopic {
  vin: string;
  section: Section;
  rest: string[];
}

const SECTIONS: readonly Section[] = ["v", "connectivity", "alerts", "errors"];

/**
 * Splits a Tesla fleet-telemetry MQTT topic of the form
 * `<base>/<VIN>/<section>[/...rest]` into its parts. Returns null when the
 * topic does not sit under `base` or its section segment isn't recognized.
 */
export function parseTopic(topic: string, base: string): ParsedTopic | null {
  const baseParts = base.split("/").filter((p) => p.length > 0);
  const parts = topic.split("/").filter((p) => p.length > 0);

  if (parts.length < baseParts.length + 2) return null;
  for (let i = 0; i < baseParts.length; i++) {
    if (parts[i] !== baseParts[i]) return null;
  }

  const vin = parts[baseParts.length];
  const section = parts[baseParts.length + 1];
  if (!vin || !section || !(SECTIONS as string[]).includes(section)) return null;

  return { vin, section: section as Section, rest: parts.slice(baseParts.length + 2) };
}

/**
 * Decodes a raw MQTT payload: JSON-parses it, then unwraps Tesla's
 * protobuf-JSON wrapper objects (`{"doubleValue": 1}`, `{"locationValue": {...}}`,
 * etc.) down to their plain value. `"invalid"` / `{"invalid": true}` become null.
 */
export function decodePayload(raw: Buffer | string): unknown {
  const text = typeof raw === "string" ? raw : raw.toString("utf8");

  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    value = text;
  }

  return unwrap(value);
}

function unwrap(value: unknown): unknown {
  if (value === "invalid") return null;
  if (value === null || typeof value !== "object" || Array.isArray(value)) return value;

  const obj = value as Record<string, unknown>;
  const keys = Object.keys(obj);
  if (keys.length !== 1) return value;

  const key = keys[0]!;
  if (key === "invalid" && obj[key] === true) return null;
  if (key.endsWith("Value")) return unwrap(obj[key]);

  return value;
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

/**
 * Reads `field` off `value` (when `value` is an object) and parses it as a
 * date; falls back to `fallback` when the field is missing, not a string, or
 * not a parseable date.
 */
function atFromField(value: unknown, field: string, fallback: Date): Date {
  if (isPlainObject(value)) {
    const raw = value[field];
    if (typeof raw === "string") {
      const parsed = new Date(raw);
      if (!Number.isNaN(parsed.getTime())) return parsed;
    }
  }
  return fallback;
}

/**
 * Tesla's fleet-telemetry connectivity payload is
 * `{"ConnectionId":"...","Status":"CONNECTED"|"DISCONNECTED"|"UNKNOWN","CreatedAt":"..."}`.
 * A bare status string is also accepted (older/synthetic payloads). Anything
 * else — wrong shape, wrong type, missing field — normalizes to "UNKNOWN"
 * rather than throwing.
 */
function connectivityStatus(value: unknown): "CONNECTED" | "DISCONNECTED" | "UNKNOWN" {
  const raw = isPlainObject(value) ? value.Status : value;
  const status = typeof raw === "string" ? raw.toUpperCase() : undefined;
  return status === "CONNECTED" || status === "DISCONNECTED" ? status : "UNKNOWN";
}

/**
 * Tesla's alert payload is
 * `{"Name":"...","StartedAt":"...","EndedAt":string|null,"Audiences":[...]}`;
 * an alert is active while `EndedAt` is unset. A bare truthy/boolean payload
 * is also accepted (older/synthetic payloads).
 */
function alertFromPayload(value: unknown, receivedAt: Date): { active: boolean; at: Date } {
  if (isPlainObject(value) && "EndedAt" in value) {
    return { active: !value.EndedAt, at: atFromField(value, "StartedAt", receivedAt) };
  }
  const active = value === true || value === "true" || value === 1;
  return { active, at: receivedAt };
}

/**
 * Tesla's error payload is `{"Name":"...","Body":"...","Tags":{...},"CreatedAt":"..."}`.
 * Anything else is stringified as the body.
 */
function errorFromPayload(value: unknown, receivedAt: Date): { body: string; at: Date } {
  if (isPlainObject(value)) {
    const body = typeof value.Body === "string" ? value.Body : JSON.stringify(value);
    return { body, at: atFromField(value, "CreatedAt", receivedAt) };
  }
  const body = typeof value === "string" ? value : JSON.stringify(value);
  return { body, at: receivedAt };
}

/**
 * The single topic-parse + payload-decode path shared by the MQTT source and
 * its tests: splits `topic` under `base`, decodes `raw`, and maps the result
 * onto a `BridgeEvent`. Returns null for topics outside `base` or an
 * unrecognized section/missing name segment. Never throws on a malformed
 * payload — unrecognized shapes fall back to "UNKNOWN" status / inactive
 * alerts / stringified error bodies, with `at` from the payload's own
 * timestamp field when parseable, else `receivedAt`.
 */
export function toBridgeEvent(
  topic: string,
  raw: Buffer | string,
  base: string,
  receivedAt: Date,
): BridgeEvent | null {
  const parsed = parseTopic(topic, base);
  if (!parsed) return null;

  const { vin, section, rest } = parsed;
  const value = decodePayload(raw);

  switch (section) {
    case "v": {
      const name = rest[0];
      if (!name) return null;
      return { kind: "field", vin, name, value, at: receivedAt };
    }
    case "connectivity":
      return { kind: "connectivity", vin, status: connectivityStatus(value), at: atFromField(value, "CreatedAt", receivedAt) };
    case "alerts": {
      const name = rest[0];
      if (!name) return null;
      const { active, at } = alertFromPayload(value, receivedAt);
      return { kind: "alert", vin, name, active, at };
    }
    case "errors": {
      const name = rest[0];
      if (!name) return null;
      const { body, at } = errorFromPayload(value, receivedAt);
      return { kind: "error", vin, name, body, at };
    }
    default:
      return null;
  }
}
