export type BudgetMode = "normal" | "reduced" | "minimal";
export type UsageCategory = "signals" | "commands" | "data" | "wakes";

export interface VehicleStateRow {
  vehicle_id: string; owner_id: string;
  soc?: number | null; range_km?: number | null; charge_state?: string | null; charger_power_kw?: number | null;
  charge_limit_soc?: number | null; charge_port_open?: boolean | null; scheduled_charge_at?: string | null; charge_at?: string | null;
  inside_c?: number | null; outside_c?: number | null; hvac_on?: boolean | null; climate_keeper?: string | null; climate_at?: string | null;
  lat?: number | null; lng?: number | null; heading?: number | null; speed_kph?: number | null; gear?: string | null; odometer_km?: number | null; location_at?: string | null;
  locked?: boolean | null; doors?: Record<string, boolean> | null; windows?: Record<string, boolean> | null; frunk_open?: boolean | null; trunk_open?: boolean | null; body_at?: string | null;
  tpms_bar?: Record<string, number> | null; sentry?: boolean | null;
  sleep_state?: string | null; software_version?: string | null; bridge_seen_at?: string | null; bridge_health?: Record<string, unknown> | null;
  updated_at?: string;
}
