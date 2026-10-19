import { describe, it, expect, vi } from "vitest";
import { Batcher } from "../src/batcher";

describe("Batcher", () => {
  it("flushes once pending reaches maxRows", async () => {
    const onFlush = vi.fn().mockResolvedValue(undefined);
    const batcher = new Batcher<number>({ maxRows: 200, maxAgeMs: 2000, onFlush });

    const t0 = 1_000_000;
    for (let i = 0; i < 200; i++) batcher.push(i, t0);

    await batcher.flushIfDue(t0);

    expect(onFlush).toHaveBeenCalledTimes(1);
    expect(onFlush.mock.calls[0]![0]).toHaveLength(200);
    expect(batcher.stats()).toEqual({ pending: 0, dropped: 0, flushed: 200 });
  });

  it("does not flush before maxRows or maxAgeMs are reached", async () => {
    const onFlush = vi.fn().mockResolvedValue(undefined);
    const batcher = new Batcher<number>({ maxRows: 200, maxAgeMs: 2000, onFlush });

    const t0 = 1_000_000;
    batcher.push(1, t0);
    batcher.push(2, t0);

    await batcher.flushIfDue(t0 + 1000);

    expect(onFlush).not.toHaveBeenCalled();
    expect(batcher.stats().pending).toBe(2);
  });

  it("flushes once the oldest pending item reaches maxAgeMs", async () => {
    const onFlush = vi.fn().mockResolvedValue(undefined);
    const batcher = new Batcher<number>({ maxRows: 200, maxAgeMs: 2000, onFlush });

    const t0 = 1_000_000;
    batcher.push(1, t0);
    batcher.push(2, t0 + 500);

    await batcher.flushIfDue(t0 + 1999);
    expect(onFlush).not.toHaveBeenCalled();

    await batcher.flushIfDue(t0 + 2000);
    expect(onFlush).toHaveBeenCalledTimes(1);
    expect(onFlush.mock.calls[0]![0]).toEqual([1, 2]);
    expect(batcher.stats()).toEqual({ pending: 0, dropped: 0, flushed: 2 });
  });

  it("retains rows and retries when onFlush rejects", async () => {
    const onFlush = vi.fn().mockRejectedValueOnce(new Error("boom")).mockResolvedValueOnce(undefined);
    const batcher = new Batcher<number>({ maxRows: 2, maxAgeMs: 2000, onFlush });

    const t0 = 1_000_000;
    batcher.push(1, t0);
    batcher.push(2, t0);

    await batcher.flushIfDue(t0);
    expect(onFlush).toHaveBeenCalledTimes(1);
    expect(batcher.stats()).toEqual({ pending: 2, dropped: 0, flushed: 0 });

    await batcher.flushIfDue(t0 + 10);
    expect(onFlush).toHaveBeenCalledTimes(2);
    expect(onFlush.mock.calls[1]![0]).toEqual([1, 2]);
    expect(batcher.stats()).toEqual({ pending: 0, dropped: 0, flushed: 2 });
  });

  it("prepends retained rows ahead of newly pushed ones on retry", async () => {
    const onFlush = vi.fn().mockRejectedValueOnce(new Error("boom")).mockResolvedValueOnce(undefined);
    const batcher = new Batcher<string>({ maxRows: 2, maxAgeMs: 2000, onFlush });

    const t0 = 1_000_000;
    batcher.push("a", t0);
    batcher.push("b", t0);
    await batcher.flushIfDue(t0);

    batcher.push("c", t0 + 50);
    await batcher.flushIfDue(t0 + 2050);

    expect(onFlush.mock.calls[1]![0]).toEqual(["a", "b", "c"]);
  });

  it("drops the oldest rows once the buffer spans more than maxBufferMs", async () => {
    const onFlush = vi.fn().mockResolvedValue(undefined);
    const batcher = new Batcher<string>({
      maxRows: 200,
      maxAgeMs: 2000,
      maxBufferMs: 300_000,
      onFlush,
    });

    const t0 = 1_000_000;
    batcher.push("old-1", t0);
    batcher.push("old-2", t0 + 1_000);
    batcher.push("fresh", t0 + 301_001);

    // Not yet due to flush (maxRows/maxAgeMs not hit relative to "fresh"'s own age),
    // but the stale-drop check runs on every flushIfDue call.
    await batcher.flushIfDue(t0 + 301_001);

    const stats = batcher.stats();
    expect(stats.dropped).toBe(2);
    expect(stats.pending).toBe(1);
  });

  it("reports flushed/dropped/pending counters cumulatively", async () => {
    const onFlush = vi.fn().mockResolvedValue(undefined);
    const batcher = new Batcher<number>({ maxRows: 2, maxAgeMs: 2000, maxBufferMs: 300_000, onFlush });

    const t0 = 1_000_000;
    batcher.push(1, t0);
    batcher.push(2, t0);
    await batcher.flushIfDue(t0);
    expect(batcher.stats()).toEqual({ pending: 0, dropped: 0, flushed: 2 });

    batcher.push(3, t0 + 1_000_000);
    batcher.push(4, t0 + 1_000_000);
    await batcher.flushIfDue(t0 + 1_000_000);
    expect(batcher.stats()).toEqual({ pending: 0, dropped: 0, flushed: 4 });
  });

  it("flush() flushes everything pending regardless of maxRows/maxAgeMs", async () => {
    const onFlush = vi.fn().mockResolvedValue(undefined);
    const batcher = new Batcher<number>({ maxRows: 200, maxAgeMs: 2000, onFlush });

    batcher.push(1);
    batcher.push(2);

    await batcher.flush();

    expect(onFlush).toHaveBeenCalledTimes(1);
    expect(onFlush.mock.calls[0]![0]).toEqual([1, 2]);
    expect(batcher.stats()).toEqual({ pending: 0, dropped: 0, flushed: 2 });
  });

  it("flush() is a no-op when the buffer is empty", async () => {
    const onFlush = vi.fn().mockResolvedValue(undefined);
    const batcher = new Batcher<number>({ onFlush });

    await batcher.flush();

    expect(onFlush).not.toHaveBeenCalled();
  });

  it("flush() waits for an in-flight flushIfDue flush before running its own", async () => {
    let resolveFirst: (() => void) | undefined;
    const firstFlush = new Promise<void>((resolve) => {
      resolveFirst = resolve;
    });
    const onFlush = vi.fn().mockImplementationOnce(() => firstFlush).mockResolvedValueOnce(undefined);
    const batcher = new Batcher<number>({ maxRows: 1, maxAgeMs: 2000, onFlush });

    batcher.push(1);
    const flushIfDuePromise = batcher.flushIfDue(); // buffer at maxRows: starts flushing [1], onFlush pending

    batcher.push(2); // pushed while the first flush is still in flight

    const flushPromise = batcher.flush(); // must wait for the in-flight flush, then flush [2]
    resolveFirst?.();

    await flushIfDuePromise;
    await flushPromise;

    expect(onFlush).toHaveBeenCalledTimes(2);
    expect(onFlush.mock.calls[0]![0]).toEqual([1]);
    expect(onFlush.mock.calls[1]![0]).toEqual([2]);
    expect(batcher.stats()).toEqual({ pending: 0, dropped: 0, flushed: 2 });
  });
});
