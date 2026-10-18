import type { BudgetMode, UsageCategory } from "./types";
export const PRICES_USD_PER_UNIT: Record<UsageCategory, number> = { signals: 1 / 150_000, commands: 1 / 1_000, data: 1 / 500, wakes: 1 / 50 };
export function costUsd(counts: Partial<Record<UsageCategory, number>>): number {
  return (Object.keys(PRICES_USD_PER_UNIT) as UsageCategory[]).reduce((s, k) => s + (counts[k] ?? 0) * PRICES_USD_PER_UNIT[k], 0);
}
export function projectMonthSpend(counts: Partial<Record<UsageCategory, number>>, now: Date): number {
  const day = now.getUTCDate();
  const daysInMonth = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 0)).getUTCDate();
  return costUsd(counts) * (daysInMonth / Math.max(day, 1));
}
export function budgetModeFor(projectedUsd: number, budgetUsd: number): BudgetMode {
  const r = projectedUsd / budgetUsd;
  return r >= 0.9 ? "minimal" : r >= 0.7 ? "reduced" : "normal";
}
