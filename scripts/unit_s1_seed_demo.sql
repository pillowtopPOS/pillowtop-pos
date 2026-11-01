-- ============================================================================
-- DEMO ONLY. Never run against a real client.
-- Seeds 3 demo units on the TBM company so the Units page has data.
-- Single paste; ends in one select printing the demo unit ids.
-- ============================================================================
create temp table if not exists unit_demo_ids (unit_id uuid);

-- Flag first: create_unit refuses untracked products.
update public.products p
set unit_tracked = true
where p.id = (
  select p2.id from public.products p2
  join public.companies c on c.id = p2.company_id
  where (c.name ilike '%TBM%' or c.name ilike '%mattress%')
    and (p2.item_name ilike '%mattress%' or p2.sku ilike '%matt%')
  order by p2.created_at
  limit 1);

with co as (
  select c.id
  from public.companies c
  where c.name ilike '%TBM%' or c.name ilike '%mattress%'
  order by c.created_at
  limit 1
), prod as (
  select p.id, p.company_id
  from public.products p
  join co on co.id = p.company_id
  where p.item_name ilike '%mattress%' or p.sku ilike '%matt%'
  order by p.created_at
  limit 1
), loc as (
  select s.id
  from public.stores s
  join co on co.id = s.company_id
  where s.location_type = 'WAREHOUSE' and s.is_active
  order by s.created_at
  limit 1
)
insert into unit_demo_ids (unit_id)
select public.create_unit(
  prod.company_id, prod.id, loc.id, 'Prime', null, null)
from prod, loc
union all
select public.create_unit(
  prod.company_id, prod.id, loc.id, 'Prime', null, null)
from prod, loc
union all
select public.create_unit(
  prod.company_id, prod.id, loc.id, 'Prime', null, null)
from prod, loc;

-- Mirror the +3 into inventory_positions (the S2 receiving wrapper will own
-- this write; for the demo we do it by hand so units and stock agree).
insert into public.inventory_positions
  (variant_id, location_id, sublocation_id, disposition, on_hand_quantity, committed_quantity)
select u.product_id, u.location_id, null, u.disposition, count(*), 0
from public.units u
join unit_demo_ids d on d.unit_id = u.id
group by u.product_id, u.location_id, u.disposition
on conflict (variant_id, location_id, sublocation_id, disposition)
do update set on_hand_quantity =
  inventory_positions.on_hand_quantity + excluded.on_hand_quantity;

-- One unit goes MISSING (move_unit takes 1 off the mirror itself).
select public.move_unit(
  (select unit_id from unit_demo_ids order by unit_id limit 1 offset 2),
  'MISSING', null, '{"event_type":"UNIT_MISSING"}'::jsonb);

-- One unit RESERVED against an existing requirement if the company has one.
do $$
declare
  v_req uuid;
  v_unit uuid;
begin
  select jir.id into v_req
  from public.journey_inventory_requirements jir
  join public.units u on u.product_id = jir.variant_id
  join unit_demo_ids d on d.unit_id = u.id
  where jir.status = 'ready'
  limit 1;
  if v_req is not null then
    select unit_id into v_unit
    from unit_demo_ids order by unit_id limit 1 offset 1;
    perform public.move_unit(v_unit, 'RESERVED', null,
      jsonb_build_object('requirement_id', v_req));
  end if;
end $$;

select u.id as demo_unit_id, u.unit_number, u.status
from public.units u
join unit_demo_ids d on d.unit_id = u.id
order by u.unit_number;
