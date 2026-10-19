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

  it("re-queues a failed patch underneath newer data (newer values win) and resends it on the next flush", async () => {
    const mergeState = vi.fn().mockRejectedValueOnce(new Error("rpc boom")).mockResolvedValue(undefined);
    const sink = { mergeState } as unknown as Pick<Sink, "mergeState">;
    const health = new Health();
    const { log } = fakeLog();

    const patchAccumulator = createPatchAccumulator(sink, health, log);
    patchAccumulator.merge({ locked: true, body_at: "2026-10-19T00:00:00.000Z", doors: { driver_front: true, passenger_front: false } });

    await patchAccumulator.flush();
    expect(health.payload().patch_failures).toBe(1);

    // Newer state arrives after the failure: it must win over the re-queued values.
    patchAccumulator.merge({ locked: false, doors: { driver_front: false } });
    await patchAccumulator.flush();

    expect(mergeState).toHaveBeenCalledTimes(2);
    expect(mergeState.mock.calls[1]![0]).toEqual({
      locked: false,
      body_at: "2026-10-19T00:00:00.000Z",
      doors: { driver_front: false, passenger_front: false },
    });

    // Delivered: nothing left to resend.
    await patchAccumulator.flush();
    expect(mergeState).toHaveBeenCalledTimes(2);
  });

  it("newer data merged while the failing mergeState call was in flight also wins over the re-queued patch", async () => {
    let rejectFirst: ((err: Error) => void) | undefined;
    const mergeState = vi
      .fn()
      .mockImplementationOnce(() => new Promise<void>((_, reject) => { rejectFirst = reject; }))
      .mockResolvedValue(undefined);
    const sink = { mergeState } as unknown as Pick<Sink, "mergeState">;
    const health = new Health();
    const { log } = fakeLog();

    const patchAccumulator = createPatchAccumulator(sink, health, log);
    patchAccumulator.merge({ gear: "D", soc: 70 });
    const inFlight = patchAccumulator.flush();
    patchAccumulator.merge({ gear: "P" }); // arrives while the first call is in flight
    rejectFirst!(new Error("rpc boom"));
    await inFlight;

    await patchAccumulator.flush();
    expect(mergeState.mock.calls[1]![0]).toEqual({ gear: "P", soc: 70 });
  });

  it("drops a patch after 3 consecutive failures so a permanently rejected patch cannot block forever", async () => {
    const mergeState = vi.fn().mockRejectedValue(new Error("invalid input syntax"));
    const sink = { mergeState } as unknown as Pick<Sink, "mergeState">;
    const health = new Health();
    const { log, calls } = fakeLog();

    const patchAccumulator = createPatchAccumulator(sink, health, log);
    patchAccumulator.merge({ doors: { driver_front: true } });

    await patchAccumulator.flush();
    await patchAccumulator.flush();
    await patchAccumulator.flush();
    expect(mergeState).toHaveBeenCalledTimes(3);
    expect(health.payload().patch_failures).toBe(3);
    expect(calls.some(([level, msg]) => level === "error" && /dropping patch/.test(msg))).toBe(true);

    // Dropped: a further flush with nothing new sends nothing.
    await patchAccumulator.flush();
    expect(mergeState).toHaveBeenCalledTimes(3);

    // The failure count starts over for new data.
    mergeState.mockReset();
    mergeState.mockRejectedValueOnce(new Error("blip")).mockResolvedValue(undefined);
    patchAccumulator.merge({ locked: true });
    await patchAccumulator.flush();
    await patchAccumulator.flush();
    expect(mergeState).toHaveBeenCalledTimes(2);
    expect(mergeState.mock.calls[1]![0]).toEqual({ locked: true });
  });

  it("a success resets the consecutive-failure count", async () => {
    const mergeState = vi
      .fn()
      .mockRejectedValueOnce(new Error("blip 1"))
      .mockRejectedValueOnce(new Error("blip 2"))
      .mockResolvedValueOnce(undefined)
      .mockRejectedValueOnce(new Error("blip 3"))
      .mockRejectedValueOnce(new Error("blip 4"))
      .mockResolvedValue(undefined);
    const sink = { mergeState } as unknown as Pick<Sink, "mergeState">;
    const health = new Health();
    const { log } = fakeLog();

    const patchAccumulator = createPatchAccumulator(sink, health, log);
    patchAccumulator.merge({ soc: 1 });
    await patchAccumulator.flush(); // fail 1
    await patchAccumulator.flush(); // fail 2
    await patchAccumulator.flush(); // success
    patchAccumulator.merge({ soc: 2 });
    await patchAccumulator.flush(); // fail 1 (count was reset)
    await patchAccumulator.flush(); // fail 2
    await patchAccumulator.flush(); // success: not dropped
    expect(mergeState).toHaveBeenCalledTimes(6);
    expect(mergeState.mock.calls[5]![0]).toEqual({ soc: 2 });
  });
});
