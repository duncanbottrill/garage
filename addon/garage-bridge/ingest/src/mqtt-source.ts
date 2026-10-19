import mqtt, { type MqttClient } from "mqtt";
import { decodePayload, parseTopic, type ParsedTopic } from "./decode";
import type { BridgeEvent } from "./state";

export type MqttStatus = "connecting" | "connected" | "reconnecting" | "offline" | "error";

export interface MqttSourceOptions {
  url: string;
  username?: string;
  password?: string;
  base: string;
  vin: string;
  onEvent: (ev: BridgeEvent) => void;
  onStatus?: (status: MqttStatus, detail?: unknown) => void;
}

export interface MqttSource {
  stop: () => void;
}

/**
 * Subscribes to `<base>/<vin>/#` (QoS 1) on the broker at `url` and turns every
 * message into a `BridgeEvent` via `decode.ts`'s topic/payload helpers,
 * handing each one to `onEvent`. mqtt.js owns reconnection (5s backoff);
 * `onStatus` is purely informational for logging/health.
 */
export function startMqttSource(opts: MqttSourceOptions): MqttSource {
  const client: MqttClient = mqtt.connect(opts.url, {
    username: opts.username,
    password: opts.password,
    reconnectPeriod: 5000,
    clientId: "garage-ingest",
  });

  const topic = `${opts.base}/${opts.vin}/#`;

  client.on("connect", () => {
    client.subscribe(topic, { qos: 1 }, (err) => {
      if (err) opts.onStatus?.("error", err);
    });
    opts.onStatus?.("connected");
  });
  client.on("reconnect", () => opts.onStatus?.("reconnecting"));
  client.on("close", () => opts.onStatus?.("offline"));
  client.on("error", (err) => opts.onStatus?.("error", err));

  client.on("message", (receivedTopic, payload) => {
    const parsed = parseTopic(receivedTopic, opts.base);
    if (!parsed || parsed.vin !== opts.vin) return;

    const value = decodePayload(payload);
    const ev = toBridgeEvent(parsed, value, new Date());
    if (ev) opts.onEvent(ev);
  });

  return {
    stop: () => {
      client.end(true);
    },
  };
}

function toBridgeEvent(parsed: ParsedTopic, value: unknown, at: Date): BridgeEvent | null {
  const { vin, section, rest } = parsed;

  switch (section) {
    case "v": {
      const name = rest[0];
      if (!name) return null;
      return { kind: "field", vin, name, value, at };
    }
    case "connectivity": {
      const status = typeof value === "string" ? value : String(value);
      const normalized = status === "CONNECTED" || status === "DISCONNECTED" ? status : "UNKNOWN";
      return { kind: "connectivity", vin, status: normalized, at };
    }
    case "alerts": {
      // garage/<VIN>/alerts/<name>/current
      const name = rest[0];
      if (!name) return null;
      const active = value === true || value === "true" || value === 1;
      return { kind: "alert", vin, name, active, at };
    }
    case "errors": {
      const name = rest[0];
      if (!name) return null;
      const body = typeof value === "string" ? value : JSON.stringify(value);
      return { kind: "error", vin, name, body, at };
    }
    default:
      return null;
  }
}
