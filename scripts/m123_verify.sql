-- m123 verify: list_ready_journeys has the p_all_stores signature, the
-- zero-arg version is gone, and the company check is in the body.
-- Run in Supabase SQL editor after 001-123.

create or replace function pg_temp.chk(name text, ok boolean) returns void
language plpgsql as $$
begin
  if ok then raise notice 'PASS %', name;
  else raise exception 'FAIL %', name; end if;
end $$;

do $$
declare
  v_new int;
  v_old int;
  v_src text;
begin
  select count(*) into v_new
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'list_ready_journeys'
    and p.pronargs = 1;
  perform pg_temp.chk('one-arg version exists', v_new = 1);

  select count(*) into v_old
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'list_ready_journeys'
    and p.pronargs = 0;
  perform pg_temp.chk('zero-arg version dropped', v_old = 0);

  select p.prosrc into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'list_ready_journeys'
    and p.pronargs = 1;
  perform pg_temp.chk('body mentions p_all_stores', v_src like '%p_all_stores%');
  perform pg_temp.chk('body has company check', v_src like '%s.company_id = v_company_id%');
  perform pg_temp.chk('body resolves caller company', v_src like '%v_employee.home_store_id%');
end $$;

-- Behavioral (needs fixtures, run manually):
-- T1 p_all_stores omitted/false: identical rows to m122 for the same user.
-- T2 true: salesperson sees ready delivery orders at OTHER stores in the
--    same company; never sees another company's rows.
-- T3 employee with NULL home_store_id + true: empty list.
-- T4 pickup-only and non-Ready journeys still excluded in both modes.
