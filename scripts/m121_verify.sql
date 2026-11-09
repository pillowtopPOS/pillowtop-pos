-- m121 verify: jm sync trigger is deferred to commit.
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
  select * into v from pg_trigger
  where tgname = 'trg_jm_requirement_sync'
    and tgrelid = 'public.journey_inventory_requirements'::regclass;
  perform pg_temp.chk('trigger exists', v.tgname is not null);
  perform pg_temp.chk('is constraint trigger', v.tgconstraint <> 0);
  perform pg_temp.chk('is deferrable', v.tgdeferrable);
  perform pg_temp.chk('initially deferred', v.tginitdeferred);
end $$;

-- Behavioral (needs fixtures, run manually):
-- T1 covered order paid in full: no journey_mismatch request row at all,
--    no "Transfer requested" line — before AND after commit.
-- T2 qty increase on paid covered order: same.
-- T3 genuinely uncovered order (store ATS 0): exactly ONE approved
--    request with held_quantity = shortfall, visible after commit.
-- T4 Quoted order: no request while Quoted; leaving Quoted with real
--    shortfall creates one.
