-- S4a-1 checks: transfer_line_units schema + preview_transfer_units +
-- pick_transfer_units. DB with migrations 001..115 applied.
-- Prints PASS/FAIL per check. Runs in a transaction, rolls back at the end.
begin;

create temp table t(name text, ok boolean);
create or replace function pg_temp.chk(nm text, cond boolean)
returns void language sql as $$
  insert into t values (nm, coalesce(cond, false));
$$;

do $$
declare
  v_c uuid := gen_random_uuid();
  v_w uuid := gen_random_uuid(); v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();
  v_emp uuid := gen_random_uuid(); v_auth uuid := gen_random_uuid();
  v_pt uuid := gen_random_uuid(); v_pu uuid := gen_random_uuid();
  v_cust uuid := gen_random_uuid();
  v_ja uuid := gen_random_uuid(); v_jb uuid := gen_random_uuid();
  v_ra uuid := gen_random_uuid(); v_rb uuid := gen_random_uuid();
  v_u1 uuid := gen_random_uuid(); v_u2 uuid := gen_random_uuid();
  v_u3 uuid := gen_random_uuid(); v_u4 uuid := gen_random_uuid();
  v_u5 uuid := gen_random_uuid(); v_u6 uuid := gen_random_uuid();
  v_t1 uuid := gen_random_uuid(); v_t2 uuid := gen_random_uuid();
  v_t3 uuid := gen_random_uuid(); v_t4 uuid := gen_random_uuid();
  v_t5 uuid := gen_random_uuid();
  v_l1 uuid := gen_random_uuid(); v_l2 uuid := gen_random_uuid();
  v_l3 uuid := gen_random_uuid(); v_l4 uuid := gen_random_uuid();
  v_l5 uuid := gen_random_uuid();
  v_state text;
  v_prev jsonb; v_pick jsonb; v_err text;
