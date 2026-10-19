import { readFileSync } from "node:fs";

const FQDN_PATTERN = /^[a-z0-9-]+\.[a-z0-9-]+\.ts\.net$/;

/**
 * Reads the tailnet FQDN written by the `tlscert` rootfs service once
 * `tailscale cert` has run. The file already contains the full name (e.g.
 * `garage-bridge.tail068c8f.ts.net`) — this trims it and throws unless it
 * matches the expected `<host>.<tailnet>.ts.net` shape, so a malformed or
 * truncated write never silently propagates into a telemetry config POST.
 */
export function readFqdn(path = "/data/tailscale/fqdn"): string {
  const fqdn = readFileSync(path, "utf8").trim();
  if (!FQDN_PATTERN.test(fqdn)) {
    throw new Error(`invalid tailnet FQDN in ${path}: ${JSON.stringify(fqdn)}`);
  }
  return fqdn;
}
