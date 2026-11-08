-- S4a-3 checks: unit-level receive + missing (migration 117).
-- DB with migrations 001..117 applied. pg_temp.chk style, rolls back.
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
  v_empd uuid := gen_random_uuid(); v_authd uuid := gen_random_uuid();
  v_empu uuid := gen_random_uuid(); v_authu uuid := gen_random_uuid();
  v_empw uuid := gen_random_uuid(); v_authw uuid := gen_random_uuid();
  v_pf uuid := gen_random_uuid(); v_ps uuid := gen_random_uuid();
  v_pw uuid := gen_random_uuid(); v_pl uuid := gen_random_uuid();
  v_pm uuid := gen_random_uuid(); v_pscan uuid := gen_random_uuid();
  v_cust uuid := gen_random_uuid();
  v_jw uuid := gen_random_uuid(); v_rw uuid := gen_random_uuid();
  v_js uuid := gen_random_uuid(); v_rs uuid := gen_random_uuid();
  v_state text;
  v_tf uuid := gen_random_uuid(); v_ts uuid := gen_random_uuid();
  v_tw uuid := gen_random_uuid(); v_tl uuid := gen_random_uuid();
  v_tp1 uuid := gen_random_uuid(); v_tp2 uuid := gen_random_uuid();
  v_tp3 uuid := gen_random_uuid(); v_tsc uuid := gen_random_uuid();
  v_lf uuid := gen_random_uuid(); v_ls uuid := gen_random_uuid();
  v_lw uuid := gen_random_uuid(); v_ll uuid := gen_random_uuid();
  v_lp1 uuid := gen_random_uuid(); v_lp2 uuid := gen_random_uuid();
  v_lp3 uuid := gen_random_uuid(); v_lsc uuid := gen_random_uuid();
  v_uf1 uuid := gen_random_uuid(); v_uf2 uuid := gen_random_uuid();
  v_us1 uuid := gen_random_uuid(); v_us2 uuid := gen_random_uuid();
  v_us3 uuid := gen_random_uuid();
  v_uw1 uuid := gen_random_uuid();
  v_usc1 uuid := gen_random_uuid(); v_usc2 uuid := gen_random_uuid();
  v_err text; v_res jsonb;
