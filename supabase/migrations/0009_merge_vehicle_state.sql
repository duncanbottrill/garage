create or replace function public.merge_vehicle_state(p_vehicle uuid, p_patch jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare cur jsonb; merged jsonb; k text; cols text; known jsonb := '{}'::jsonb;
begin
  if jsonb_typeof(p_patch) is distinct from 'object' then
    raise exception 'merge_vehicle_state: patch must be an object';
  end if;
  select to_jsonb(v) into cur from vehicle_state v where v.vehicle_id = p_vehicle for update;
  if cur is null then raise exception 'merge_vehicle_state: no vehicle_state row for %', p_vehicle; end if;
  -- keep only known columns from the patch, never allow vehicle_id/owner_id to change;
  -- derive the known-key set from the row itself (cur) rather than information_schema,
  -- so it always matches exactly what jsonb_populate_record below will accept.
  -- a JSON null means "omit, don't null" — skip it so the existing value survives the merge.
  for k in select jsonb_object_keys(cur) loop
    if k in ('vehicle_id','owner_id') then continue; end if;
    if p_patch ? k and jsonb_typeof(p_patch -> k) is distinct from 'null' then
      known := known || jsonb_build_object(k, p_patch -> k);
    end if;
  end loop;
  merged := cur || known;
  foreach k in array array['doors','windows','tpms_bar','bridge_health'] loop
    if known ? k and jsonb_typeof(cur -> k) = 'object' and jsonb_typeof(known -> k) = 'object' then
      merged := jsonb_set(merged, array[k], (cur -> k) || (known -> k));
    end if;
  end loop;
  merged := merged || jsonb_build_object('updated_at', now());
  select string_agg(format('%I = r.%I', t.key, t.key), ', ') into cols
    from jsonb_object_keys(cur) as t(key) where t.key not in ('vehicle_id','owner_id');
  execute format('update vehicle_state v set %s from jsonb_populate_record(null::vehicle_state, $1) r where v.vehicle_id = $2', cols) using merged, p_vehicle;
end $$;
revoke execute on function public.merge_vehicle_state(uuid, jsonb) from public, anon, authenticated;
