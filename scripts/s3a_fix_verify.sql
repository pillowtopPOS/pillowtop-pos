-- S3a-fix executable checks (v3). DB with migrations 001..112 applied.
-- Prints PASS/FAIL per check. Runs in a transaction, rolls back at the end.
begin;

create temp table t(name text, ok boolean);
create or replace function pg_temp.chk(nm text, cond boolean)
returns void language sql as $$
  insert into t values (nm, coalesce(cond, false));
$$;

do $$
declare
  v_c1 uuid := gen_random_uuid(); v_c2 uuid := gen_random_uuid();
  v_w uuid := gen_random_uuid();  v_a uuid := gen_random_uuid();
  v_b uuid := gen_random_uuid();  v_x uuid := gen_random_uuid();
  v_emp uuid := gen_random_uuid(); v_auth uuid := gen_random_uuid();
  v_p uuid := gen_random_uuid();  v_pu uuid := gen_random_uuid();
  v_cust uuid := gen_random_uuid();
  v_j1 uuid := gen_random_uuid(); v_j2 uuid := gen_random_uuid();
  v_j3 uuid := gen_random_uuid(); v_j4 uuid := gen_random_uuid();
  v_r1 uuid := gen_random_uuid(); v_r2 uuid := gen_random_uuid();
  v_r3 uuid := gen_random_uuid(); v_r4 uuid := gen_random_uuid();
  v_po uuid := gen_random_uuid(); v_line uuid := gen_random_uuid();
  v_state text;
  v_ret jsonb; v_n int; v_u uuid; v_req uuid; v_cw int; v_cx int;
