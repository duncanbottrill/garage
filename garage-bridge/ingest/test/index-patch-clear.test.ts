import { describe, it, expect, vi } from "vitest";
import { createPatchAccumulator, type Logger } from "../src/index";
import { Health } from "../src/health";
import type { Sink } from "../src/supabase-sink";

const log: Logger = () => {};

function accumulator(mergeState = vi.fn().mockResolvedValue(undefined)) {
  const sink = { mergeState } as unknown as Pick<Sink, "mergeState">;
  return { acc: createPatchAccumulator(sink, new Health(), log), mergeState };
}

describe("patch accumulator: set/clear semantics", () => {
  it("flushes a pending clear as mergeState(patch, clear)", async () => {
    const { acc, mergeState } = accumulator();
    acc.merge({ soc: 80 });
    acc.merge({}, ["scheduled_charge_at"]);
    await acc.flush();
    expect(mergeState).toHaveBeenCalledTimes(1);
    expect(mergeState).toHaveBeenCalledWith({ soc: 80 }, ["scheduled_charge_at"]);
  });

  it("flushes a clear with nothing else pending", async () => {
    const { acc, mergeState } = accumulator();
    acc.merge({}, ["scheduled_charge_at"]);
    await acc.flush();
    expect(mergeState).toHaveBeenCalledWith({}, ["scheduled_charge_at"]);
  });

  it("a later value for a cleared key wins over the clear", async () => {
    const { acc, mergeState } = accumulator();
    acc.merge({}, ["scheduled_charge_at"]);
    acc.merge({ scheduled_charge_at: "2026-10-22T01:00:00.000Z" });
    await acc.flush();
    expect(mergeState).toHaveBeenCalledWith({ scheduled_charge_at: "2026-10-22T01:00:00.000Z" });
  });

  it("a later clear removes the pending value for that key", async () => {
    const { acc, mergeState } = accumulator();
    acc.merge({ scheduled_charge_at: "2026-10-22T01:00:00.000Z", soc: 80 });
    acc.merge({}, ["scheduled_charge_at"]);
    await acc.flush();
    expect(mergeState).toHaveBeenCalledWith({ soc: 80 }, ["scheduled_charge_at"]);
  });

  it("passes no clear argument when nothing is cleared (unchanged call shape)", async () => {
    const { acc, mergeState } = accumulator();
    acc.merge({ soc: 80 }, []);
    await acc.flush();
    expect(mergeState.mock.calls).toEqual([[{ soc: 80 }]]);
  });

  it("re-queues a failed clear underneath newer data: a newer value for the key wins", async () => {
    const mergeState = vi.fn().mockRejectedValueOnce(new Error("blip")).mockResolvedValue(undefined);
    const { acc } = accumulator(mergeState);
    acc.merge({ soc: 80 }, ["scheduled_charge_at"]);
    await acc.flush();
    acc.merge({ scheduled_charge_at: "2026-10-22T01:00:00.000Z" });
    await acc.flush();
    expect(mergeState).toHaveBeenCalledTimes(2);
    expect(mergeState.mock.calls[1]).toEqual([{ soc: 80, scheduled_charge_at: "2026-10-22T01:00:00.000Z" }]);
  });

  it("re-queues a failed value underneath a newer clear: the clear wins", async () => {
    const mergeState = vi.fn().mockRejectedValueOnce(new Error("blip")).mockResolvedValue(undefined);
    const { acc } = accumulator(mergeState);
    acc.merge({ scheduled_charge_at: "2026-10-22T01:00:00.000Z", soc: 80 });
    await acc.flush();
    acc.merge({}, ["scheduled_charge_at"]);
    await acc.flush();
    expect(mergeState.mock.calls[1]).toEqual([{ soc: 80 }, ["scheduled_charge_at"]]);
  });
});
