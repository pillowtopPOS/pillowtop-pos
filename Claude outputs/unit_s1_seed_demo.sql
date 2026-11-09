-- ============================================================================
-- DEMO ONLY. Never run against a real client with live data.
-- Single paste. Creates one throwaway product (sku DEMO-UNIT-1) with 3 demo
-- units so the Units page has something to show. It does NOT touch any real
-- product or real stock. Undo with unit_s1_seed_demo_cleanup.sql.
--
-- What you get (unit numbers come from the company counter):
--   unit 1: In stock            unit 2: Held for a demo customer
--   unit 3: Missing
--   plus ONE deliberate stock mismatch so the Discrepancies section shows a row.
-- Stops with a clear error if it is not safe to run.
-- ============================================================================
do $$
declare
  v_count int;
  v_company uuid;
  v_wh uuid;
  v_store uuid;
  v_prod uuid := gen_random_uuid();
  v_cust uuid := gen_random_uuid();
  v_journey uuid := gen_random_uuid();
  v_req uuid := gen_random_uuid();
  v_u1 uuid; v_u2 uuid; v_u3 uuid;
begin
  select count(*) into v_count from public.companies;
  if v_count <> 1 then
    raise exception 'Expected exactly one company, found %. Stop and ask Claude.', v_count;
  end if;
  select id into v_company from public.companies;

  if exists (select 1 from public.products where sku = 'DEMO-UNIT-1') then
    raise exception 'Demo data already exists. Run the cleanup first.';
  end if;

  select id into v_wh from public.stores
  where company_id = v_company and location_type = 'WAREHOUSE' and is_active
  order by name limit 1;
  select id into v_store from public.stores
  where company_id = v_company and location_type = 'STORE' and is_active
  order by name limit 1;
  if v_wh is null or v_store is null then
    raise exception 'Need one active warehouse and one active store.';
  end if;

  insert into public.products (id, company_id, sku, item_name, price)
  values (v_prod, v_company, 'DEMO-UNIT-1', 'DEMO Unit ID Mattress', 1.00);
  update public.products set unit_tracked = true where id = v_prod;

  v_u1 := public.create_unit(v_company, v_prod, v_wh, 'Prime', null, null);
  v_u2 := public.create_unit(v_company, v_prod, v_wh, 'Prime', null, null);
  v_u3 := public.create_unit(v_company, v_prod, v_wh, 'Prime', null, null);

  -- Stock mirror: the receiving code will do this in S2; by hand for the demo.
  insert into public.inventory_positions
    (variant_id, location_id, sublocation_id, disposition, on_hand_quantity, committed_quantity)
  values (v_prod, v_wh, null, 'Prime', 3, 0);

  -- Unit 3 goes missing (move_unit takes 1 off stock itself).
  perform public.move_unit(v_u3, 'MISSING', null, '{}'::jsonb);

  -- Unit 2 is held for a demo customer.
  insert into public.customers (id, first_name, last_name, phone, email, street_address, city, state, zip_code)
  values (v_cust, 'DEMO', 'Customer', '555-0100', 'demo-unit@example.com', '1 Demo St', 'Denver', 'CO', '80202');
  insert into public.sleep_journeys (id, store_id, customer_id, current_state, sale_kind)
  values (v_journey, v_store, v_cust, 'Sleep Trial', 'STANDARD');
  insert into public.journey_inventory_requirements (id, journey_id, variant_id, location_id, quantity_required, status)
  values (v_req, v_journey, v_prod, v_wh, 1, 'ready');
  perform public.move_unit(v_u2, 'RESERVED', null, jsonb_build_object('requirement_id', v_req));
  update public.inventory_positions set committed_quantity = 1
  where variant_id = v_prod and location_id = v_wh and disposition = 'Prime';

  -- Deliberate mismatch: stock says one more than the units do.
  update public.inventory_positions set on_hand_quantity = on_hand_quantity + 1
  where variant_id = v_prod and location_id = v_wh and disposition = 'Prime';
end $$;

select u.unit_number, u.status, p.sku,
  (select on_hand_quantity from public.inventory_positions ip where ip.variant_id = p.id limit 1) as stock_says,
  (select count(*) from public.units x where x.product_id = p.id and x.status in ('STOCK','RESERVED')) as units_say
from public.units u
join public.products p on p.id = u.product_id
where p.sku = 'DEMO-UNIT-1'
order by u.unit_number;
