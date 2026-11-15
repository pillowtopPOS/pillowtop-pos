-- Migration 114 checks. DB with 001..114 applied. Transaction, rolls back.
begin;
create temp table t(name text, ok boolean);
create or replace function pg_temp.chk(nm text, cond boolean)
returns void language sql as $$
  insert into t values (nm, coalesce(cond, false));
$$;

do $$
declare
  v_c uuid := gen_random_uuid();
  v_w uuid := gen_random_uuid(); v_a uuid := gen_random_uuid(); v_x uuid := gen_random_uuid();
  v_emp uuid := gen_random_uuid(); v_auth uuid := gen_random_uuid();
  v_p uuid := gen_random_uuid(); v_pu uuid := gen_random_uuid();
  v_cust uuid := gen_random_uuid();
  v_j uuid := gen_random_uuid();
  v_r uuid := gen_random_uuid();
  v_req uuid; v_n int; v_cw int;
begin
  insert into companies(id,name) values (v_c,'C');
  insert into stores(id,company_id,name,location_type,is_active) values
    (v_w,v_c,'W','WAREHOUSE',true),(v_a,v_c,'A','STORE',true),
    (v_x,v_c,'X','STORE',true);
  insert into employees(id,auth_user_id,home_store_id,role,is_active)
    values (v_emp,v_auth,v_w,'owner',true);
  insert into products(id,company_id,item_name,unit_tracked,sku) values
    (v_p,v_c,'T114',true,'T114-P'),(v_pu,v_c,'T114U',false,'T114-U');
  insert into customers(id,company_id,first_name,last_name)
    values (v_cust,v_c,'T','U');
  insert into inventory_positions(variant_id,location_id,disposition,
    on_hand_quantity,committed_quantity) values
    (v_p,v_w,'Prime',5,0),(v_p,v_x,'Prime',5,0),(v_pu,v_w,'Prime',5,0);
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_auth)::text,true);

  -- T1 order vs warehouse stock, NO workspace: request + hold at write ----
  insert into sleep_journeys(id,customer_id,store_id,current_state)
    values (v_j,v_cust,v_a,'Sold');
  insert into journey_inventory_requirements
    (id,journey_id,variant_id,location_id,quantity_required,status)
    values (v_r,v_j,v_p,v_a,1,'pending');
  select id into v_req from transfer_requests
    where source_reference_id=v_j and status='approved' limit 1;
  perform pg_temp.chk('T1a request exists at write time', v_req is not null);
  perform pg_temp.chk('T1b warehouse-first origin + hold',
    (select origin_location_id from transfer_requests where id=v_req)=v_w
    and (select held_quantity from transfer_requests where id=v_req)=1
    and (select committed_quantity from inventory_positions
      where variant_id=v_p and location_id=v_w and disposition='Prime')=1);
  -- older store unit never chosen when warehouse covers:
  perform pg_temp.chk('T1c store X not origin', (select origin_location_id
    from transfer_requests where id=v_req)<>v_x);

  -- T2 run sync twice: still exactly one request, one hold -----------------
  perform public.trg_sync_requirement_request(v_r);
  perform public.trg_sync_requirement_request(v_r);
  select count(*) into v_n from transfer_requests
    where source_reference_id=v_j and status='approved';
  perform pg_temp.chk('T2 idempotent: one request, hold=1',
    v_n=1 and (select committed_quantity from inventory_positions
      where variant_id=v_p and location_id=v_w and disposition='Prime')=1);

  -- T3 qty up grows, qty down shrinks --------------------------------------
  update journey_inventory_requirements set quantity_required=3 where id=v_r;
  perform pg_temp.chk('T3a qty up 1->3: request+hold grow',
    (select quantity from transfer_requests where id=v_req)=3
    and (select held_quantity from transfer_requests where id=v_req)=3
    and (select committed_quantity from inventory_positions
      where variant_id=v_p and location_id=v_w and disposition='Prime')=3);
  update journey_inventory_requirements set quantity_required=1 where id=v_r;
  perform pg_temp.chk('T3b qty down 3->1: request+hold shrink',
    (select quantity from transfer_requests where id=v_req)=1
    and (select committed_quantity from inventory_positions
      where variant_id=v_p and location_id=v_w and disposition='Prime')=1);

  -- T4 cancel releases ------------------------------------------------------
  update sleep_journeys set cancelled_at=now() where id=v_j;
  perform pg_temp.chk('T4 cancel: request cancelled, hold 0',
    (select status from transfer_requests where id=v_req)='cancelled'
    and (select committed_quantity from inventory_positions
      where variant_id=v_p and location_id=v_w and disposition='Prime')=0);

  -- T5 Quoted creates nothing; Sold creates it ------------------------------
  v_j := gen_random_uuid(); v_r := gen_random_uuid();
  insert into sleep_journeys(id,customer_id,store_id,current_state)
    values (v_j,v_cust,v_a,'Quoted');
  insert into journey_inventory_requirements
    (id,journey_id,variant_id,location_id,quantity_required,status)
    values (v_r,v_j,v_p,v_a,2,'pending');
  perform pg_temp.chk('T5a Quoted: no request, no hold',
    not exists(select 1 from transfer_requests where source_reference_id=v_j)
    and (select committed_quantity from inventory_positions
      where variant_id=v_p and location_id=v_w and disposition='Prime')=0);
  update sleep_journeys set current_state='Sold' where id=v_j;
  select id into v_req from transfer_requests
    where source_reference_id=v_j and status='approved' limit 1;
  perform pg_temp.chk('T5b Sold: request qty2 + hold2',
    v_req is not null
    and (select quantity from transfer_requests where id=v_req)=2
    and (select committed_quantity from inventory_positions
      where variant_id=v_p and location_id=v_w and disposition='Prime')=2);

  -- T6 Sold -> Quoted releases -----------------------------------------------
  update sleep_journeys set current_state='Quoted' where id=v_j;
  perform pg_temp.chk('T6 back to Quoted: cancelled + released',
    (select status from transfer_requests where id=v_req)='cancelled'
    and (select committed_quantity from inventory_positions
      where variant_id=v_p and location_id=v_w and disposition='Prime')=0);

  -- T7 untracked product order also sources at write time -------------------
  v_j := gen_random_uuid(); v_r := gen_random_uuid();
  insert into sleep_journeys(id,customer_id,store_id,current_state)
    values (v_j,v_cust,v_a,'Sold');
  insert into journey_inventory_requirements
    (id,journey_id,variant_id,location_id,quantity_required,status)
    values (v_r,v_j,v_pu,v_a,1,'pending');
  perform pg_temp.chk('T7 untracked: request + hold',
    exists(select 1 from transfer_requests
      where source_reference_id=v_j and status='approved')
    and (select committed_quantity from inventory_positions
      where variant_id=v_pu and location_id=v_w and disposition='Prime')=1);
  update sleep_journeys set cancelled_at=now() where id=v_j;

  -- T8 failure path: audit row, order save still succeeds -------------------
  create or replace function public.create_journey_mismatch_transfer(uuid,uuid,integer,uuid)
    returns uuid language plpgsql as $$ begin
      raise exception 'forced test failure'; end $$;
  v_j := gen_random_uuid(); v_r := gen_random_uuid();
  insert into sleep_journeys(id,customer_id,store_id,current_state)
    values (v_j,v_cust,v_a,'Sold');
  insert into journey_inventory_requirements
    (id,journey_id,variant_id,location_id,quantity_required,status)
    values (v_r,v_j,v_p,v_a,1,'pending');  -- must not raise
  perform pg_temp.chk('T8a order save succeeded despite failure', true);
  perform pg_temp.chk('T8b audit_events row written',
    exists(select 1 from audit_events
      where event_type='JM_REQUEST_SYNC_FAILED' and entity_id=v_r));
end $$;

select name, case when ok then 'PASS' else 'FAIL' end as result
from t order by ctid;
rollback;
