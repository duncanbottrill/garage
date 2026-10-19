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
