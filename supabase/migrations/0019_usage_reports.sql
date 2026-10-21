-- Idempotent usage reports. The app sends each batch of counts with a report_id and keeps the
-- batch (with its id) until the backend has acknowledged it, so a reply lost after the server
-- recorded the batch, or a relaunch with the batch still on disk, re-sends the same id and is
-- counted once. Rows are kept 30 days; a resend later than that is counted again.
create table usage_reports (
  owner_id uuid not null references auth.users(id) on delete cascade,
  report_id uuid not null,
  category text not null,
  count bigint not null,
  created_at timestamptz not null default now(),
  primary key (owner_id, report_id)
);
create index usage_reports_created_at on usage_reports (owner_id, created_at);
-- Service role only: no policies.
alter table usage_reports enable row level security;

drop function if exists increment_usage(uuid, text, bigint);

-- Returns true when the count was added, false when p_report_id had already been counted.
create function increment_usage(p_owner uuid, p_category text, p_count bigint default 1, p_report_id uuid default null)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if p_report_id is not null then
    insert into usage_reports(owner_id, report_id, category, count)
    values (p_owner, p_report_id, p_category, p_count)
    on conflict (owner_id, report_id) do nothing;
    if not found then
      return false;
    end if;
    delete from usage_reports where owner_id = p_owner and created_at < now() - interval '30 days';
  end if;
  insert into api_usage(owner_id, category, month, count)
  values (p_owner, p_category, date_trunc('month', now())::date, p_count)
  on conflict (owner_id, category, month) do update set count = api_usage.count + excluded.count;
  return true;
end;
$$;

revoke execute on function increment_usage(uuid, text, bigint, uuid) from public, anon, authenticated;
