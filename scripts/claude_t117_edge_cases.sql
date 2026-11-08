begin;
create temp table t(name text, ok boolean, detail text);
create or replace function pg_temp.chk(nm text, cond boolean, d text default '') returns void language sql as $$ insert into t values (nm, coalesce(cond,false), d) $$;
do $$
declare
 v_c uuid:=gen_random_uuid(); v_w uuid:=gen_random_uuid(); v_a uuid:=gen_random_uuid();
 v_emp uuid:=gen_random_uuid(); v_auth uuid:=gen_random_uuid(); v_p uuid:=gen_random_uuid(); v_q uuid:=gen_random_uuid();
 v_cust uuid:=gen_random_uuid(); v_j uuid:=gen_random_uuid(); v_rq uuid:=gen_random_uuid();
 v_u1 uuid:=gen_random_uuid(); v_u2 uuid:=gen_random_uuid(); v_u3 uuid:=gen_random_uuid(); v_u4 uuid:=gen_random_uuid(); v_u5 uuid:=gen_random_uuid();
 v_t1 uuid:=gen_random_uuid(); v_t2 uuid:=gen_random_uuid(); v_t3 uuid:=gen_random_uuid();
 v_l1 uuid:=gen_random_uuid(); v_l2 uuid:=gen_random_uuid(); v_l3 uuid:=gen_random_uuid();
 v_r jsonb; v_st text; v_as uuid; v_n int; v_pos record; v_err text;
