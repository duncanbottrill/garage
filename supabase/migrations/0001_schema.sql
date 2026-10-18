create extension if not exists pgcrypto;

create table vehicles (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  vin text not null unique,
  tesla_vehicle_id bigint,
  display_name text not null default 'Model Y',
  model text, trim text, pack_kwh numeric,
  telemetry_config_version int not null default 0,
  telemetry_confirmed_at timestamptz,
  budget_mode text not null default 'normal' check (budget_mode in ('normal','reduced','minimal')),
  created_at timestamptz not null default now()
);

create table vehicle_state (
  vehicle_id uuid primary key references vehicles(id) on delete cascade,
  owner_id uuid not null references auth.users(id) on delete cascade,
  soc numeric, range_km numeric, charge_state text, charger_power_kw numeric, charge_limit_soc int,
  charge_port_open boolean, scheduled_charge_at timestamptz, charge_at timestamptz,
  inside_c numeric, outside_c numeric, hvac_on boolean, climate_keeper text, climate_at timestamptz,
  lat numeric, lng numeric, heading numeric, speed_kph numeric, gear text, odometer_km numeric, location_at timestamptz,
  locked boolean, doors jsonb, windows jsonb, frunk_open boolean, trunk_open boolean, body_at timestamptz,
  tpms_bar jsonb, sentry boolean,
  sleep_state text, software_version text, bridge_seen_at timestamptz, bridge_health jsonb,
  updated_at timestamptz not null default now()
);

create table signals (
  vehicle_id uuid not null references vehicles(id) on delete cascade,
  owner_id uuid not null,
  name text not null,
  value_num numeric, value_text text, value_json jsonb,
  recorded_at timestamptz not null,
  primary key (vehicle_id, name, recorded_at)
) partition by range (recorded_at);

-- partitions for the next 14 months; a later cron extends them
do $$
declare d date := date_trunc('month', now())::date; i int;
begin
  for i in 0..13 loop
    execute format('create table if not exists signals_%s partition of signals for values from (%L) to (%L)',
      to_char(d + (i||' month')::interval, 'YYYYMM'), d + (i||' month')::interval, d + ((i+1)||' month')::interval);
  end loop;
end $$;

create table places (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null, lat numeric not null, lng numeric not null,
  radius_m int not null default 150, kind text not null default 'other' check (kind in ('home','work','other'))
);

create table drives (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references vehicles(id) on delete cascade,
  owner_id uuid not null,
  started_at timestamptz not null, ended_at timestamptz,
  start_lat numeric, start_lng numeric, end_lat numeric, end_lng numeric,
  start_place_id uuid references places(id), end_place_id uuid references places(id),
  start_odometer_km numeric, end_odometer_km numeric, distance_km numeric,
  start_soc numeric, end_soc numeric, energy_kwh numeric, wh_per_km numeric, max_speed_kph numeric,
  inside_c_start numeric, outside_c_start numeric,
  created_at timestamptz not null default now()
);

create table charges (
  id uuid primary key default gen_random_uuid(),
  vehicle_id uuid not null references vehicles(id) on delete cascade,
  owner_id uuid not null,
  started_at timestamptz not null, ended_at timestamptz,
  lat numeric, lng numeric, place_id uuid references places(id),
  start_soc numeric, end_soc numeric, energy_added_kwh numeric, energy_drawn_kwh numeric,
  peak_power_kw numeric, charger_type text check (charger_type in ('ac','dc_supercharger','dc_other')),
  cost_minor int, currency text not null default 'GBP', tariff_id uuid,
  created_at timestamptz not null default now()
);

create table api_usage (
  owner_id uuid not null references auth.users(id) on delete cascade,
  category text not null check (category in ('signals','commands','data','wakes')),
  month date not null,
  count bigint not null default 0,
  primary key (owner_id, category, month)
);

create table tesla_credentials (
  owner_id uuid primary key references auth.users(id) on delete cascade,
  refresh_token_enc bytea not null,
  access_token text,
  access_expires_at timestamptz,
  rotated_at timestamptz not null default now(),
  last_error text
);

-- RLS
alter table vehicles enable row level security;
alter table vehicle_state enable row level security;
alter table signals enable row level security;
alter table places enable row level security;
alter table drives enable row level security;
alter table charges enable row level security;
alter table api_usage enable row level security;
alter table tesla_credentials enable row level security;

create policy owner_all on vehicles      for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy owner_read on vehicle_state for select using (owner_id = auth.uid());
create policy owner_read on signals       for select using (owner_id = auth.uid());
create policy owner_all on places        for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy owner_read on drives        for select using (owner_id = auth.uid());
create policy owner_read on charges       for select using (owner_id = auth.uid());
create policy owner_read on api_usage     for select using (owner_id = auth.uid());
-- tesla_credentials: no user policies at all; service role only.

-- Realtime
alter publication supabase_realtime add table vehicle_state;
