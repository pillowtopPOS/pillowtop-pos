-- ============================================================================
-- DEMO ONLY. Removes everything unit_s1_seed_demo.sql made (found by the demo
-- product sku DEMO-UNIT-1 and the demo customer email). Single paste.
-- Also puts the unit number counter back to its start if, and only if, no
-- other units exist, so real go-live numbering does not start at 4.
-- ============================================================================
do $$
declare
  v_prod uuid;
  v_company uuid;
begin
  select id, company_id into v_prod, v_company
  from public.products where sku = 'DEMO-UNIT-1';

  if v_prod is not null then
    alter table public.unit_events disable trigger trg_unit_events_no_update;
    alter table public.unit_events disable trigger trg_unit_events_no_delete;

    delete from public.unit_events
    where unit_id in (select id from public.units where product_id = v_prod);
    delete from public.units where product_id = v_prod;
    delete from public.stock_ledger_entries where variant_id = v_prod;
    delete from public.inventory_positions where variant_id = v_prod;
    delete from public.journey_inventory_requirements where variant_id = v_prod;

    alter table public.unit_events enable trigger trg_unit_events_no_update;
    alter table public.unit_events enable trigger trg_unit_events_no_delete;

    delete from public.products where id = v_prod;

    update public.unit_counters uc
    set next_value = (select c.unit_counter_start from public.companies c where c.id = uc.company_id)
    where uc.company_id = v_company
      and not exists (select 1 from public.units x where x.company_id = v_company);
  end if;

  delete from public.journey_interactions
  where journey_id in (select id from public.sleep_journeys
    where customer_id in (select id from public.customers where email = 'demo-unit@example.com'));
  delete from public.journey_events
  where journey_id in (select id from public.sleep_journeys
    where customer_id in (select id from public.customers where email = 'demo-unit@example.com'));
  delete from public.sleep_journeys
  where customer_id in (select id from public.customers where email = 'demo-unit@example.com');
  delete from public.customers where email = 'demo-unit@example.com';
end $$;

select
  (select count(*) from public.products where sku = 'DEMO-UNIT-1') as demo_products_left,
  (select count(*) from public.customers where email = 'demo-unit@example.com') as demo_customers_left,
  (select count(*) from public.sleep_journeys sj join public.customers c on c.id = sj.customer_id where c.email = 'demo-unit@example.com') as demo_journeys_left,
  (select count(*) from public.units) as units_total,
  (select coalesce(max(next_value), 0) from public.unit_counters) as counter_next_value;
