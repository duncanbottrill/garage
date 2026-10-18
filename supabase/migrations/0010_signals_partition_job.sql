-- Extends the signals partition set ahead of time and schedules the job
-- with pg_cron so new monthly partitions keep getting created (and
-- secured, via secure_signals_partition from 0005) without manual
-- intervention. Idempotent: re-running only creates partitions that are
-- still missing, and returns 0 once the window is already covered.

create or replace function public.ensure_signals_partitions(p_months_ahead int default 14)
returns int language plpgsql security definer set search_path = public as $$
declare d date := date_trunc('month', now())::date; i int; nm text; created int := 0;
begin
  for i in 0..p_months_ahead loop
    nm := 'signals_' || to_char(d + (i||' month')::interval, 'YYYYMM');
    if not exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relname = nm) then
      execute format('create table public.%I partition of public.signals for values from (%L) to (%L)', nm, d + (i||' month')::interval, d + ((i+1)||' month')::interval);
      perform public.secure_signals_partition(nm);
      created := created + 1;
    end if;
  end loop;
  return created;
end $$;
revoke execute on function public.ensure_signals_partitions(int) from public, anon, authenticated;

do $$ begin
  create extension if not exists pg_cron;
exception when feature_not_supported or undefined_file or insufficient_privilege then
  raise notice 'pg_cron extension not available here; schedule signals-partitions manually';
end $$;

do $$ begin
  perform cron.unschedule('signals-partitions') from cron.job where jobname = 'signals-partitions';
  perform cron.schedule('signals-partitions', '0 3 1 * *', $job$ select public.ensure_signals_partitions(); $job$);
exception when undefined_table or undefined_function or insufficient_privilege then
  raise notice 'pg_cron not available here; schedule signals-partitions manually';
end $$;
