-- S4a-2 checks: unit-level ship + committed-release-at-ship.
-- DB with migrations 001..116 applied. pg_temp.chk style, rolls back.
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
  v_pa uuid := gen_random_uuid(); v_pb uuid := gen_random_uuid();
  v_pc uuid := gen_random_uuid(); v_pd uuid := gen_random_uuid();
  v_pu uuid := gen_random_uuid();
  v_cust uuid := gen_random_uuid();
  v_ja uuid := gen_random_uuid(); v_ra uuid := gen_random_uuid();
  v_state text;
  v_tl uuid := gen_random_uuid(); v_tp uuid := gen_random_uuid();
  v_tc uuid := gen_random_uuid(); v_td uuid := gen_random_uuid();
  v_tu uuid := gen_random_uuid();
  v_ll uuid := gen_random_uuid(); v_lp uuid := gen_random_uuid();
  v_lc uuid := gen_random_uuid(); v_ld uuid := gen_random_uuid();
  v_lu uuid := gen_random_uuid();
  v_ua1 uuid := gen_random_uuid(); v_ua2 uuid := gen_random_uuid();
  v_ub1 uuid := gen_random_uuid(); v_ub2 uuid := gen_random_uuid();
  v_ub3 uuid := gen_random_uuid();
  v_uc1 uuid := gen_random_uuid(); v_uc2 uuid := gen_random_uuid();
  v_uc3 uuid := gen_random_uuid();
  v_err text; v_pos record;
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
    (v_pa,v_c,'Legacy',true),(v_pb,v_c,'Picked',true),
    (v_pc,v_c,'Partial',true),(v_pd,v_c,'OldTransit',true),
    (v_pu,v_c,'Untracked',false);
  insert into customers(id,first_name,last_name) values (v_cust,'T','U');
  insert into sleep_journeys(id,customer_id,store_id,current_state) values
    (v_ja,v_cust,v_a,v_state);
  insert into journey_inventory_requirements
    (id,journey_id,variant_id,location_id,quantity_required,status) values
    (v_ra,v_ja,v_pb,v_a,1,'pending');
  perform set_config('request.jwt.claims',
    jsonb_build_object('sub',v_auth)::text,true);

  -- origin positions: on_hand / committed (committed = approval hold)
  insert into inventory_positions(variant_id,location_id,sublocation_id,
    disposition,on_hand_quantity,committed_quantity) values
    (v_pa,v_w,null,'Prime',10,2),
    (v_pb,v_w,null,'Prime',10,3),
    (v_pc,v_w,null,'Prime',10,3),
    (v_pd,v_w,null,'Prime',10,2),
    (v_pu,v_w,null,'Prime',10,1);

  -- units at W
  insert into units(id,company_id,product_id,unit_number,status,
    location_id,disposition) values
    (v_ua1,v_c,v_pa,301,'STOCK',v_w,'Prime'),
    (v_ua2,v_c,v_pa,302,'STOCK',v_w,'Prime'),
    (v_ub1,v_c,v_pb,311,'STOCK',v_w,'Prime'),
    (v_ub2,v_c,v_pb,312,'STOCK',v_w,'Prime'),
    (v_ub3,v_c,v_pb,313,'RESERVED',v_w,'Prime',v_ra),
    (v_uc1,v_c,v_pc,321,'STOCK',v_w,'Prime'),
    (v_uc2,v_c,v_pc,322,'STOCK',v_w,'Prime'),
    (v_uc3,v_c,v_pc,323,'STOCK',v_w,'Prime');

  insert into transfers(id,origin_location_id,destination_location_id,
    status,scheduled_date) values
    (v_tl,v_w,v_a,'pending','2025-01-01'),
    (v_tp,v_w,v_a,'pending','2025-01-01'),
    (v_tc,v_w,v_a,'pending','2025-01-01'),
    (v_td,v_w,v_a,'in_transit','2025-01-01'),
    (v_tu,v_w,v_a,'pending','2025-01-01');
  insert into transfer_line_items(id,transfer_id,variant_id,
    quantity_requested,quantity_shipped) values
    (v_ll,v_tl,v_pa,2,0),
    (v_lp,v_tp,v_pb,3,0),
    (v_lc,v_tc,v_pc,3,0),
    (v_ld,v_td,v_pd,2,2),   -- old-logic in-transit: shipped, hold intact
    (v_lu,v_tu,v_pu,1,0);

  -- T1 legacy quantity-only ship: no pick rows -> units untouched,
  -- committed released AT SHIP (the ATS fix), ledger written
  perform public.mark_transfer_in_transit(v_tl, v_emp);
  select * into v_pos from inventory_positions
    where variant_id = v_pa and location_id = v_w;
  perform pg_temp.chk('T1a on_hand debited by 2', v_pos.on_hand_quantity = 8);
  perform pg_temp.chk('T1b committed released at ship (0 left)',
    v_pos.committed_quantity = 0);
  perform pg_temp.chk('T1c committed_released_qty = 2',
    (select committed_released_qty from transfer_line_items
      where id = v_ll) = 2);
  perform pg_temp.chk('T1d units NOT moved (legacy path)',
    (select count(*) from units where product_id = v_pa
      and status = 'STOCK' and location_id = v_w) = 2);

  -- T2 ATS during transit = true availability (8), not the old 6
  perform pg_temp.chk('T2 in-transit ATS is 8',
    (select on_hand_quantity - committed_quantity
       from inventory_positions
      where variant_id = v_pa and location_id = v_w) = 8);

  -- T3 finalize after new-logic ship nets correct committed + dest stock
  perform public.finalize_transfer(v_tl, null, v_emp);
  select * into v_pos from inventory_positions
    where variant_id = v_pa and location_id = v_w;
  perform pg_temp.chk('T3a origin committed stays 0 after finalize',
    v_pos.committed_quantity = 0);
  perform pg_temp.chk('T3b destination received 2',
    (select on_hand_quantity from inventory_positions
      where variant_id = v_pa and location_id = v_a) = 2);
  perform pg_temp.chk('T3c quantity_received = 2',
    (select quantity_received from transfer_line_items where id = v_ll) = 2);

  -- T4 second ship attempt errors
  begin
    perform public.mark_transfer_in_transit(v_tl, v_emp);
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T4 re-ship rejected', v_err is not null);

  -- T5 picked transfer: pick 3 units (incl. RESERVED-for-A), ship all
  perform public.pick_transfer_units(v_tp, null, v_emp);
  perform public.mark_transfer_in_transit(v_tp, v_emp);
  perform pg_temp.chk('T5a all 3 units IN_TRANSIT at origin',
    (select count(*) from units where product_id = v_pb
      and status = 'IN_TRANSIT' and location_id = v_w) = 3);
  perform pg_temp.chk('T5b unit_events carry transfer_id + UNIT_SHIPPED',
    (select count(*) from unit_events ue join units u on u.id = ue.unit_id
      where u.product_id = v_pb and ue.transfer_id = v_tp
        and ue.event_type = 'UNIT_SHIPPED'
        and ue.from_status = 'STOCK' or
        (u.product_id = v_pb and ue.transfer_id = v_tp
         and ue.event_type = 'UNIT_SHIPPED' and ue.from_status = 'RESERVED')) >= 3);
  perform pg_temp.chk('T5c RESERVED unit kept its requirement',
    exists(select 1 from units where id = v_ub3
      and status = 'IN_TRANSIT' and assigned_requirement_id = v_ra));
  perform pg_temp.chk('T5d RESERVED unit event has journey_id',
    exists(select 1 from unit_events ue where ue.unit_id = v_ub3
      and ue.transfer_id = v_tp and ue.journey_id = v_ja));
  perform pg_temp.chk('T5e origin committed released by 3 at ship',
    (select committed_quantity from inventory_positions
      where variant_id = v_pb and location_id = v_w) = 0);

  -- T6 partial ship of a picked line requires an explicit unit list
  perform public.pick_transfer_units(v_tc, null, v_emp);
  begin
    perform public.mark_transfer_in_transit(v_tc, v_emp,
      jsonb_build_object(v_lc::text, 2));
    v_err := null;
  exception when others then v_err := sqlerrm;
  end;
  perform pg_temp.chk('T6a partial ship without list rejected', v_err is not null);
  perform public.mark_transfer_in_transit(v_tc, v_emp,
    jsonb_build_object(v_lc::text, 2),
    jsonb_build_array(jsonb_build_object('line_item_id', v_lc,
      'unit_ids', jsonb_build_array(v_uc1, v_uc2))));
  perform pg_temp.chk('T6b exactly 2 units shipped',
    (select count(*) from units where product_id = v_pc
      and status = 'IN_TRANSIT') = 2);
  perform pg_temp.chk('T6c left-behind unit kept its pick row removed + still STOCK',
    (select count(*) from units where id = v_uc3
      and status = 'STOCK' and location_id = v_w) = 1
    and not exists(select 1 from transfer_line_units tlu
      join transfer_line_items tli on tli.id = tlu.transfer_line_item_id
      where tli.transfer_id = v_tc and tlu.unit_id = v_uc3));
  perform pg_temp.chk('T6d committed released = shipped qty (2), not requested (3)',
    (select committed_released_qty from transfer_line_items
      where id = v_lc) = 2
    and (select committed_quantity from inventory_positions
      where variant_id = v_pc and location_id = v_w) = 1);

  -- T7 finalize partial: releases requested - released = 1 more -> 0 total
  perform public.finalize_transfer(v_tc, null, v_emp);
  perform pg_temp.chk('T7a origin committed fully released after finalize',
    (select committed_quantity from inventory_positions
      where variant_id = v_pc and location_id = v_w) = 0);
  perform pg_temp.chk('T7b destination got shipped qty 2',
    (select on_hand_quantity from inventory_positions
      where variant_id = v_pc and location_id = v_a) = 2);

  -- T8 old-logic in-transit transfer (committed_released_qty = 0):
  -- finalize releases the FULL requested amount, exactly as before
  perform public.finalize_transfer(v_td, null, v_emp);
  perform pg_temp.chk('T8a old in-transit finalize releases full hold',
    (select committed_quantity from inventory_positions
      where variant_id = v_pd and location_id = v_w) = 0);
  perform pg_temp.chk('T8b old in-transit dest received 2',
    (select on_hand_quantity from inventory_positions
      where variant_id = v_pd and location_id = v_a) = 2);

  -- T9 untracked line ships quantity-only under the new signature
  perform public.mark_transfer_in_transit(v_tu, v_emp);
  perform pg_temp.chk('T9a untracked ship works, committed released at ship',
    (select status from transfers where id = v_tu) = 'in_transit'
    and (select committed_quantity from inventory_positions
      where variant_id = v_pu and location_id = v_w) = 0);
  perform pg_temp.chk('T9b no unit rows for untracked line',
    not exists(select 1 from transfer_line_units tlu
      join transfer_line_items tli on tli.id = tlu.transfer_line_item_id
      where tli.transfer_id = v_tu));
end $$;

select name, ok from t order by name;
select count(*) filter (where ok) || ' / ' || count(*) as summary from t;
rollback;
