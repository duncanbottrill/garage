-- vehicles.owner_id is immutable: ownership transfer is out of scope for slice 1,
-- and silently allowing it would let a compromised session reassign a vehicle.
create or replace function public.prevent_vehicle_owner_change()
returns trigger language plpgsql as $$
begin
  if new.owner_id <> old.owner_id then
    raise exception 'vehicles.owner_id is immutable';
  end if;
  return new;
end $$;
create trigger vehicles_owner_immutable before update on vehicles
  for each row execute function prevent_vehicle_owner_change();
