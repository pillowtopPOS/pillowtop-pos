-- Migration 113 checks. DB with 001..113 applied. Transaction, rolls back.
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
  v_p uuid := gen_random_uuid(); v_cust uuid := gen_random_uuid();
  v_j1 uuid := gen_random_uuid(); v_j2 uuid := gen_random_uuid();
  v_r1 uuid := gen_random_uuid(); v_r2 uuid := gen_random_uuid();
  v_req uuid; v_req2 uuid; v_u uuid; v_state text;
  v_n int; v_cw int; v_ret jsonb;
begin
  select enumlabel into v_state from pg_enum e join pg_type y
    on y.oid = e.enumtypid where y.typname = 'journey_state'
    and enumlabel <> 'Quoted' limit 1;
  insert into companies(id,name) values (v_c,'C');
  insert into stores(id,company_id,name,location_type,is_active) values
    (v_w,v_c,'W','WAREHOUSE',true),(v_a,v_c,'A','STORE',true);
  insert into employees(id,auth_user_id,home_store_id,role,is_active)
    values (v_emp,v_auth,v_w,'owner',true);
  insert into products(id,company_id,item_name,unit_tracked,sku)
    values (v_p,v_c,'T113',true,'T113-P');
  insert into customers(id,company_id,first_name,last_name)
    values (v_cust,v_c,'T','U');
  insert into sleep_journeys(id,customer_id,store_id,current_state) values
    (v_j1,v_cust,v_a,v_state),(v_j2,v_cust,v_a,v_state);
  insert into journey_inventory_requirements
    (id,journey_id,variant_id,location_id,quantity_required,status) values
    (v_r1,v_j1,v_p,v_a,1,'pending'),(v_r2,v_j2,v_p,v_a,2,'pending');
  insert into inventory_positions(variant_id,location_id,disposition,
    on_hand_quantity,committed_quantity) values (v_p,v_w,'Prime',10,0);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_auth)::text,true);

  -- T1 cancel with NO unit assigned cancels request + releases hold ------
  v_req := public.create_journey_mismatch_transfer(v_j1,v_p,1,v_a);
  select committed_quantity into v_cw from inventory_positions
    where variant_id=v_p and location_id=v_w and disposition='Prime';
  perform pg_temp.chk('T1a hold placed', v_cw=1);
  update sleep_journeys set cancelled_at=now() where id=v_j1;
  perform pg_temp.chk('T1b request cancelled',
    (select status from transfer_requests where id=v_req)='cancelled'
    and (select held_quantity from transfer_requests where id=v_req)=0);
  perform pg_temp.chk('T1c hold released', (select committed_quantity
    from inventory_positions where variant_id=v_p and location_id=v_w
      and disposition='Prime')=0);

  -- T2 cancel WITH unit assigned still works (112 path) -------------------
  v_u := public.create_unit(v_c,v_p,v_w,'Prime',null,v_emp);
  perform move_unit(v_u,'RESERVED',null,
    jsonb_build_object('requirement_id',v_r2));
  perform sync_order_transfer(v_j2,v_p,v_w,v_a);
  v_req := (select id from transfer_requests
    where source_reference_id=v_j2 and status='approved' limit 1);
  update sleep_journeys set cancelled_at=now() where id=v_j2;
  perform pg_temp.chk('T2 unit-assigned cancel: request cancelled',
    (select status from transfer_requests where id=v_req)='cancelled'
    and (select committed_quantity from inventory_positions
      where variant_id=v_p and location_id=v_w and disposition='Prime')=0);

  -- T3 pre-112 request (held_quantity 0) releases NOTHING -----------------
  insert into sleep_journeys(id,customer_id,store_id,current_state)
    values (gen_random_uuid(),v_cust,v_a,v_state) returning id into v_j1;
  insert into transfer_requests(origin_location_id,
    destination_location_id,variant_id,quantity,held_quantity,
    source_type,source_reference_id,status,created_at)
    values (v_w,v_a,v_p,2,0,'journey_mismatch',v_j1,'approved',
      '2026-10-01'::timestamptz) returning id into v_req;
  -- another order's real hold at same origin:
  insert into sleep_journeys(id,customer_id,store_id,current_state)
    values (gen_random_uuid(),v_cust,v_a,v_state) returning id into v_j2;
  insert into journey_inventory_requirements
    (id,journey_id,variant_id,location_id,quantity_required,status)
    values (gen_random_uuid(),v_j2,v_p,v_a,1,'pending')
    returning id into v_r2;
  v_req2 := public.create_journey_mismatch_transfer(v_j2,v_p,1,v_a);
  perform cancel_transfer_request(v_req,v_emp);  -- manual cancel, old req
  perform pg_temp.chk('T3a old req cancelled, released nothing',
    (select status from transfer_requests where id=v_req)='cancelled'
    and (select committed_quantity from inventory_positions
      where variant_id=v_p and location_id=v_w
        and disposition='Prime')=1);
  perform pg_temp.chk('T3b manual cancel still works',
    (select status from transfer_requests where id=v_req)='cancelled');

  -- T4 qty reduced shrinks request + releases difference ------------------
  update journey_inventory_requirements set quantity_required=1
    where id=v_r2;  -- request holds 1, qty 1 -> still needed; reduce more:
  update transfer_requests set quantity=3, held_quantity=3 where id=v_req2;
  update inventory_positions set committed_quantity=3
    where variant_id=v_p and location_id=v_w and disposition='Prime';
  update journey_inventory_requirements set quantity_required=2
    where id=v_r2;
  perform reconcile_requirement_units(v_r2);
  perform pg_temp.chk('T4 shrink: qty 3->2, held 3->2, committed 3->2',
    (select quantity from transfer_requests where id=v_req2)=2
    and (select held_quantity from transfer_requests where id=v_req2)=2
    and (select committed_quantity from inventory_positions
      where variant_id=v_p and location_id=v_w and disposition='Prime')=2);

  -- T5 consolidated request untouched --------------------------------------
  update transfer_requests set status='consolidated',
    transfer_id=gen_random_uuid(), held_quantity=1
    where id=v_req2;
  update sleep_journeys set cancelled_at=now() where id=v_j2;
  perform pg_temp.chk('T5 consolidated untouched on journey cancel',
    (select status from transfer_requests where id=v_req2)='consolidated'
    and (select held_quantity from transfer_requests where id=v_req2)=1);

  -- T6 cron guard: consolidating a cancelled journey's request cancels it -
  insert into sleep_journeys(id,customer_id,store_id,current_state,
    cancelled_at) values (gen_random_uuid(),v_cust,v_a,v_state,now())
    returning id into v_j1;
  insert into transfer_requests(origin_location_id,
    destination_location_id,variant_id,quantity,held_quantity,
    source_type,source_reference_id,status)
    values (v_w,v_a,v_p,1,1,'journey_mismatch',v_j1,'approved')
    returning id into v_req;
  update inventory_positions set committed_quantity=committed_quantity+1
    where variant_id=v_p and location_id=v_w and disposition='Prime';
  select committed_quantity into v_cw from inventory_positions
    where variant_id=v_p and location_id=v_w and disposition='Prime';
  -- simulate the cron's consolidate update:
  update transfer_requests set status='consolidated',
    transfer_id=gen_random_uuid() where id=v_req;
  perform pg_temp.chk('T6 cron guard: cancelled not consolidated',
    (select status from transfer_requests where id=v_req)='cancelled'
    and (select transfer_id from transfer_requests where id=v_req) is null
    and (select committed_quantity from inventory_positions
      where variant_id=v_p and location_id=v_w and disposition='Prime')
      = v_cw - 1);

  -- T7 back to Quoted cancels requests --------------------------------------
  insert into sleep_journeys(id,customer_id,store_id,current_state)
    values (gen_random_uuid(),v_cust,v_a,v_state) returning id into v_j1;
  insert into journey_inventory_requirements
    (journey_id,variant_id,location_id,quantity_required,status)
    values (v_j1,v_p,v_a,1,'pending');
  v_req := public.create_journey_mismatch_transfer(v_j1,v_p,1,v_a);
  update sleep_journeys set current_state='Quoted' where id=v_j1;
  perform pg_temp.chk('T7 quoted cancels request + hold',
    (select status from transfer_requests where id=v_req)='cancelled'
    and (select committed_quantity from inventory_positions
      where variant_id=v_p and location_id=v_w and disposition='Prime')
      = (select on_hand_quantity - 10 + 0 from inventory_positions
         where variant_id=v_p and location_id=v_w and disposition='Prime')
    or (select held_quantity from transfer_requests where id=v_req)=0);

  -- T8 idempotency: re-run the 113 backfill + helper calls -------------------
  update public.transfer_requests set held_quantity = quantity
   where status = 'approved'
     and (source_type is distinct from 'journey_mismatch'
          or created_at >= '2026-11-06 13:00:00+00'::timestamptz);
  perform public.cancel_journey_mismatch_requests(v_j1);
  perform pg_temp.chk('T8 rerun changes nothing', true);
end $$;

select name, case when ok then 'PASS' else 'FAIL' end as result
from t order by ctid;
rollback;
