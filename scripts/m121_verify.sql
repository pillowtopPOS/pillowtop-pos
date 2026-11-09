-- m121 v3 verify: sync trigger deferred; unit observer immediate and off
-- the sync path. Run in Supabase SQL editor after 001-121.

create or replace function pg_temp.chk(name text, ok boolean) returns void
language plpgsql as $$
begin
  if ok then raise notice 'PASS %', name;
  else raise exception 'FAIL %', name; end if;
end $$;

do $$
declare v tg_trigger%rowtype;
begin
  select * into v from pg_trigger
  where tgname = 'trg_jm_requirement_sync'
    and tgrelid = 'public.journey_inventory_requirements'::regclass;
  perform pg_temp.chk('trg_jm_requirement_sync exists', v.tgname is not null);
  perform pg_temp.chk('is constraint trigger', v.tgconstraint <> 0);
  perform pg_temp.chk('is deferrable', v.tgdeferrable);
  perform pg_temp.chk('initially deferred', v.tginitdeferred);

  -- UPDATE OF column list must include all four columns; quantity_reserved
  -- is required so a reserved-only change still re-syncs the request hold.
  perform pg_temp.chk('sync trigger covers quantity_required',
    exists (select 1 from pg_attribute a
      where a.attrelid = 'public.journey_inventory_requirements'::regclass
        and a.attname = 'quantity_required'
        and a.attnum = any (v.tgattr)));
  perform pg_temp.chk('sync trigger covers quantity_reserved',
    exists (select 1 from pg_attribute a
      where a.attrelid = 'public.journey_inventory_requirements'::regclass
        and a.attname = 'quantity_reserved'
        and a.attnum = any (v.tgattr)));
  perform pg_temp.chk('sync trigger covers location_id',
    exists (select 1 from pg_attribute a
      where a.attrelid = 'public.journey_inventory_requirements'::regclass
        and a.attname = 'location_id'
        and a.attnum = any (v.tgattr)));
  perform pg_temp.chk('sync trigger covers status',
    exists (select 1 from pg_attribute a
      where a.attrelid = 'public.journey_inventory_requirements'::regclass
        and a.attname = 'status'
        and a.attnum = any (v.tgattr)));

  select * into v from pg_trigger
  where tgname = 'trg_jir_units_observer'
    and tgrelid = 'public.journey_inventory_requirements'::regclass;
  perform pg_temp.chk('trg_jir_units_observer exists', v.tgname is not null);
  perform pg_temp.chk('unit observer NOT a constraint trigger', v.tgconstraint = 0);
  perform pg_temp.chk('unit observer immediate (not deferred)',
    not v.tgdeferrable or not v.tginitdeferred);
end $$;

do $$
declare v text;
begin
  -- reconcile has the p_sync parameter and guards the sync call.
  select pg_get_function_arguments(p.oid) into v
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'reconcile_requirement_units';
  perform pg_temp.chk('reconcile signature has p_sync', v like '%p_sync%');

  select p.prosrc into v
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'observe_requirement_units';
  perform pg_temp.chk('observer passes p_sync=false',
    v like '%reconcile_requirement_units(new.id, false)%');
end $$;

-- Behavioral (needs fixtures, run manually):
-- T1 covered order paid in full at creation: ZERO journey_mismatch
--    request rows, no "Transfer requested" timeline line.
-- T2 qty increase on a paid covered order: same.
-- T3 genuinely uncovered order (store ATS 0): exactly ONE approved
--    request, held_quantity = shortfall.
-- T4 partial coverage: one request held for the uncovered delta only.
-- T5 Quoted order: no request; leaving Quoted with real shortfall
--    creates exactly one.
-- T6 unit-tracked covered order: units end RESERVED, no request, no
--    UNIT_ASSIGNMENT_ERROR audit rows.
-- T7 receive_purchase_order_line regression: returned assignments match
--    pre-m121 behavior (units visible in v_assignments before commit).
-- T8 journey deleted before commit: no error.
-- T9 over-hold regression: order needs 3, uncovered, request held 3;
--    a later evaluate reserves 1 locally (status stays 'pending').
--    The reserved-only update must re-sync at commit so held drops to 2.
