-- Early seed/fixture data used short door/window keys (fl/fr/rl/rr); the mappers
-- have used driver_front/passenger_front/driver_rear/passenger_rear since
-- migration 0001. Strip any leftover legacy keys so stale rows don't carry
-- both naming schemes at once.
update vehicle_state
set doors = case when doors ?| array['fl','fr','rl','rr'] then doors - array['fl','fr','rl','rr'] else doors end,
    windows = case when windows ?| array['fl','fr','rl','rr'] then windows - array['fl','fr','rl','rr'] else windows end
where doors ?| array['fl','fr','rl','rr'] or windows ?| array['fl','fr','rl','rr'];
