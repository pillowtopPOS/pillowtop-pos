-- PillowTop POS m133: fix the route position uniqueness rule from m132.
--
-- m132 made (truck_id, route_position) unique across ALL dates among BOOKED
-- stops, so Truck 1 position 1 on one day blocked Truck 1 position 1 on every
-- other day. Positions only have to be unique per truck PER DAY.
-- Found by Instinct: saving a route on a fresh day failed while another day
-- already had a saved route.

drop index if exists public.delivery_stops_truck_position;

create unique index if not exists delivery_stops_truck_position
  on public.delivery_stops (truck_id, delivery_date, route_position)
  where status = 'BOOKED' and truck_id is not null;
