-- S4a-4 checks: cancel_transfer (migration 118) + consolidated-mask fix.
-- DB with migrations 001..118 applied. pg_temp.chk style, rolls back.
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
  v_emp uuid := gen_random_uuid(); v_auth uuid := gen_random_uuid();
  v_p uuid := gen_random_uuid();
  v_cust uuid := gen_random_uuid();
  v_j uuid := gen_random_uuid(); v_r uuid := gen_random_uuid();
  v_state text;
  v_req1 uuid := gen_random_uuid(); v_req2 uuid := gen_random_uuid();
  v_t1 uuid; v_t2 uuid; v_t3 uuid; v_t1b uuid;
  v_l1 uuid; v_l2 uuid; v_l3 uuid;
  v_u1 uuid := gen_random_uuid(); v_u2 uuid := gen_random_uuid();
  v_err text; v_q int; v_res jsonb; v_comm int; v_held int;
begin
  select enumlabel into v_state from pg_enum e join pg_type y
    on y.oid = e.enumtypid where y.typname = 'journey_state'
    and enumlabel <> 'Quoted' limit 1;
  insert into companies(id,name,business_timezone)
    values (v_c,'C','America/Denver');
  insert into stores(id,company_id,name,location_type,is_active) values
    (v_w,v_c,'W','WAREHOUSE',true),(v_a,v_c,'A','STORE',true);
  insert into employees(id,auth_user_id,home_store_id,role,is_active)
    values (v_emp,v_auth,v_w,'owner',true);
  insert into products(id,company_id,item_name,unit_tracked) values
    (v_p,v_c,'Widget',true);
  insert into customers(id,first_name,last_name) values (v_cust,'T','U');
  insert into sleep_journeys(id,customer_id,store_id,current_state) values
    (v_j,v_cust,v_a,v_state);
  insert into journey_inventory_requirements
    (id,journey_id,variant_id,location_id,quantity_required,status) values
    (v_r,v_j,v_p,v_a,2,'pending');
  insert into inventory_positions(variant_id,location_id,sublocation_id,
    disposition,on_hand_quantity,committed_quantity) values
    (v_p,v_w,null,'Prime',10,0);
  insert into units(id,company_id,product_id,unit_number,status,
    location_id,disposition) values
    (v_u1,v_c,v_p,501,'STOCK',v_w,'Prime'),
    (v_u2,v_c,v_p,502,'STOCK',v_w,'Prime');
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_auth)::text,true);

  -- ============ T1: expedite -> cancel regression (non-JM) ==========
  insert into transfer_requests(id,origin_location_id,
    destination_location_id,variant_id,quantity,source_type,status)
    values (v_req1,v_w,v_a,v_p,2,'manager_requested','pending_approval');
  perform public.approve_transfer_request(v_req1, v_emp);
  select committed_quantity into v_comm from inventory_positions
    where variant_id = v_p and location_id = v_w;
  select held_quantity into v_held from transfer_requests where id = v_req1;
  perform pg_temp.chk('T1a approve committed 2 / held 2',
    v_comm = 2 and v_held = 2);

  perform public.expedite_transfer_request(v_req1, v_emp, current_date + 1);
  select transfer_id into v_t1 from transfer_requests where id = v_req1;
  perform pg_temp.chk('T1b expedite consolidated into pending transfer',
    v_t1 is not null and exists(select 1 from transfers
      where id = v_t1 and status = 'pending'));

  -- pick the two units so cancel must delete pick rows
  perform public.pick_transfer_units(v_t1, null, v_emp);
  perform pg_temp.chk('T1c pick rows exist pre-cancel',
    (select count(*) from transfer_line_units tlu
      join transfer_line_items tli on tli.id = tlu.transfer_line_item_id
      where tli.transfer_id = v_t1) = 2);

  v_res := public.cancel_transfer(v_t1, v_emp, 'test cancel');
  select committed_quantity into v_comm from inventory_positions
    where variant_id = v_p and location_id = v_w;
  select status::text, held_quantity, transfer_id into v_err, v_held, v_t2
    from transfer_requests where id = v_req1;
  perform pg_temp.chk('T1d committed back to pre-expedite value (2)',
    v_comm = 2);
  perform pg_temp.chk('T1e request approved, held 2, transfer_id cleared',
    v_err = 'approved' and v_held = 2 and v_t2 is null);
  perform pg_temp.chk('T1f pick rows deleted, units still STOCK at W',
    not exists(select 1 from transfer_line_units tlu
      join transfer_line_items tli on tli.id = tlu.transfer_line_item_id
      where tli.transfer_id = v_t1)
    and (select count(*) from units where product_id = v_p
      and status = 'STOCK' and location_id = v_w) = 2);
  perform pg_temp.chk('T1g transfer marked cancelled + audit row',
    (select status from transfers where id = v_t1) = 'cancelled'
    and exists(select 1 from audit_events ae
      where ae.event_type = 'TRANSFER_CANCELLED'
        and ae.entity_id = v_t1));

  -- re-expedite proves the request is usable again; its units re-pick
  perform public.expedite_transfer_request(v_req1, v_emp, current_date + 1);
  select transfer_id into v_t1b from transfer_requests where id = v_req1;
  perform public.pick_transfer_units(v_t1b, null, v_emp);
  perform pg_temp.chk('T1h re-expedite + re-pick works after cancel',
    v_t1b is not null and v_t1b <> v_t1
    and (select count(*) from transfer_line_units tlu
      join transfer_line_items tli on tli.id = tlu.transfer_line_item_id
      where tli.transfer_id = v_t1b) = 2);
  perform public.cancel_transfer(v_t1b, v_emp, 'cleanup');

  -- ============ T2: JM request cancel -> sync rebuilds hold ========
  -- simulate an approved JM request with hold (as 114 would leave it)
  insert into transfer_requests(id,origin_location_id,
    destination_location_id,variant_id,quantity,held_quantity,
    source_type,source_reference_id,status)
    values (v_req2,v_w,v_a,v_p,2,2,'journey_mismatch',v_j,'approved');
  update inventory_positions
    set committed_quantity = committed_quantity + 2
    where variant_id = v_p and location_id = v_w;
  select committed_quantity into v_comm from inventory_positions
    where variant_id = v_p and location_id = v_w;
  perform pg_temp.chk('T2a pre-expedite committed = 4 (2+2 holds)',
    v_comm = 4);

  perform public.expedite_transfer_request(v_req2, v_emp, current_date + 1);
  select transfer_id into v_t2 from transfer_requests where id = v_req2;
  v_res := public.cancel_transfer(v_t2, v_emp, 'jm cancel');
  select committed_quantity into v_comm from inventory_positions
    where variant_id = v_p and location_id = v_w;
  select held_quantity, quantity, status::text into v_held, v_q, v_err
    from transfer_requests where id = v_req2;
  perform pg_temp.chk('T2b JM committed back to 4 after cancel+sync',
    v_comm = 4);
  perform pg_temp.chk('T2c JM request approved, held rebuilt to 2',
    v_err = 'approved' and v_held = 2 and v_q = 2);

  -- ============ T3: mask ignores consolidated-on-cancelled ==========
  -- force the stale state the mask fix guards: consolidated request
  -- pointing at the cancelled transfer. Shortfall must become visible.
  update transfer_requests
    set status = 'consolidated', transfer_id = v_t2
    where id = v_req2;
  perform public.sync_order_transfer(v_j, v_p, v_w, v_a);
  perform pg_temp.chk('T3 cancelled-transfer quantity no longer masks need',
    exists(select 1 from transfer_requests
      where source_type = 'journey_mismatch'
        and source_reference_id = v_j and variant_id = v_p
        and destination_location_id = v_a
        and status in ('pending_approval','approved')
        and transfer_id is null));

  -- ============ T4: refusals =======================================
  insert into transfers(id,origin_location_id,destination_location_id,
    status,scheduled_date,in_transit_at) values
    (gen_random_uuid(),v_w,v_a,'in_transit','2025-01-01',now());
  select id into v_t3 from transfers where status = 'in_transit'
    and origin_location_id = v_w limit 1;
  insert into transfer_line_items(transfer_id,variant_id,quantity_requested,
    quantity_shipped) values (v_t3,v_p,1,1);
  begin
    perform public.cancel_transfer(v_t3, v_emp);
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T4a in_transit cancel refused with clear message',
    v_err like '%in transit%');

  begin
    perform public.cancel_transfer(v_t1, v_emp);  -- already cancelled
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T4b double cancel refused', v_err is not null);
end $$;

select name, ok from t order by name;
select count(*) filter (where ok) || ' / ' || count(*) as summary from t;
rollback;
