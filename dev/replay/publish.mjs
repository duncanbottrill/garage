#!/usr/bin/env node
// Replays the Task 3 ingest fixtures
// (addon/garage-bridge/ingest/test/fixtures/mqtt-samples.json) over MQTT for
// dev/e2e-bridge.sh, with every fixture's VIN swapped to the e2e harness
// VIN, spread over ~REPLAY_DURATION_MS, QoS 1.
//
// Finishes with one extra message: a Tesla-shaped connectivity object
// (`{ConnectionId,Status,CreatedAt}`, same shape as the fixtures' own
// `connectivity-connected`/`connectivity-disconnected` samples — the real
// fleet-telemetry dispatcher payload, not a bare string) with
// `Status: "CONNECTED"` on `<base>/<vin>/connectivity`. `decode.ts`'s
// `toBridgeEvent` reads `Status` off that object (uppercased; a bare status
// string is still accepted too), so this proves sleep_state -> "online" via
// the real payload shape end to end. It also happens to run after
// `connectivity-disconnected`, which would otherwise have been the last
// connectivity write.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
import mqtt from "mqtt";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, "../..");

const MQTT_URL = process.env.MQTT_URL ?? "mqtt://127.0.0.1:1883";
const VIN = process.env.REPLAY_VIN ?? "XP7YE2E000000001";
const DURATION_MS = Number(process.env.REPLAY_DURATION_MS ?? 10_000);
const FIXTURES_PATH =
  process.env.FIXTURES_PATH ?? path.join(REPO_ROOT, "addon/garage-bridge/ingest/test/fixtures/mqtt-samples.json");
// The VIN baked into the fixtures file (Task 3's sample data).
const SOURCE_VIN = "XP7YGCEL9PB123456";

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  const fixtures = JSON.parse(readFileSync(FIXTURES_PATH, "utf8"));
  if (!Array.isArray(fixtures) || fixtures.length === 0) {
    throw new Error(`no fixtures found at ${FIXTURES_PATH}`);
  }

  const messages = fixtures.map((f) => ({
    id: f.id,
    topic: f.topic.replaceAll(SOURCE_VIN, VIN),
    payload: f.payload,
  }));

  messages.push({
    id: "replay-final-connectivity-connected",
    topic: `garage/${VIN}/connectivity`,
    payload: JSON.stringify({
      ConnectionId: "replay-final",
      Status: "CONNECTED",
      CreatedAt: new Date().toISOString(),
    }),
  });

  console.log(`[replay] connecting to ${MQTT_URL}`);
  const client = await mqtt.connectAsync(MQTT_URL, {
    clientId: `garage-e2e-replay-${Date.now()}`,
    clean: true,
  });
  console.log(`[replay] connected; publishing ${messages.length} messages over ~${DURATION_MS}ms (VIN ${VIN})`);

  const intervalMs = messages.length > 1 ? DURATION_MS / (messages.length - 1) : 0;

  for (let i = 0; i < messages.length; i++) {
    const msg = messages[i];
    await client.publishAsync(msg.topic, msg.payload, { qos: 1 });
    console.log(`[replay] published ${msg.id} -> ${msg.topic}`);
    if (i < messages.length - 1 && intervalMs > 0) {
      await sleep(intervalMs);
    }
  }

  await client.endAsync();
  console.log("[replay] done");
}

main().catch((err) => {
  console.error(`[replay] FAILED: ${err instanceof Error ? err.stack : String(err)}`);
  process.exit(1);
});
