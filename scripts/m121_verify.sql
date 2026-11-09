-- m121 verify: both requirement observers are deferred to commit.
-- Run in Supabase SQL editor after 001-121.

create or replace function pg_temp.chk(name text, ok boolean) returns void
language plpgsql as $$
begin
  if ok then raise notice 'PASS %', name;
  else raise exception 'FAIL %', name; end if;
end $$;

do $$
declare v tg_trigger%rowtype;
begin
  for v in
    select * from pg_trigger
    where tgrelid = 'public.journey_inventory_requirements'::regclass
      and tgname in ('trg_jm_requirement_sync', 'trg_jir_units_observer')
  loop
    perform pg_temp.chk(v.tgname || ' exists', v.tgname is not null);
    perform pg_temp.chk(v.tgname || ' is constraint trigger', v.tgconstraint <> 0);
    perform pg_temp.chk(v.tgname || ' is deferrable', v.tgdeferrable);
    perform pg_temp.chk(v.tgname || ' initially deferred', v.tginitdeferred);
  end loop;
  perform pg_temp.chk('both triggers present',
    (select count(*) from pg_trigger
     where tgrelid = 'public.journey_inventory_requirements'::regclass
       and tgname in ('trg_jm_requirement_sync', 'trg_jir_units_observer')) = 2);
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
-- T6 unit-tracked covered order: units end RESERVED at commit, no
--    request, no UNIT_ASSIGNMENT_ERROR audit rows.
-- T7 journey deleted before commit: no error (reconcile not-found guard).
