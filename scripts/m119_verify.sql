-- m119 checks: verify_transfer_receiver check-in rule (migration 119).
-- DB with migrations 001..119 applied. pg_temp.chk style, rolls back.
begin;

create temp table t(name text, ok boolean);
create or replace function pg_temp.chk(nm text, cond boolean)
returns void language sql as $$
  insert into t values (nm, coalesce(cond, false));
$$;

do $$
declare
  v_c uuid := gen_random_uuid();
  v_w uuid := gen_random_uuid();
  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();

  v_owner uuid := gen_random_uuid();
  v_owner_auth uuid := gen_random_uuid();
  v_checked uuid := gen_random_uuid();
  v_checked_auth uuid := gen_random_uuid();
  v_elsewhere uuid := gen_random_uuid();
  v_elsewhere_auth uuid := gen_random_uuid();
  v_stale uuid := gen_random_uuid();
  v_stale_auth uuid := gen_random_uuid();
  v_sixpm uuid := gen_random_uuid();
  v_sixpm_auth uuid := gen_random_uuid();
  v_homeonly uuid := gen_random_uuid();
  v_homeonly_auth uuid := gen_random_uuid();
  v_wareemp uuid := gen_random_uuid();
  v_wareemp_auth uuid := gen_random_uuid();
  v_storeemp uuid := gen_random_uuid();
  v_storeemp_auth uuid := gen_random_uuid();

  v_today date;
  v_ok uuid;
  v_err text;
begin
  insert into companies(id,name,business_timezone)
    values (v_c,'C','America/Denver');
  insert into stores(id,company_id,name,location_type,is_active) values
    (v_w,v_c,'Main Warehouse','WAREHOUSE',true),
    (v_a,v_c,'Main Street','STORE',true),
    (v_b,v_c,'Lone Tree','STORE',true);

  insert into employees(id,auth_user_id,home_store_id,role,is_active) values
    (v_owner, v_owner_auth, v_w, 'owner', true),
    (v_checked, v_checked_auth, v_a, 'employee', true),
    (v_elsewhere, v_elsewhere_auth, v_a, 'employee', true),
    (v_stale, v_stale_auth, v_a, 'employee', true),
    (v_sixpm, v_sixpm_auth, v_a, 'employee', true),
    (v_homeonly, v_homeonly_auth, v_a, 'employee', true),
    (v_wareemp, v_wareemp_auth, v_w, 'employee', true),
    (v_storeemp, v_storeemp_auth, v_a, 'employee', true);

  v_today := public.business_today(v_a);

  -- helper pattern: point the JWT at an employee, optionally with a
  -- check-in. is_local=true keeps it inside this transaction.

  -- T1: owner allowed at a store destination with no check-in at all.
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_owner_auth)::text, true);
  v_ok := public.verify_transfer_receiver(v_owner, v_a);
  perform pg_temp.chk('T1 owner allowed at store destination',
    v_ok = v_owner);

  -- T2: employee checked in at the destination store today: allowed.
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_checked_auth,
      'user_metadata', jsonb_build_object(
        'active_store_id', v_a,
        'active_store_confirmed_at',
          ((v_today + time '09:00') at time zone 'America/Denver')::text)
    )::text, true);
  v_ok := public.verify_transfer_receiver(v_checked, v_a);
  perform pg_temp.chk('T2 checked-in staff at destination allowed',
    v_ok = v_checked);

  -- T3: checked in at a DIFFERENT store today: refused, exact message.
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_elsewhere_auth,
      'user_metadata', jsonb_build_object(
        'active_store_id', v_b,
        'active_store_confirmed_at',
          ((v_today + time '09:00') at time zone 'America/Denver')::text)
    )::text, true);
  begin
    perform public.verify_transfer_receiver(v_elsewhere, v_a);
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T3 checked-in elsewhere refused with exact message',
    v_err = 'Check in at Main Street first. Only an employee checked in at the destination store today, or an owner or admin, can receive this transfer.');

  -- T4: check-in dated yesterday (local): refused.
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_stale_auth,
      'user_metadata', jsonb_build_object(
        'active_store_id', v_a,
        'active_store_confirmed_at',
          (((v_today - 1) + time '09:00') at time zone 'America/Denver')::text)
    )::text, true);
  begin
    perform public.verify_transfer_receiver(v_stale, v_a);
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T4 stale check-in refused', v_err is not null
    and v_err like 'Check in at Main Street first.%');

  -- T5: home store IS the destination but no check-in today: refused.
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_homeonly_auth)::text, true);
  begin
    perform public.verify_transfer_receiver(v_homeonly, v_a);
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T5 home-store-only no longer qualifies',
    v_err is not null
    and v_err like 'Check in at Main Street first.%');

  -- T6: check-in at 6pm local today. In Denver (UTC-6/-7) that instant is
  -- already the NEXT day in UTC half the year; the local-day test must
  -- still allow it.
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_sixpm_auth,
      'user_metadata', jsonb_build_object(
        'active_store_id', v_a,
        'active_store_confirmed_at',
          ((v_today + time '18:00') at time zone 'America/Denver')::text)
    )::text, true);
  v_ok := public.verify_transfer_receiver(v_sixpm, v_a);
  perform pg_temp.chk('T6 6pm-local check-in allowed (UTC next day)',
    v_ok = v_sixpm);

  -- T7: warehouse destination, warehouse-based employee: still allowed.
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_wareemp_auth)::text, true);
  v_ok := public.verify_transfer_receiver(v_wareemp, v_w);
  perform pg_temp.chk('T7 warehouse staff allowed at warehouse dest',
    v_ok = v_wareemp);

  -- T8: warehouse destination, store-based employee: refused with the
  -- original warehouse-rule message.
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub', v_storeemp_auth)::text, true);
  begin
    perform public.verify_transfer_receiver(v_storeemp, v_w);
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T8 store staff refused at warehouse dest',
    v_err = 'Only the destination store''s staff, a manager, or warehouse staff can receive a transfer');
end $$;

select name, ok from t order by name;
select count(*) filter (where ok) || ' / ' || count(*) as summary from t;
rollback;
