create or replace function public.merge_vehicle_state(p_vehicle uuid, p_patch jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare cur jsonb; merged jsonb; k text; cols text; known jsonb := '{}'::jsonb;
begin
  select to_jsonb(v) into cur from vehicle_state v where v.vehicle_id = p_vehicle for update;
  if cur is null then raise exception 'merge_vehicle_state: no vehicle_state row for %', p_vehicle; end if;
  -- keep only known columns from the patch, never allow vehicle_id/owner_id to change
  for k in select column_name from information_schema.columns where table_schema = 'public' and table_name = 'vehicle_state' and column_name not in ('vehicle_id','owner_id') loop
    if p_patch ? k then known := known || jsonb_build_object(k, p_patch -> k); end if;
  end loop;
  merged := cur || known;
  foreach k in array array['doors','windows','tpms_bar','bridge_health'] loop
    if known ? k and jsonb_typeof(cur -> k) = 'object' and jsonb_typeof(known -> k) = 'object' then
      merged := jsonb_set(merged, array[k], (cur -> k) || (known -> k));
    end if;
  end loop;
  merged := merged || jsonb_build_object('updated_at', now());
  select string_agg(format('%I = r.%I', column_name, column_name), ', ') into cols
    from information_schema.columns where table_schema = 'public' and table_name = 'vehicle_state' and column_name not in ('vehicle_id','owner_id');
  execute format('update vehicle_state v set %s from jsonb_populate_record(null::vehicle_state, $1) r where v.vehicle_id = $2', cols) using merged, p_vehicle;
end $$;
revoke execute on function public.merge_vehicle_state(uuid, jsonb) from public, anon, authenticated;
