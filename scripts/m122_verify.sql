-- m122 verify: list_ready_journeys covers every ready delivery order.
-- Run in Supabase SQL editor. (Post-m123 the function has one arg;
-- these checks are body-content checks and hold either way.)

create or replace function pg_temp.chk(name text, ok boolean) returns void
language plpgsql as $$
begin
  if ok then raise notice 'PASS %', name;
  else raise exception 'FAIL %', name; end if;
end $$;

do $$
declare v_src text;
begin
  select p.prosrc into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'list_ready_journeys';
  perform pg_temp.chk('function exists', v_src is not null);
  perform pg_temp.chk('no ready_after_wait_at requirement',
    v_src not like '%ready_after_wait_at is not null%');
  perform pg_temp.chk('delivery-only filter',
    v_src like '%fulfillment_type = ''delivery''%');
  perform pg_temp.chk('effective non-pickup line check',
    v_src like '%fulfillment_type_override%');
  perform pg_temp.chk('ready_at from inventory_received',
    v_src like '%inventory_received%');
  perform pg_temp.chk('journey_number returned',
    v_src like '%journey_number%');
  perform pg_temp.chk('083 recipient rule present',
    v_src like '%active_store_id%');
end $$;