begin
 insert into companies(id,name,business_timezone) values (v_c,'C','America/Denver');
 insert into stores(id,company_id,name,location_type,is_active) values (v_w,v_c,'W','WAREHOUSE',true),(v_a,v_c,'A','STORE',true);
 insert into employees(id,auth_user_id,home_store_id,role,is_active) values (v_emp,v_auth,v_w,'owner',true);
 insert into products(id,company_id,sku,item_name,unit_tracked) values (v_p,v_c,'XA','XA',true),(v_q,v_c,'XB','XB',true);
 insert into customers(id,first_name,last_name) values (v_cust,'T','U');
 insert into sleep_journeys(id,customer_id,store_id,current_state,journey_number) values (v_j,v_cust,v_a,'Sold','J1');
 insert into journey_inventory_requirements(id,journey_id,variant_id,location_id,quantity_required,status) values (v_rq,v_j,v_p,v_a,1,'pending');
 perform set_config('request.jwt.claims', jsonb_build_object('sub',v_auth)::text, true);
 -- A: order-bound unit u1 (RESERVED at W for rq), plus quantity positions. Clear 114's auto request/hold first.
 insert into inventory_positions(variant_id,location_id,disposition,on_hand_quantity,committed_quantity) values (v_p,v_w,'Prime',1,0)
   on conflict do nothing;
 update inventory_positions set on_hand_quantity=1, committed_quantity=1 where variant_id=v_p and location_id=v_w;
 insert into units(id,company_id,product_id,unit_number,status,location_id,disposition,assigned_requirement_id) values (v_u1,v_c,v_p,501,'STOCK',v_w,'Prime',null);
 perform public.move_unit(v_u1,'RESERVED',null,jsonb_build_object('requirement_id',v_rq));
 insert into transfers(id,origin_location_id,destination_location_id,status,scheduled_date) values (v_t1,v_w,v_a,'pending',current_date);
 insert into transfer_line_items(id,transfer_id,variant_id,quantity_requested) values (v_l1,v_t1,v_p,1);
 perform public.pick_transfer_units(v_t1,null,v_emp);
 perform public.mark_transfer_in_transit(v_t1,v_emp);
 -- order CANCELLED while unit in transit
 update sleep_journeys set cancelled_at=now() where id=v_j;
 v_r := public.finalize_transfer(v_t1,null,v_emp);
 select status, assigned_requirement_id into v_st, v_as from units where id=v_u1;
 perform pg_temp.chk('E1 cancelled-in-transit: unit arrives as plain STOCK, unassigned', v_st='STOCK' and v_as is null, coalesce(v_st,'null')||' '||coalesce(v_as::text,'null'));
 select location_id=v_a into v_err from units where id=v_u1;
 perform pg_temp.chk('E1b unit physically at destination', v_err='true', coalesce(v_err,'null'));
 -- B: 2 units shipped, one marked missing BEFORE finalize, then finalize with received=1
 insert into units(id,company_id,product_id,unit_number,status,location_id,disposition) values (v_u2,v_c,v_q,511,'STOCK',v_w,'Prime'),(v_u3,v_c,v_q,512,'STOCK',v_w,'Prime');
 insert into inventory_positions(variant_id,location_id,disposition,on_hand_quantity,committed_quantity) values (v_q,v_w,'Prime',2,2);
 insert into transfers(id,origin_location_id,destination_location_id,status,scheduled_date) values (v_t2,v_w,v_a,'pending',current_date);
 insert into transfer_line_items(id,transfer_id,variant_id,quantity_requested) values (v_l2,v_t2,v_q,2);
 perform public.pick_transfer_units(v_t2,null,v_emp);
 perform public.mark_transfer_in_transit(v_t2,v_emp);
 perform public.mark_transfer_unit_missing(v_u3,'lost on truck',v_emp);
 begin
   perform public.finalize_transfer(v_t2,null,v_emp); v_err:=null;
 exception when others then v_err:=sqlerrm; end;
 perform pg_temp.chk('E2a pre-missing + default full count is rejected (not silently wrong)', v_err is not null, coalesce(v_err,'accepted'));
 v_r := public.finalize_transfer(v_t2, jsonb_build_object(v_l2::text,1), v_emp);
 select * into v_pos from inventory_positions where variant_id=v_q and location_id=v_w;
 perform pg_temp.chk('E2b origin: on_hand 0, committed 0 after missing+finalize', v_pos.on_hand_quantity=0 and v_pos.committed_quantity=0, v_pos.on_hand_quantity||'/'||v_pos.committed_quantity);
 select on_hand_quantity into v_n from inventory_positions where variant_id=v_q and location_id=v_a;
 perform pg_temp.chk('E2c destination credited only 1', v_n=1, coalesce(v_n::text,'null'));
 perform pg_temp.chk('E2d u2 STOCK at A, u3 MISSING', (select status from units where id=v_u2)='STOCK' and (select status from units where id=v_u3)='MISSING');
 perform pg_temp.chk('E2e missing unit listed in finalize result', jsonb_array_length(v_r->'missing_units')=1, v_r::text);
 -- C: short receive named by unit_number only
 insert into units(id,company_id,product_id,unit_number,status,location_id,disposition) values (v_u4,v_c,v_q,521,'STOCK',v_w,'Prime'),(v_u5,v_c,v_q,522,'STOCK',v_w,'Prime');
 update inventory_positions set on_hand_quantity=2, committed_quantity=2 where variant_id=v_q and location_id=v_w;
 insert into transfers(id,origin_location_id,destination_location_id,status,scheduled_date) values (v_t3,v_w,v_a,'pending',current_date);
 insert into transfer_line_items(id,transfer_id,variant_id,quantity_requested) values (v_l3,v_t3,v_q,2);
 perform public.pick_transfer_units(v_t3,null,v_emp);
 perform public.mark_transfer_in_transit(v_t3,v_emp);
 v_r := public.finalize_transfer(v_t3, jsonb_build_object(v_l3::text,1), v_emp,
   jsonb_build_array(jsonb_build_object('line_item_id',v_l3,'received_unit_numbers',jsonb_build_array(521),'missing_reason','damaged')));
 perform pg_temp.chk('E3 typed unit number 521 received, 522 missing', (select status from units where id=v_u4)='STOCK' and (select status from units where id=v_u5)='MISSING', (select status from units where id=v_u4)||' '||(select status from units where id=v_u5));
exception when others then perform pg_temp.chk('99 harness error', false, sqlerrm);
end $$;
select name, ok, left(detail,110) d from t order by name;
rollback;
