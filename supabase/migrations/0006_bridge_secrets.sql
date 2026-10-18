create table bridge_secrets (
  owner_id uuid primary key references auth.users(id) on delete cascade,
  secret_hash text not null,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);
alter table bridge_secrets enable row level security; -- service role only