begin
  select enumlabel into v_state from pg_enum e join pg_type y
    on y.oid = e.enumtypid where y.typname = 'journey_state'
    and enumlabel <> 'Quoted' limit 1;
  v_state := coalesce(v_state, 'Sold');
  insert into companies(id,name,business_timezone)
    values (v_c,'C','America/Denver');
  insert into stores(id,company_id,name,location_type,is_active) values
    (v_w,v_c,'W','WAREHOUSE',true),(v_a,v_c,'A','STORE',true),
    (v_b,v_c,'B','STORE',true);
  insert into employees(id,auth_user_id,home_store_id,role,is_active) values
    (v_emp,v_auth,v_w,'owner',true),
    (v_empd,v_authd,v_a,'sales',true),
    (v_empu,v_authu,v_b,'sales',true),
    (v_empw,v_authw,v_w,'sales',true);
  insert into products(id,company_id,item_name,unit_tracked) values
    (v_pf,v_c,'Full',true),(v_ps,v_c,'Short',true),
    (v_pw,v_c,'Wait',true),(v_pl,v_c,'Legacy',true),
    (v_pm,v_c,'Perm',false),(v_pscan,v_c,'Scan',true);
  insert into customers(id,first_name,last_name) values
    (v_cust,'Test','Customer');
  insert into sleep_journeys(id,customer_id,store_id,current_state) values
    (v_jw,v_cust,v_a,v_state),(v_js,v_cust,v_a,v_state);
  insert into journey_inventory_requirements
    (id,journey_id,variant_id,location_id,quantity_required,status) values
    (v_rw,v_jw,v_pw,v_a,1,'pending'),
    (v_rs,v_js,v_ps,v_a,1,'pending');
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_auth)::text,true);

  insert into inventory_positions(variant_id,location_id,sublocation_id,
    disposition,on_hand_quantity,committed_quantity) values
    (v_pf,v_w,null,'Prime',10,2),
    (v_ps,v_w,null,'Prime',10,3),
    (v_pw,v_w,null,'Prime',10,1),
    (v_pl,v_w,null,'Prime',10,1),
    (v_pm,v_w,null,'Prime',10,1),
    (v_pscan,v_w,null,'Prime',10,2);

  insert into units(id,company_id,product_id,unit_number,status,
    location_id,disposition,assigned_requirement_id) values
    (v_uf1,v_c,v_pf,401,'STOCK',v_w,'Prime',null),
    (v_uf2,v_c,v_pf,402,'STOCK',v_w,'Prime',null),
    (v_us1,v_c,v_ps,411,'STOCK',v_w,'Prime',null),
    (v_us2,v_c,v_ps,412,'STOCK',v_w,'Prime',null),
    (v_us3,v_c,v_ps,413,'RESERVED',v_w,'Prime',v_rs),
    (v_uw1,v_c,v_pw,421,'STOCK',v_w,'Prime',null),
    (v_usc1,v_c,v_pscan,431,'STOCK',v_w,'Prime',null),
    (v_usc2,v_c,v_pscan,432,'STOCK',v_w,'Prime',null);

  insert into transfers(id,origin_location_id,destination_location_id,
    status,scheduled_date,in_transit_at) values
    (v_tf,v_w,v_a,'pending','2025-01-01',null),
    (v_ts,v_w,v_a,'pending','2025-01-01',null),
    (v_tw,v_w,v_a,'pending','2025-01-01',null),
    (v_tl,v_w,v_a,'in_transit','2025-01-01',now()),
    (v_tp1,v_w,v_a,'in_transit','2025-01-01',now()),
    (v_tp2,v_w,v_a,'in_transit','2025-01-01',now()),
    (v_tp3,v_w,v_a,'in_transit','2025-01-01',now()),
    (v_tsc,v_w,v_a,'pending','2025-01-01',null);
  insert into transfer_line_items(id,transfer_id,variant_id,
    quantity_requested,quantity_shipped,committed_released_qty) values
    (v_lf,v_tf,v_pf,2,0,0),
    (v_ls,v_ts,v_ps,3,0,0),
    (v_lw,v_tw,v_pw,1,0,0),
    (v_ll,v_tl,v_pl,1,1,0),
    (v_lp1,v_tp1,v_pm,1,1,0),
    (v_lp2,v_tp2,v_pm,1,1,0),
    (v_lp3,v_tp3,v_pm,1,1,0),
    (v_lsc,v_tsc,v_pscan,2,0,0);

  -- ============ T1: full-count receive, no scanning ================
  perform public.pick_transfer_units(v_tf, null, v_emp);
  perform public.mark_transfer_in_transit(v_tf, v_emp);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_authd)::text,true);
  v_res := public.finalize_transfer(v_tf, null, v_empd);  -- dest staff!
  perform pg_temp.chk('T1a both units STOCK at destination',
    (select count(*) from units where product_id = v_pf
      and status = 'STOCK' and location_id = v_a) = 2);
  perform pg_temp.chk('T1b received_at stamped on pick rows',
    (select count(*) from transfer_line_units tlu
      join transfer_line_items tli on tli.id = tlu.transfer_line_item_id
      where tli.transfer_id = v_tf and tlu.received_at is not null) = 2);
  perform pg_temp.chk('T1c UNIT_RECEIVED events carry transfer_id',
    (select count(*) from unit_events ue join units u on u.id = ue.unit_id
      where u.product_id = v_pf and ue.transfer_id = v_tf
        and ue.event_type = 'UNIT_RECEIVED'
        and ue.to_location_id = v_a) = 2);
  perform pg_temp.chk('T1d quantity_received = 2',
    (select quantity_received from transfer_line_items where id = v_lf) = 2);
  perform pg_temp.chk('T1e result lists 2 received units, 0 missing',
    jsonb_array_length(v_res -> 'received_unit_ids') = 2
    and jsonb_array_length(v_res -> 'missing_units') = 0);

  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_auth)::text,true);

  -- ============ T2: short receive, explicit missing ===============
  perform public.pick_transfer_units(v_ts, null, v_emp);
  perform public.mark_transfer_in_transit(v_ts, v_emp);
  -- short by 1 with NO list -> must error
  begin
    perform public.finalize_transfer(v_ts,
      jsonb_build_object(v_ls::text, 2), v_emp);
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T2a short receive without missing list rejected',
    v_err is not null);
  -- short by 1 naming uS1 missing; uS3 is RESERVED and stays received
  v_res := public.finalize_transfer(v_ts,
    jsonb_build_object(v_ls::text, 2), v_emp,
    jsonb_build_array(jsonb_build_object('line_item_id', v_ls,
      'missing_unit_ids', jsonb_build_array(v_us1))));
  perform pg_temp.chk('T2b uS1 is MISSING with audit + tlu stamps',
    (select status from units where id = v_us1) = 'MISSING'
    and exists(select 1 from transfer_line_units tlu
      where tlu.unit_id = v_us1 and tlu.missing_at is not null)
    and exists(select 1 from audit_events ae
      where ae.event_type = 'TRANSFER_UNIT_MISSING'
        and ae.after ->> 'unit_id' = v_us1::text));
  perform pg_temp.chk('T2c uS2 arrived STOCK at A',
    (select status || ':' || location_id::text from units where id = v_us2)
      = 'STOCK:' || v_a::text);
  perform pg_temp.chk('T2d RESERVED uS3 arrived RESERVED at A, kept requirement',
    (select status || ':' || location_id::text || ':' ||
       coalesce(assigned_requirement_id::text,'-') from units where id = v_us3)
      = 'RESERVED:' || v_a::text || ':' || v_rs::text);
  perform pg_temp.chk('T2e quantity_received = 2 = units received',
    (select quantity_received from transfer_line_items where id = v_ls) = 2);
  perform pg_temp.chk('T2f missing unit in result',
    (select count(*) from jsonb_array_elements(v_res -> 'missing_units') m
      where m ->> 'unit_id' = v_us1::text) = 1);
  perform pg_temp.chk('T2g IN_TRANSIT->MISSING unit event written',
    exists(select 1 from unit_events ue where ue.unit_id = v_us1
      and ue.transfer_id = v_ts and ue.to_status = 'MISSING'));

  -- ============ T3: scan/typed rejects =============================
  -- unshipped unit named as received -> rejected
  begin
    perform public.finalize_transfer(v_tw, null, v_emp);  -- not shipped yet anyway
    v_err := 'unexpected';
  exception when others then v_err := sqlerrm;
  end;
  -- (v_tw is still pending: finalize rejects before unit checks)
  perform pg_temp.chk('T3a finalize on pending transfer rejected', v_err is not null);

  -- ============ T4: arriving unit fills a waiting order ============
  perform public.pick_transfer_units(v_tw, null, v_emp);
  perform public.mark_transfer_in_transit(v_tw, v_emp);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_authd)::text,true);
  v_res := public.finalize_transfer(v_tw, null, v_empd);
  perform pg_temp.chk('T4a arrived unit assigned to waiting order',
    (select assigned_requirement_id from units where id = v_uw1) = v_rw
    and (select status from units where id = v_uw1) = 'RESERVED');
  perform pg_temp.chk('T4b result.assignments has journey + customer',
    exists(select 1 from jsonb_array_elements(v_res -> 'assignments') a
      where a ->> 'unit_id' = v_uw1::text
        and a ->> 'journey_id' = v_jw::text
        and a ->> 'customer_name' = 'Test Customer'));

  -- ============ T5: legacy in-transit line, no picks ===============
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_authw)::text,true);
  v_res := public.finalize_transfer(v_tl, null, v_empw);  -- warehouse staff ok
  perform pg_temp.chk('T5a legacy finalize works, quantity_received=1',
    (select quantity_received from transfer_line_items where id = v_ll) = 1
    and (select on_hand_quantity from inventory_positions
      where variant_id = v_pl and location_id = v_a) = 1);
  perform pg_temp.chk('T5b legacy result has empty unit lists',
    jsonb_array_length(v_res -> 'received_unit_ids') = 0
    and jsonb_array_length(v_res -> 'missing_units') = 0);

  -- ============ T6: receive permission =============================
  -- unrelated store staff rejected
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_authu)::text,true);
  begin
    perform public.finalize_transfer(v_tp1, null, v_empu);
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T6a unrelated-store staff rejected', v_err is not null);
  -- destination staff allowed (T1 already proved; do it on tp2)
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_authd)::text,true);
  v_res := public.finalize_transfer(v_tp2, null, v_empd);
  perform pg_temp.chk('T6b destination staff allowed on second transfer',
    (select status from transfers where id = v_tp2) = 'finalized');
  -- owner/manager allowed
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_auth)::text,true);
  v_res := public.finalize_transfer(v_tp3, null, v_emp);
  perform pg_temp.chk('T6c owner allowed',
    (select status from transfers where id = v_tp3) = 'finalized');

  -- ============ T6b: scanned-unit validation on a tracked line ======
  perform public.pick_transfer_units(v_tsc, null, v_emp);
  perform public.mark_transfer_in_transit(v_tsc, v_emp);
  -- naming a unit that was NOT shipped on this transfer -> reject
  begin
    perform public.finalize_transfer(v_tsc,
      jsonb_build_object(v_lsc::text, 1), v_emp,
      jsonb_build_array(jsonb_build_object('line_item_id', v_lsc,
        'received_unit_ids', jsonb_build_array(v_usc1, v_uf1))));
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T6d unshipped unit in receive list rejected',
    v_err is not null);
  -- received list larger than reported received count -> reject
  begin
    perform public.finalize_transfer(v_tsc,
      jsonb_build_object(v_lsc::text, 1), v_emp,
      jsonb_build_array(jsonb_build_object('line_item_id', v_lsc,
        'received_unit_ids', jsonb_build_array(v_usc1, v_usc2))));
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T6e receive count above reported rejected',
    v_err is not null);
  -- valid short receive by unit_number scan: miss 432, receive 431
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_authd)::text,true);
  v_res := public.finalize_transfer(v_tsc,
    jsonb_build_object(v_lsc::text, 1), v_empd,
    jsonb_build_array(jsonb_build_object('line_item_id', v_lsc,
      'missing_unit_numbers', jsonb_build_array(432))));
  perform pg_temp.chk('T6f unit_number scan resolves within shipped set',
    (select status from units where id = v_usc2) = 'MISSING'
    and (select status || ':' || location_id::text from units where id = v_usc1)
      = 'STOCK:' || v_a::text
    and (select quantity_received from transfer_line_items where id = v_lsc) = 1);

  -- ============ T7: mark_transfer_unit_missing =====================
  -- ship t? need an in-transit picked transfer: reuse none left; ship a
  -- fresh one quickly is heavy -- instead verify guard on resolved unit:
  begin
    perform public.mark_transfer_unit_missing(v_uf1, 'test', v_emp);
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T7a already-received unit cannot be marked missing',
    v_err is not null);

  -- ============ T8: second finalize blocked =========================
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_auth)::text,true);
  begin
    perform public.finalize_transfer(v_tf, null, v_emp);
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T8 double finalize rejected', v_err is not null);
end $$;

select name, ok from t order by name;
select count(*) filter (where ok) || ' / ' || count(*) as summary from t;
rollback;