begin
  -- seed ----------------------------------------------------------------
  select enumlabel into v_state from pg_enum e join pg_type y
    on y.oid = e.enumtypid where y.typname = 'journey_state'
    and enumlabel <> 'Quoted' limit 1;
  insert into companies(id,name,business_timezone)
    values (v_c,'C','America/Denver');
  insert into stores(id,company_id,name,location_type,is_active) values
    (v_w,v_c,'W','WAREHOUSE',true),(v_a,v_c,'A','STORE',true),
    (v_b,v_c,'B','STORE',true);
  insert into employees(id,auth_user_id,home_store_id,role,is_active)
    values (v_emp,v_auth,v_w,'owner',true);
  insert into products(id,company_id,item_name,unit_tracked) values
    (v_pt,v_c,'Tracked',true),(v_pu,v_c,'Untracked',false);
  insert into customers(id,first_name,last_name) values (v_cust,'T','U');
  insert into sleep_journeys(id,customer_id,store_id,current_state) values
    (v_ja,v_cust,v_a,v_state),(v_jb,v_cust,v_b,v_state);
  insert into journey_inventory_requirements
    (id,journey_id,variant_id,location_id,quantity_required,status) values
    (v_ra,v_ja,v_pt,v_a,1,'pending'),
    (v_rb,v_jb,v_pt,v_b,1,'pending');
  -- units at W for tracked product:
  --   #101 STOCK, #102 STOCK,
  --   #103 RESERVED bound to requirement at A (this transfer's dest),
  --   #104 RESERVED bound to requirement at B (must never be picked W->A),
  --   #105 STOCK but already spoken for elsewhere is not needed;
  -- #106 tracked unit at B (wrong location), #107 untracked unit at W.
  insert into units(id,company_id,product_id,unit_number,status,
    location_id,disposition,assigned_requirement_id) values
    (v_u1,v_c,v_pt,101,'STOCK',v_w,'Prime',null),
    (v_u2,v_c,v_pt,102,'STOCK',v_w,'Prime',null),
    (v_u3,v_c,v_pt,103,'RESERVED',v_w,'Prime',v_ra),
    (v_u4,v_c,v_pt,104,'RESERVED',v_w,'Prime',v_rb),
    (v_u5,v_c,v_pt,105,'STOCK',v_b,'Prime',null),
    (v_u6,v_c,v_pu,201,'STOCK',v_w,'Prime',null);
  -- transfers: t1 pending W->A qty3 tracked; t2 pending W->A qty1
  -- untracked; t3 pending W->A qty2 tracked (double-pick target);
  -- t4 in_transit (pick must fail); t5 pending qty5 (shortfall).
  insert into transfers(id,origin_location_id,destination_location_id,
    status,scheduled_date) values
    (v_t1,v_w,v_a,'pending','2025-01-01'),
    (v_t2,v_w,v_a,'pending','2025-01-01'),
    (v_t3,v_w,v_a,'pending','2025-01-01'),
    (v_t4,v_w,v_a,'in_transit','2025-01-01'),
    (v_t5,v_w,v_a,'pending','2025-01-01');
  insert into transfer_line_items(id,transfer_id,variant_id,
    quantity_requested) values
    (v_l1,v_t1,v_pt,3),(v_l2,v_t2,v_pu,1),(v_l3,v_t3,v_pt,2),
    (v_l4,v_t4,v_pt,1),(v_l5,v_t5,v_pt,5);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_auth)::text,true);

  -- T1 preview: order-bound RESERVED first, then oldest STOCK;
  -- RESERVED-for-B and wrong-location unit excluded; untracked line omitted
  v_prev := public.preview_transfer_units(v_t1);
  perform pg_temp.chk('T1a preview has one line',
    jsonb_array_length(v_prev->'lines') = 1);
  perform pg_temp.chk('T1b candidates = bound-103, stock-101, stock-102',
    (select jsonb_agg(x->>'unit_number' order by ord)
       from jsonb_array_elements(v_prev->'lines'->0->'candidates')
            with ordinality e(x,ord)) = '["103","101","102"]'::jsonb);
  perform pg_temp.chk('T1c auto_pick = bound-103, stock-101, stock-102',
    (v_prev->'lines'->0->'auto_pick') =
      jsonb_build_array(v_u3::text, v_u1::text, v_u2::text));
  perform pg_temp.chk('T1d candidate count is 3 (104 and 105 excluded)',
    jsonb_array_length(v_prev->'lines'->0->'candidates') = 3);

  -- T2 auto pick writes rows with status/requirement snapshot
  v_pick := public.pick_transfer_units(v_t1, null, v_emp);
  perform pg_temp.chk('T2a three rows picked',
    (select count(*) from transfer_line_units
      where transfer_id = v_t1) = 3);
  perform pg_temp.chk('T2b order-bound unit kept RESERVED + requirement',
    exists(select 1 from transfer_line_units tlu
      join units u on u.id = tlu.unit_id
      where tlu.transfer_id = v_t1 and u.unit_number = 103
        and tlu.picked_status = 'RESERVED'
        and tlu.picked_requirement_id = v_ra));
  perform pg_temp.chk('T2c STOCK units picked as STOCK',
    (select count(*) from transfer_line_units tlu
      join units u on u.id = tlu.unit_id
      where tlu.transfer_id = v_t1 and tlu.picked_status = 'STOCK') = 2);

  -- T3 idempotent re-pick replaces, never duplicates
  perform public.pick_transfer_units(v_t1, null, v_emp);
  perform pg_temp.chk('T3 re-pick still exactly 3 rows',
    (select count(*) from transfer_line_units
      where transfer_id = v_t1) = 3);

  -- T4 manual override: reorder/swapped set accepted
  v_pick := public.pick_transfer_units(v_t1, jsonb_build_array(
    jsonb_build_object('line_item_id', v_l1,
      'unit_ids', jsonb_build_array(v_u2, v_u1, v_u3))), v_emp);
  perform pg_temp.chk('T4 override picks the same 3 units',
    (select count(*) from transfer_line_units
      where transfer_id = v_t1
        and unit_id in (v_u1, v_u2, v_u3)) = 3);

  -- T5 override errors: too few units for the line
  begin
    perform public.pick_transfer_units(v_t1, jsonb_build_array(
      jsonb_build_object('line_item_id', v_l1,
        'unit_ids', jsonb_build_array(v_u1, v_u2))), v_emp);
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T5 short override rejected', v_err is not null);

  -- T6 override errors: wrong product
  begin
    perform public.pick_transfer_units(v_t1, jsonb_build_array(
      jsonb_build_object('line_item_id', v_l1,
        'unit_ids', jsonb_build_array(v_u6, v_u1, v_u2))), v_emp);
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T6 wrong-product unit rejected', v_err is not null);

  -- T7 override errors: unit not at origin
  begin
    perform public.pick_transfer_units(v_t1, jsonb_build_array(
      jsonb_build_object('line_item_id', v_l1,
        'unit_ids', jsonb_build_array(v_u5, v_u1, v_u2))), v_emp);
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T7 wrong-location unit rejected', v_err is not null);

  -- T8 override errors: RESERVED unit bound to another store
  begin
    perform public.pick_transfer_units(v_t1, jsonb_build_array(
      jsonb_build_object('line_item_id', v_l1,
        'unit_ids', jsonb_build_array(v_u4, v_u1, v_u2))), v_emp);
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T8 RESERVED-for-other-store rejected', v_err is not null);

  -- T9 unit already on an unresolved shipment cannot be picked again
  begin
    perform public.pick_transfer_units(v_t3, jsonb_build_array(
      jsonb_build_object('line_item_id', v_l3,
        'unit_ids', jsonb_build_array(v_u1, v_u2))), v_emp);
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T9 unit already in-flight rejected', v_err is not null);

  -- T10 untracked line: preview omits it, pick writes nothing, succeeds
  v_prev := public.preview_transfer_units(v_t2);
  perform pg_temp.chk('T10a untracked line omitted from preview',
    jsonb_array_length(v_prev->'lines') = 0);
  perform public.pick_transfer_units(v_t2, null, v_emp);
  perform pg_temp.chk('T10b untracked pick writes zero rows',
    not exists(select 1 from transfer_line_units
      where transfer_id = v_t2));

  -- T11 pick on non-pending transfer fails
  begin
    perform public.pick_transfer_units(v_t4, null, v_emp);
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T11 in_transit pick rejected', v_err is not null);

  -- T12 insufficient eligible units fails with a clear error
  begin
    perform public.pick_transfer_units(v_t5, null, v_emp);
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T12 shortfall pick rejected', v_err is not null);
  perform pg_temp.chk('T13 candidates fn not callable by authenticated',
    not has_function_privilege('authenticated','public.transfer_line_unit_candidates(uuid)','execute'));
  perform pg_temp.chk('T14 read policy is scoped by store visibility (not using true)',
    exists(select 1 from pg_policies where tablename='transfer_line_units'
      and cmd='SELECT' and qual like '%is_store_visible%'));
  perform pg_temp.chk('T15 no open policy left',
    not exists(select 1 from pg_policies where tablename='transfer_line_units' and qual='true'));
end $$;


select name, ok from t order by name;
select count(*) filter (where ok) || ' / ' || count(*) as summary from t;
rollback;
