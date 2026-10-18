import type { VehicleStateRow } from "../types";
export const milesToKm = (mi: number) => mi * 1.609344;
export const psiToBar = (psi: number) => psi * 0.0689476;
export interface VehicleDataResponse {
  state?: string; vehicle_state?: any; charge_state?: any; climate_state?: any; drive_state?: any;
}
export function vehicleDataToState(p: VehicleDataResponse, at: Date): Partial<VehicleStateRow> {
  const iso = at.toISOString(); const cs = p.charge_state ?? {}, cl = p.climate_state ?? {}, ds = p.drive_state ?? {}, vs = p.vehicle_state ?? {};
  const out: Partial<VehicleStateRow> = { updated_at: iso };
  if (cs.battery_level != null) { out.soc = cs.battery_level; out.charge_at = iso; }
  if (cs.battery_range != null) out.range_km = milesToKm(cs.battery_range);
  if (cs.charging_state != null) out.charge_state = String(cs.charging_state).toLowerCase();
  if (cs.charger_power != null) out.charger_power_kw = cs.charger_power;
  if (cs.charge_limit_soc != null) out.charge_limit_soc = cs.charge_limit_soc;
  if (cs.charge_port_door_open != null) out.charge_port_open = !!cs.charge_port_door_open;
  if (cl.inside_temp != null) { out.inside_c = cl.inside_temp; out.climate_at = iso; }
  if (cl.outside_temp != null) out.outside_c = cl.outside_temp;
  if (cl.is_climate_on != null) out.hvac_on = !!cl.is_climate_on;
  if (cl.climate_keeper_mode != null) out.climate_keeper = cl.climate_keeper_mode;
  if (ds.latitude != null && ds.longitude != null) { out.lat = ds.latitude; out.lng = ds.longitude; out.location_at = iso; }
  if (ds.heading != null) out.heading = ds.heading;
  if (ds.speed != null) out.speed_kph = milesToKm(ds.speed); else if (ds.shift_state !== undefined) out.speed_kph = 0;
  if (ds.shift_state !== undefined) out.gear = ds.shift_state ?? "P";
  if (vs.odometer != null) out.odometer_km = milesToKm(vs.odometer);
  if (vs.locked != null) { out.locked = !!vs.locked; out.body_at = iso; }
  if (vs.df != null) out.doors = { fl: !!vs.df, fr: !!vs.pf, rl: !!vs.dr, rr: !!vs.pr };
  if (vs.fd_window != null) out.windows = { fl: !!vs.fd_window, fr: !!vs.fp_window, rl: !!vs.rd_window, rr: !!vs.rp_window };
  if (vs.ft != null) out.frunk_open = !!vs.ft; if (vs.rt != null) out.trunk_open = !!vs.rt;
  if (vs.tpms_pressure_fl != null) out.tpms_bar = { fl: vs.tpms_pressure_fl, fr: vs.tpms_pressure_fr, rl: vs.tpms_pressure_rl, rr: vs.tpms_pressure_rr };
  if (vs.sentry_mode != null) out.sentry = !!vs.sentry_mode;
  if (vs.car_version != null) out.software_version = String(vs.car_version).split(" ")[0];
  if (p.state != null) out.sleep_state = p.state; // 'online' | 'asleep' | 'offline'
  return out;
}
