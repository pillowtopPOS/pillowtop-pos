-- ============================================================================
-- DEMO ONLY. Reverses unit_s1_seed_demo.sql.
-- Disables the append-only guards, removes demo units, events, ledger rows,
-- counters and mirror rows it created, restores the product flag, re-enables
-- the triggers. Ends with a select of leftover demo rows (expect zeros).
-- ============================================================================
do $$
declare
  v_pid uuid;
begin
  select product_id into v_pid
  from public.units
  where id in (select unit_id from unit_demo_ids)
  limit 1;

  alter table public.unit_events disable trigger trg_unit_events_no_update;
  alter table public.unit_events disable trigger trg_unit_events_no_delete;

  delete from public.unit_events
  where unit_id in (select unit_id from unit_demo_ids);
  delete from public.stock_ledger_entries
  where reference_type = 'unit'
    and correlation_id in (select unit_id from unit_demo_ids);
  delete from public.units
  where id in (select unit_id from unit_demo_ids);

  -- restore the mirror the MISSING move took down (demo moved -1 Prime)
  update public.inventory_positions ip
  set on_hand_quantity = on_hand_quantity + 1
  where variant_id = v_pid
    and sublocation_id is null
    and disposition = 'Prime'
    and location_id in (
      select s.id from public.stores s where s.location_type = 'WAREHOUSE'
        and s.company_id = (select company_id from public.products where id = v_pid)
      order by s.created_at limit 1);

  -- then remove the +3 the seed added
  update public.inventory_positions ip
  set on_hand_quantity = greatest(on_hand_quantity - 3, 0)
  where variant_id = v_pid
    and sublocation_id is null
    and disposition = 'Prime';

  update public.products set unit_tracked = null
  where id = v_pid;

  alter table public.unit_events enable trigger trg_unit_events_no_update;
  alter table public.unit_events enable trigger trg_unit_events_no_delete;
end $$;

select
  (select count(*) from public.units u
    join unit_demo_ids d on d.unit_id = u.id) as units_left,
  (select count(*) from public.unit_events e
    join unit_demo_ids d on d.unit_id = e.unit_id) as events_left;
