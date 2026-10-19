import mqtt, { type MqttClient } from "mqtt";
import { toBridgeEvent } from "./decode";
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

const MIN_RECONNECT_MS = 1000;
const MAX_RECONNECT_MS = 30_000;

/**
 * Subscribes to `<base>/<vin>/#` (QoS 1) on the broker at `url` and turns every
 * message into a `BridgeEvent` via `decode.ts`'s topic/payload helpers,
 * handing each one to `onEvent`. Uses a persistent session (`clean: false`)
 * so queued QoS-1 messages survive a reconnect, and backs off its own
 * reconnect attempts from 1s up to a 30s cap (mqtt.js has no built-in
 * exponential backoff), resetting to 1s on every successful connect.
 * `onStatus` is purely informational for logging/health.
 */
export function startMqttSource(opts: MqttSourceOptions): MqttSource {
  let reconnectMs = MIN_RECONNECT_MS;

  const client: MqttClient = mqtt.connect(opts.url, {
    username: opts.username,
    password: opts.password,
    clean: false,
    reconnectPeriod: MIN_RECONNECT_MS,
    clientId: "garage-ingest",
  });

  const topic = `${opts.base}/${opts.vin}/#`;

  client.on("connect", () => {
    reconnectMs = MIN_RECONNECT_MS;
    client.options.reconnectPeriod = MIN_RECONNECT_MS;
    client.subscribe(topic, { qos: 1 }, (err) => {
      if (err) opts.onStatus?.("error", err);
    });
    opts.onStatus?.("connected");
  });
  client.on("reconnect", () => {
    opts.onStatus?.("reconnecting");
    reconnectMs = Math.min(reconnectMs * 2, MAX_RECONNECT_MS);
    client.options.reconnectPeriod = reconnectMs;
  });
  client.on("close", () => opts.onStatus?.("offline"));
  client.on("error", (err) => opts.onStatus?.("error", err));

  client.on("message", (receivedTopic, payload) => {
    try {
      const ev = toBridgeEvent(receivedTopic, payload, opts.base, new Date());
      if (ev && ev.vin === opts.vin) opts.onEvent(ev);
    } catch (err) {
      opts.onStatus?.("error", err);
    }
  });

  return {
    stop: () => {
      client.end(true);
    },
  };
}
