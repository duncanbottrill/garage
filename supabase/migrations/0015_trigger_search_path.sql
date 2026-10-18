-- Supabase advisor: trigger functions should pin search_path like every other function here.
create or replace function public.prevent_vehicle_owner_change()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.owner_id <> old.owner_id then
    raise exception 'vehicles.owner_id is immutable';
  end if;
  return new;
end $$;
