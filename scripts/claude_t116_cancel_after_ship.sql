begin;
create temp table t(name text, ok boolean, detail text);
create or replace function pg_temp.chk(nm text, cond boolean, d text default '') returns void language sql as $$ insert into t values (nm, coalesce(cond,false), d) $$;
do $$
declare
 v_c uuid:=gen_random_uuid(); v_w uuid:=gen_random_uuid(); v_a uuid:=gen_random_uuid();
 v_emp uuid:=gen_random_uuid(); v_auth uuid:=gen_random_uuid(); v_p uuid:=gen_random_uuid();
 v_cust uuid:=gen_random_uuid(); v_ja uuid:=gen_random_uuid(); v_jb uuid:=gen_random_uuid(); v_jc uuid:=gen_random_uuid();
 v_ra uuid:=gen_random_uuid(); v_rb uuid:=gen_random_uuid(); v_rc uuid:=gen_random_uuid();
 v_tr uuid:=gen_random_uuid(); v_line uuid; v_req uuid; v_n int; v_h int; v_st text;
begin
 insert into companies(id,name,business_timezone) values (v_c,'C','America/Denver');
 insert into stores(id,company_id,name,location_type,is_active) values (v_w,v_c,'W','WAREHOUSE',true),(v_a,v_c,'A','STORE',true);
 insert into employees(id,auth_user_id,home_store_id,role,is_active) values (v_emp,v_auth,v_w,'owner',true);
 insert into products(id,company_id,sku,item_name,unit_tracked) values (v_p,v_c,'X116','X116',false);
 insert into customers(id,first_name,last_name) values (v_cust,'T','U');
 insert into inventory_positions(variant_id,location_id,disposition,on_hand_quantity,committed_quantity) values (v_p,v_w,'Prime',10,0);
 perform set_config('request.jwt.claims', jsonb_build_object('sub',v_auth)::text, true);
 -- order B (stays live, hold 1) and order A (hold 2)
 insert into sleep_journeys(id,customer_id,store_id,current_state,journey_number) values (v_jb,v_cust,v_a,'Sold','B'),(v_ja,v_cust,v_a,'Sold','A');
 insert into journey_inventory_requirements(id,journey_id,variant_id,location_id,quantity_required,status) values (v_rb,v_jb,v_p,v_a,1,'pending'),(v_ra,v_ja,v_p,v_a,2,'pending');
 select committed_quantity into v_n from inventory_positions where variant_id=v_p and location_id=v_w;
 perform pg_temp.chk('S0 holds in place: committed 3', v_n=3, v_n::text);
 -- cron-like consolidation of A's request into a pending transfer (qty 2)
 insert into transfers(id,origin_location_id,destination_location_id,status,scheduled_date) values (v_tr,v_w,v_a,'pending',current_date);
 insert into transfer_line_items(transfer_id,variant_id,quantity_requested) values (v_tr,v_p,2) returning id into v_line;
 select id into v_req from transfer_requests where source_reference_id=v_ja and status='approved';
 update transfer_requests set status='consolidated', transfer_id=v_tr where id=v_req;
 -- ship
 perform public.mark_transfer_in_transit(v_tr, v_emp);
 select committed_quantity into v_n from inventory_positions where variant_id=v_p and location_id=v_w;
 perform pg_temp.chk('S1 after ship: committed = 1 (only order B)', v_n=1, v_n::text);
 -- order A cancelled while its transfer is in transit
 update sleep_journeys set cancelled_at=now() where id=v_ja;
 select committed_quantity into v_n from inventory_positions where variant_id=v_p and location_id=v_w;
 perform pg_temp.chk('S2 A cancelled after ship: B hold NOT stolen (committed still 1)', v_n=1, v_n::text);
 select status into v_st from transfers where id=v_tr;
 perform pg_temp.chk('S3 in-transit transfer not destroyed by cancel', v_st='in_transit', v_st);
 select count(*) into v_n from transfer_line_items where transfer_id=v_tr;
 perform pg_temp.chk('S4 in-transit line item not backed out', v_n=1, v_n::text);
 -- finalize: committed must remain 1
 perform public.finalize_transfer(v_tr, null, v_emp);
 select committed_quantity into v_n from inventory_positions where variant_id=v_p and location_id=v_w;
 perform pg_temp.chk('S5 after finalize: committed still 1 (B)', v_n=1, v_n::text);
 -- 114 mask: a touch on a LIVE requirement with consolidated+shipped request must not create a new request for B
 select count(*) into v_n from transfer_requests where source_reference_id=v_jb and status not in ('cancelled','rejected');
 perform pg_temp.chk('S6 order B still has exactly one open request', v_n=1, v_n::text);
 -- S7: cancel BEFORE ship (pending transfer) still correct
 insert into sleep_journeys(id,customer_id,store_id,current_state,journey_number) values (v_jc,v_cust,v_a,'Sold','C');
 insert into journey_inventory_requirements(id,journey_id,variant_id,location_id,quantity_required,status) values (v_rc,v_jc,v_p,v_a,2,'pending');
 select committed_quantity into v_n from inventory_positions where variant_id=v_p and location_id=v_w;
 perform pg_temp.chk('S7a C placed: committed 3', v_n=3, v_n::text);
 update sleep_journeys set cancelled_at=now() where id=v_jc;
 select committed_quantity into v_n from inventory_positions where variant_id=v_p and location_id=v_w;
 perform pg_temp.chk('S7b C cancelled before consolidation: committed back to 1', v_n=1, v_n::text);
exception when others then perform pg_temp.chk('99 harness error', false, sqlerrm);
end $$;
select name, ok, detail from t order by name;
rollback;
