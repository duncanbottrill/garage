import { describe, it, expect } from "vitest";
import { costUsd, projectMonthSpend, budgetModeFor } from "../src/budget";
describe("budget", () => {
  it("prices per Tesla table", () => { expect(costUsd({ signals: 150_000, commands: 1_000, data: 500, wakes: 50 })).toBeCloseTo(4, 6); });
  it("projects linearly across the month", () => {
    const d = new Date(Date.UTC(2026, 9, 10)); // 10 Oct, 31-day month
    expect(projectMonthSpend({ commands: 1_000 }, d)).toBeCloseTo(3.1, 6);
  });
  it("maps thresholds", () => {
    expect(budgetModeFor(6.9, 10)).toBe("normal"); expect(budgetModeFor(7, 10)).toBe("reduced"); expect(budgetModeFor(9, 10)).toBe("minimal");
  });
});
