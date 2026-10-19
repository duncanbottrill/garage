import { describe, it, expect, afterEach } from "vitest";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { readFqdn } from "../src/fqdn";

describe("readFqdn", () => {
  let dir: string | undefined;

  afterEach(() => {
    if (dir) rmSync(dir, { recursive: true, force: true });
    dir = undefined;
  });

  function fileWith(content: string): string {
    dir = mkdtempSync(path.join(tmpdir(), "fqdn-"));
    const file = path.join(dir, "fqdn");
    writeFileSync(file, content);
    return file;
  }

  it("returns the trimmed FQDN from the file", () => {
    const file = fileWith("garage-bridge.tail068c8f.ts.net\n");
    expect(readFqdn(file)).toBe("garage-bridge.tail068c8f.ts.net");
  });

  it("throws when the content doesn't match <host>.<tailnet>.ts.net", () => {
    const file = fileWith("not-a-valid-fqdn");
    expect(() => readFqdn(file)).toThrow(/invalid tailnet FQDN/);
  });

  it("throws on an empty file", () => {
    const file = fileWith("");
    expect(() => readFqdn(file)).toThrow();
  });

  it("throws when the file does not exist", () => {
    dir = mkdtempSync(path.join(tmpdir(), "fqdn-"));
    const missing = path.join(dir, "missing");
    expect(() => readFqdn(missing)).toThrow();
  });

  it("rejects a bare hostname with no tailnet segment", () => {
    const file = fileWith("garage-bridge.ts.net");
    expect(() => readFqdn(file)).toThrow();
  });
});