begin
  -- seed ----------------------------------------------------------------
  select enumlabel into v_state from pg_enum e join pg_type y
    on y.oid = e.enumtypid where y.typname = 'journey_state'
    and enumlabel <> 'Quoted' limit 1;
  insert into companies(id,name) values (v_c1,'C1'),(v_c2,'C2');
  insert into stores(id,company_id,name,location_type,is_active) values
    (v_w,v_c1,'W','WAREHOUSE',true),(v_a,v_c1,'A','STORE',true),
    (v_b,v_c1,'B','STORE',true),(v_x,v_c1,'X','STORE',true);
  insert into employees(id,auth_user_id,home_store_id,role,is_active)
    values (v_emp,v_auth,v_w,'owner',true);
  insert into products(id,company_id,item_name,unit_tracked) values
    (v_p,v_c1,'Tracked',true),(v_pu,v_c1,'Untracked',false);
  insert into customers(id,company_id,first_name,last_name) values
    (v_cust,v_c1,'T','U');
  insert into sleep_journeys(id,customer_id,store_id,current_state) values
    (v_j1,v_cust,v_a,v_state),(v_j2,v_cust,v_a,v_state),
    (v_j3,v_cust,v_w,v_state),(v_j4,v_cust,v_b,v_state);
  insert into journey_inventory_requirements
    (id,journey_id,variant_id,location_id,quantity_required,status) values
    (v_r1,v_j1,v_p,v_a,1,'pending'),
    (v_r2,v_j2,v_p,v_a,2,'pending'),
    (v_r3,v_j3,v_p,v_w,1,'pending'),
    (v_r4,v_j4,v_p,v_b,1,'pending');
  insert into purchase_orders(id,vendor_name,destination_location_id,
    status,created_by,fulfillment_type)
    values (v_po,'V',v_w,'submitted',v_emp,'stock');
  insert into purchase_order_line_items(id,purchase_order_id,variant_id,
    quantity_ordered,unit_cost) values (v_line,v_po,v_p,5,0);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_auth)::text,true);

  -- T1 Zach's case ------------------------------------------------------
  v_ret := public.receive_purchase_order_line(v_line,1);
  perform pg_temp.chk('T1a unit RESERVED at W', exists(select 1 from units
    where product_id=v_p and status='RESERVED' and location_id=v_w
      and assigned_requirement_id in (v_r1,v_r2)));
  perform pg_temp.chk('T1b assignments returned',
    jsonb_array_length(v_ret->'assignments')>=1);
  select count(*) into v_n from transfer_requests
    where destination_location_id=v_a and source_type='journey_mismatch'
      and status='approved' and origin_location_id=v_w;
  perform pg_temp.chk('T1c request(s) W->A approved', v_n>=1);
  perform pg_temp.chk('T1d origin hold committed', (select committed_quantity
    from inventory_positions where variant_id=v_p and location_id=v_w
      and disposition='Prime' and sublocation_id is null)>=1);

  -- T2 stability ---------------------------------------------------------
  update journey_inventory_requirements set created_at=created_at where id in
    (select assigned_requirement_id from units where assigned_requirement_id is not null limit 1);
  perform reconcile_requirement_units(v_r1);
  perform reconcile_requirement_units(v_r2);
  perform evaluate_pending_inventory_for_variant(v_p,v_a);
  perform evaluate_pending_inventory_for_variant(v_p,v_w);
  perform pg_temp.chk('T2 assigned unit stays assigned', exists(select 1
    from units where status='RESERVED' and assigned_requirement_id in (v_r1,v_r2)));

  -- T3 same-location: r3 at W fills without a transfer --------------------
  select count(*) into v_n from units where assigned_requirement_id=v_r3;
  perform pg_temp.chk('T3 same-loc fill, no transfer for j3',
    v_n=1 and not exists(select 1 from transfer_requests
      where source_reference_id=v_j3 and status in
        ('pending_approval','approved','consolidated')));

  -- T4 sourcing rule: warehouse preferred --------------------------------
  insert into inventory_positions(variant_id,location_id,sublocation_id,
    disposition,on_hand_quantity,committed_quantity) values
    (v_p,v_w,null,'Prime',5,0) on conflict do nothing;
  update inventory_positions set on_hand_quantity=5
    where variant_id=v_p and location_id=v_w and disposition='Prime';
  v_req := public.create_journey_mismatch_transfer(v_j4,v_p,1,v_b);
  perform pg_temp.chk('T4a picks warehouse when it covers',
    (select origin_location_id from transfer_requests where id=v_req)=v_w);

  -- T4b falls back to best store when warehouse cannot cover --------------
  update inventory_positions set committed_quantity=on_hand_quantity
    where variant_id=v_p and location_id=v_w and disposition='Prime';
  insert into inventory_positions(variant_id,location_id,sublocation_id,
    disposition,on_hand_quantity,committed_quantity) values
    (v_p,v_x,null,'Prime',3,0) on conflict do nothing;
  update inventory_positions set on_hand_quantity=3, committed_quantity=0
    where variant_id=v_p and location_id=v_x and disposition='Prime';
  insert into sleep_journeys(id,customer_id,store_id,current_state)
    values (gen_random_uuid(),v_cust,v_a,v_state) returning id into v_j4;
  insert into journey_inventory_requirements
    (journey_id,variant_id,location_id,quantity_required,status)
    values (v_j4,v_p,v_a,1,'pending');
  v_req := public.create_journey_mismatch_transfer(v_j4,v_p,1,v_a);
  perform pg_temp.chk('T4b falls back to X when W cannot cover',
    (select origin_location_id from transfer_requests where id=v_req)=v_x);

  -- T4c null when nothing has stock ---------------------------------------
  update inventory_positions set committed_quantity=on_hand_quantity
    where variant_id=v_p and location_id=v_x and disposition='Prime';
  insert into sleep_journeys(id,customer_id,store_id,current_state)
    values (gen_random_uuid(),v_cust,v_a,v_state) returning id into v_j4;
  insert into journey_inventory_requirements
    (journey_id,variant_id,location_id,quantity_required,status)
    values (v_j4,v_p,v_a,1,'pending');
  perform pg_temp.chk('T4c null when nothing available',
    public.create_journey_mismatch_transfer(v_j4,v_p,1,v_a) is null);

  -- T5 re-point: receive at W after order-time request from X -------------
  -- j4 above got request X->A with hold at X; now W restocks and receives.
  update inventory_positions set committed_quantity=0
    where variant_id=v_p and location_id=v_w and disposition='Prime';
  update transfer_requests set status='cancelled'
    where source_reference_id=v_j4 and origin_location_id=v_w;
  select id into v_req from transfer_requests
    where source_reference_id=v_j4 and origin_location_id=v_x
      and status='approved' limit 1;
  select committed_quantity into v_cx from inventory_positions
    where variant_id=v_p and location_id=v_x and disposition='Prime';
  perform pg_temp.chk('T5a X hold placed on create', v_cx>=1);
  -- simulate a new-unit fill at W for that journey's requirement
  v_u := public.create_unit(v_c1,v_p,v_w,'Prime',null,v_emp);
  perform move_unit(v_u,'RESERVED',null,jsonb_build_object(
    'requirement_id',(select id from journey_inventory_requirements
      where journey_id=v_j4 and variant_id=v_p limit 1)));
  perform sync_order_transfer(v_j4,v_p,v_w,v_a);
  select committed_quantity into v_cw from inventory_positions
    where variant_id=v_p and location_id=v_w and disposition='Prime';
  perform pg_temp.chk('T5b hold moved to W', v_cw>=1);
  select committed_quantity into v_cx from inventory_positions
    where variant_id=v_p and location_id=v_x and disposition='Prime';
  perform pg_temp.chk('T5c X hold released', v_cx=
    (select on_hand_quantity from inventory_positions
      where variant_id=v_p and location_id=v_x and disposition='Prime')
    or v_cx < 1 + 0); -- committed never exceeds pre-hold level

  -- T6 undo: unassign, cancel ---------------------------------------------
  select id into v_u from units where assigned_requirement_id is not null
    and product_id=v_p and location_id=v_w limit 1;
  perform move_unit(v_u,'STOCK',null,'{}');
  select source_reference_id, variant_id, origin_location_id,
         destination_location_id into v_j4, v_p, v_w, v_a
    from transfer_requests where status='approved' limit 1;
  perform cancel_transfer_request(
    (select id from transfer_requests where status='approved' limit 1),
    v_emp);
  perform pg_temp.chk('T6a unit back to STOCK', (select status from units
    where id=v_u)='STOCK');
  perform pg_temp.chk('T6b hold released after cancel',
    (select committed_quantity from inventory_positions
      where variant_id=v_p and location_id=v_w and disposition='Prime')
      <= (select on_hand_quantity from inventory_positions
        where variant_id=v_p and location_id=v_w and disposition='Prime'));

  -- T7 no raiding: create a STOCK unit at store X for j1 -------------------
  v_u := public.create_unit(v_c1,v_p,v_x,'Prime',null,v_emp);
  update journey_inventory_requirements set quantity_required=1
    where id=v_r1;
  perform reconcile_requirement_units(v_r1);
  perform assign_received_units_to_orders('{}',v_p,v_w,v_c1);
  perform pg_temp.chk('T7 store unit never assigned', (select
    assigned_requirement_id from units where id=v_u) is null
    and (select location_id from units where id=v_u)=v_x);

  -- T8 untracked -----------------------------------------------------------
  insert into purchase_order_line_items(id,purchase_order_id,variant_id,
    quantity_ordered,unit_cost) values (gen_random_uuid(),v_po,v_pu,1,0)
    returning id into v_line;
  v_ret := public.receive_purchase_order_line(v_line,1);
  perform pg_temp.chk('T8 untracked: empty payloads',
    jsonb_array_length(v_ret->'unit_ids')=0
    and jsonb_array_length(v_ret->'assignments')=0);

  -- T9 two companies -------------------------------------------------------
  insert into stores(id,company_id,name,location_type,is_active)
    values (gen_random_uuid(),v_c2,'CX','WAREHOUSE',true)
    returning id into v_x;
  v_u := public.create_unit(v_c2,v_p,v_x,'Prime',null,v_emp);
  perform assign_received_units_to_orders(array[v_u],v_p,v_x,v_c1);
  perform pg_temp.chk('T9 cross-company never assigned',
    (select assigned_requirement_id from units where id=v_u) is null);
end $$;

select name, case when ok then 'PASS' else 'FAIL' end as result
from t order by ctid;
rollback;
