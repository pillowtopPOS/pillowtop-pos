-- D1-a test seed: two trucks + one exception + one day adjustment.
-- Run in the Supabase SQL editor. Safe to read the notices to confirm
-- which company/dates were used.
--
-- The Supabase SQL editor runs as the database owner, so the security-
-- definer RPCs would reject it — this script writes the tables directly,
-- which is exactly what those RPCs do on Zach's behalf.
--
-- Company resolution: prefers a company whose name looks like "The
-- Better Mattress"; otherwise picks the company that owns the most
-- stores (TBM is the real company). Adjust the WHERE clause if your
-- setup differs.

do $$
declare
  v_company_id uuid;
  v_company_name text;
  v_monday date;
  v_wednesday date;
  v_thursday date;
  v_truck1 uuid;
  v_truck2 uuid;
begin
  select c.id, c.name into v_company_id, v_company_name
  from public.companies c
  order by
    (c.name ilike '%mattress%') desc,
    (select count(*) from public.stores s where s.company_id = c.id) desc,
    c.created_at
  limit 1;

  if v_company_id is null then
    raise exception 'No company found — check the companies table.';
  end if;

  -- Monday of the current week (ISO: Mon=1..Sun=7).
  v_monday := current_date - ((extract(isodow from current_date)::int + 6) % 7);
  v_wednesday := v_monday + 2;
  v_thursday := v_monday + 3;

  raise notice 'Company: % (%)', v_company_name, v_company_id;
  raise notice 'Week of: Mon % | exception Wed % | +3 slots Thu %',
    v_monday, v_wednesday, v_thursday;

  insert into public.delivery_trucks
    (company_id, name, home_location_id, default_stop_cap, weekly_pattern, sort_order)
  values
    (v_company_id, 'Truck 1', null, 8, '{1,2,3,4,5,6}', 0)
  returning id into v_truck1;

  insert into public.delivery_trucks
    (company_id, name, home_location_id, default_stop_cap, weekly_pattern, sort_order)
  values
    (v_company_id, 'Truck 2', null, 6, '{1,2,3,4,5,6}', 1)
  returning id into v_truck2;

  -- Truck 1 OFF this Wednesday (overrides the Mon-Sat pattern).
  insert into public.delivery_truck_exceptions (truck_id, date, is_on)
  values (v_truck1, v_wednesday, false);

  -- +3 extra slots for the whole day pool this Thursday.
  insert into public.delivery_day_adjustments (company_id, date, extra_slots)
  values (v_company_id, v_thursday, 3);

  raise notice 'Seeded: Truck 1 (cap 8, id %), Truck 2 (cap 6, id %)',
    v_truck1, v_truck2;
end $$;

-- ---------------------------------------------------------------------------
-- CLEANUP (commented out — uncomment to remove the seed data)
-- ---------------------------------------------------------------------------
-- do $$
-- declare v_company_id uuid;
-- begin
--   select c.id into v_company_id
--   from public.companies c
--   order by (c.name ilike '%mattress%') desc,
--            (select count(*) from public.stores s where s.company_id = c.id) desc,
--            c.created_at
--   limit 1;
--
--   delete from public.delivery_trucks
--   where company_id = v_company_id and name in ('Truck 1', 'Truck 2');
--   -- exceptions and adjustments cascade / are removed with the trucks;
--   -- the adjustment row is keyed by company+date, so remove it too:
--   delete from public.delivery_day_adjustments
--   where company_id = v_company_id
--     and date = current_date - ((extract(isodow from current_date)::int + 6) % 7) + 3;
-- end $$;
