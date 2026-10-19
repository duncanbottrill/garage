import { describe, it, expect, vi } from "vitest";
import { createPatchAccumulator, runShutdownFlush, type Logger } from "../src/index";
import { Health } from "../src/health";
import type { Sink } from "../src/supabase-sink";

function fakeLog(): { log: Logger; calls: Array<[string, string, Record<string, unknown> | undefined]> } {
  const calls: Array<[string, string, Record<string, unknown> | undefined]> = [];
  const log: Logger = (level, msg, extra) => {
    calls.push([level, msg, extra]);
  };
  return { log, calls };
}

describe("shutdown flush (fake sink)", () => {
  it("flushes the pending state patch via the sink's mergeState on shutdown", async () => {
    const mergeState = vi.fn().mockResolvedValue(undefined);
    const sink = { mergeState } as unknown as Pick<Sink, "mergeState">;
    const health = new Health();
    const { log } = fakeLog();

    const patchAccumulator = createPatchAccumulator(sink, health, log);
    patchAccumulator.merge({ doors: { fl: true } });
    patchAccumulator.merge({ bridge_seen_at: "2026-10-19T00:00:00.000Z" });

    const rowBatcher = { flush: vi.fn().mockResolvedValue({ ok: true }) };

    await runShutdownFlush(rowBatcher, patchAccumulator, log);

    expect(rowBatcher.flush).toHaveBeenCalledTimes(1);
    expect(mergeState).toHaveBeenCalledTimes(1);
    expect(mergeState).toHaveBeenCalledWith({ doors: { fl: true }, bridge_seen_at: "2026-10-19T00:00:00.000Z" });
  });

  it("still flushes the pending patch when the row batcher reports a failure, and logs 'final flush failed'", async () => {
    const mergeState = vi.fn().mockResolvedValue(undefined);
    const sink = { mergeState } as unknown as Pick<Sink, "mergeState">;
    const health = new Health();
    const { log, calls } = fakeLog();

    const patchAccumulator = createPatchAccumulator(sink, health, log);
    patchAccumulator.merge({ doors: { fl: true } });

    const rowBatcherError = new Error("signals insert failed");
    const rowBatcher = { flush: vi.fn().mockResolvedValue({ ok: false, error: rowBatcherError }) };

    await runShutdownFlush(rowBatcher, patchAccumulator, log);

    expect(calls.some(([level, msg]) => level === "error" && msg === "final flush failed")).toBe(true);
    expect(mergeState).toHaveBeenCalledTimes(1);
    expect(mergeState).toHaveBeenCalledWith({ doors: { fl: true } });
  });

  it("logs 'final flush failed' if rowBatcher.flush() itself throws, and still flushes the pending patch", async () => {
    const mergeState = vi.fn().mockResolvedValue(undefined);
    const sink = { mergeState } as unknown as Pick<Sink, "mergeState">;
    const health = new Health();
    const { log, calls } = fakeLog();

    const patchAccumulator = createPatchAccumulator(sink, health, log);
    patchAccumulator.merge({ bridge_health: { received: 1 } });

    const rowBatcher = { flush: vi.fn().mockRejectedValue(new Error("unexpected")) };

    await runShutdownFlush(rowBatcher, patchAccumulator, log);

    expect(calls.some(([level, msg]) => level === "error" && msg === "final flush failed")).toBe(true);
    expect(mergeState).toHaveBeenCalledTimes(1);
  });

  it("does not call mergeState when there is no pending patch", async () => {
    const mergeState = vi.fn();
    const sink = { mergeState } as unknown as Pick<Sink, "mergeState">;
    const health = new Health();
    const { log } = fakeLog();

    const patchAccumulator = createPatchAccumulator(sink, health, log);
    const rowBatcher = { flush: vi.fn().mockResolvedValue({ ok: true }) };

    await runShutdownFlush(rowBatcher, patchAccumulator, log);

    expect(mergeState).not.toHaveBeenCalled();
  });

  it("drops a failed patch and records it via Health.patchFailed rather than re-queuing it", async () => {
    const mergeState = vi.fn().mockRejectedValue(new Error("rpc boom"));
    const sink = { mergeState } as unknown as Pick<Sink, "mergeState">;
    const health = new Health();
    const { log } = fakeLog();

    const patchAccumulator = createPatchAccumulator(sink, health, log);
    patchAccumulator.merge({ doors: { fl: true } });

    await patchAccumulator.flush();
    expect(health.payload().patch_failures).toBe(1);

    // A second flush with nothing newly merged must not re-send the dropped patch.
    await patchAccumulator.flush();
    expect(mergeState).toHaveBeenCalledTimes(1);
  });
});
