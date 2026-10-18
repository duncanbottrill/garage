import { projectMonthSpend, budgetModeFor, type UsageCategory } from "@garage/core";
import { serviceClient } from "./supabase";
export async function runBudget(o: { now?: Date; budgetUsd?: number } = {}) {
  const now = o.now ?? new Date(), budget = o.budgetUsd ?? 10, sb = serviceClient();
  const month = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString().slice(0, 10);
  const { data: usage, error } = await sb.from("api_usage").select("owner_id, category, count").eq("month", month); if (error) throw error;
  const byOwner = new Map<string, Partial<Record<UsageCategory, number>>>();
  for (const r of usage ?? []) { const m = byOwner.get(r.owner_id) ?? {}; m[r.category as UsageCategory] = Number(r.count); byOwner.set(r.owner_id, m); }
  const { data: vehicles, error: vErr } = await sb.from("vehicles").select("id, owner_id, budget_mode"); if (vErr) throw vErr;
  const out: Array<{ vehicle_id: string; owner_id: string; projected_usd: number; mode: string; error?: string }> = [];
  for (const v of vehicles ?? []) {
    const projected = projectMonthSpend(byOwner.get(v.owner_id) ?? {}, now); const mode = budgetModeFor(projected, budget);
    let persisted = mode;
    if (mode !== v.budget_mode) {
      const { error: wErr } = await sb.rpc("set_budget_mode", { p_vehicle: v.id, p_mode: mode });
      if (wErr) { console.error("budget-cron: set_budget_mode failed", { vehicle_id: v.id, message: wErr.message }); persisted = v.budget_mode; out.push({ vehicle_id: v.id, owner_id: v.owner_id, projected_usd: +projected.toFixed(4), mode: persisted, error: wErr.message }); continue; }
    }
    out.push({ vehicle_id: v.id, owner_id: v.owner_id, projected_usd: +projected.toFixed(4), mode: persisted });
  }
  return out;
}
