-- m120 verify: transfer dates follow the store business timezone.
-- Run in Supabase SQL editor after 001-120. pg_temp.chk style.

create or replace function pg_temp.chk(name text, ok boolean) returns void
language plpgsql as $$
begin
  if ok then raise notice 'PASS %', name;
  else raise exception 'FAIL %', name; end if;
end $$;

-- T1: function bodies use business_today, not bare current_date for the
--     scheduled-date floor.
do $$
declare v_def text;
begin
  select pg_get_functiondef('public.expedite_transfer_request(uuid,uuid,date)'::regprocedure) into v_def;
  perform pg_temp.chk('expedite_transfer_request uses business_today', v_def like '%business_today%');
  perform pg_temp.chk('expedite_transfer_request has no current_date floor', v_def not like '%p_scheduled_date < current_date%');

  select pg_get_functiondef('public.expedite_transfer_request_group(uuid,uuid,date)'::regprocedure) into v_def;
  perform pg_temp.chk('expedite_group uses business_today', v_def like '%business_today%');

  select pg_get_functiondef('public.confirm_transfer_receipt(uuid,uuid,jsonb)'::regprocedure) into v_def;
  perform pg_temp.chk('confirm_receipt uses business_today', v_def like '%business_today%');
  perform pg_temp.chk('confirm_receipt has no ::date <> current_date', v_def not like '%::date <> current_date%');

  select pg_get_functiondef('public.run_transfer_consolidation_now(uuid)'::regprocedure) into v_def;
  perform pg_temp.chk('consolidation_now uses business_today', v_def like '%business_today%');
end $$;

-- T3 (manual, needs fixtures): at 6 PM MT with store tz America/Denver,
-- expedite_transfer_request with scheduled_date = business_today(dest)
-- succeeds; scheduled_date = business_today(dest) - 1 still raises
-- 'Scheduled date cannot be in the past'.
