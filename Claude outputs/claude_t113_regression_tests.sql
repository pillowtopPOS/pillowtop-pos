begin;
create temp table res(n int, name text, ok boolean, detail text);
create or replace function pg_temp.chk(p_n int, p_name text, p_ok boolean, p_detail text default '') returns void language sql as $$ insert into res values (p_n,p_name,coalesce(p_ok,false),p_detail) $$;
do $$
declare co uuid:=gen_random_uuid(); wh uuid:=gen_random_uuid(); sa uuid:=gen_random_uuid(); sx uuid:=gen_random_uuid();
 auo uuid:=gen_random_uuid(); eo uuid:=gen_random_uuid(); c1 uuid:=gen_random_uuid();
 p1 uuid:=gen_random_uuid(); p2 uuid:=gen_random_uuid(); p3 uuid:=gen_random_uuid(); p4 uuid:=gen_random_uuid();
 j1 uuid:=gen_random_uuid(); j2 uuid:=gen_random_uuid(); j3 uuid:=gen_random_uuid(); j4 uuid:=gen_random_uuid();
 r1 uuid; r2 uuid; rq uuid; rq2 uuid; tr uuid:=gen_random_uuid(); n int; q record; ho int;
begin
 insert into companies(id,name,business_timezone) values (co,'T','America/Denver');
 insert into stores(id,company_id,name,location_type) values (wh,co,'WH','WAREHOUSE'),(sa,co,'A','STORE'),(sx,co,'X','STORE');
 insert into auth.users(id) values (auo);
 insert into employees(id,auth_user_id,home_store_id,role) values (eo,auo,wh,'owner');
 insert into customers(id,first_name,last_name) values (c1,'Ann','Lee');
 insert into products(id,company_id,sku,item_name,price,unit_tracked) values (p1,co,'Q1','Q1',1,true),(p2,co,'Q2','Q2',1,true),(p3,co,'Q3','Q3',1,true),(p4,co,'Q4','Q4',1,true);
 insert into sleep_journeys(id,store_id,customer_id,current_state,journey_number,created_at) values (j1,sa,c1,'Sold','SJ1',now()),(j2,sa,c1,'Sold','SJ2',now()),(j3,sa,c1,'Sold','SJ3',now()),(j4,sa,c1,'Sold','SJ4',now());
 insert into journey_inventory_requirements(journey_id,variant_id,location_id,quantity_required,created_at) values (j1,p1,sa,2,now()),(j2,p2,sa,1,now()),(j3,p3,sa,1,now()),(j4,p4,sa,1,now());
 -- stock at WH for all
 insert into inventory_positions(variant_id,location_id,disposition,on_hand_quantity,committed_quantity) values (p1,wh,'Prime',5,0),(p2,wh,'Prime',5,0),(p3,wh,'Prime',5,0),(p4,wh,'Prime',5,2);
 perform set_config('request.jwt.claim.sub',auo::text,true);
 -- A: Zach's T4 scenario: order against existing warehouse stock, no units assigned; then CANCEL the order
 rq:=create_journey_mismatch_transfer(j1,p1,2,sa);
 select committed_quantity into ho from inventory_positions where variant_id=p1 and location_id=wh;
 perform pg_temp.chk(1,'A hold placed qty 2',ho=2,ho::text);
 update sleep_journeys set cancelled_at=now() where id=j1;
 select status into q from transfer_requests where id=rq;
 select committed_quantity into ho from inventory_positions where variant_id=p1 and location_id=wh;
 perform pg_temp.chk(2,'A cancel order: request cancelled and hold released',q.status='cancelled' and ho=0,q.status||' '||ho);
 -- B: reduce quantity 2 -> 1 on a live order (request shrinks)
 update journey_inventory_requirements set quantity_required=2 where journey_id=j2;
 rq:=create_journey_mismatch_transfer(j2,p2,2,sa);
 update journey_inventory_requirements set quantity_required=1 where journey_id=j2;
 perform reconcile_requirement_units((select id from journey_inventory_requirements where journey_id=j2));
 select quantity, held_quantity, status into q from transfer_requests where id=rq;
 select committed_quantity into ho from inventory_positions where variant_id=p2 and location_id=wh;
 perform pg_temp.chk(3,'B reduce qty 2->1: request 1, held 1, hold 1',q.quantity=1 and q.held_quantity=1 and ho=1,q::text||' '||ho);
 -- C: REGRESSION CHECK. A non-journey_mismatch request approved the way approve_transfer_request does (commit quantity, set status, held_quantity untouched)
 update inventory_positions set committed_quantity=committed_quantity+3 where variant_id=p3 and location_id=wh;
 insert into transfer_requests(origin_location_id,destination_location_id,variant_id,quantity,source_type,status) values (wh,sa,p3,3,'manager_requested','approved') returning id into rq2;
 select held_quantity into n from transfer_requests where id=rq2;
 perform pg_temp.chk(4,'C approved manual request records held_quantity = 3 (so cancel can release it)',n=3,'held_quantity='||n);
 perform cancel_transfer_request(rq2,eo);
 select committed_quantity into ho from inventory_positions where variant_id=p3 and location_id=wh;
 perform pg_temp.chk(5,'C cancel of approved manual request releases its 3 hold',ho=0,'committed='||ho);
 -- D: cron guard leaves an EMPTY transfer behind?
 insert into transfers(id) values (tr);
 insert into transfer_line_items(transfer_id,variant_id,quantity_requested) values (tr,p4,1);
 insert into sleep_journeys(id,store_id,customer_id,current_state,journey_number,created_at,cancelled_at) values (gen_random_uuid(),sa,c1,'Sold','SJX',now(),now()) returning id into j3;
 insert into transfer_requests(origin_location_id,destination_location_id,variant_id,quantity,held_quantity,source_type,source_reference_id,status) values (wh,sa,p4,1,0,'journey_mismatch',j3,'approved') returning id into rq;
 update transfer_requests set status='consolidated', transfer_id=tr where id=rq;
 select count(*) into n from transfer_line_items where transfer_id=tr;
 perform pg_temp.chk(6,'D cron guard: request cancelled, its line item backed out',(select status from transfer_requests where id=rq)='cancelled' and n=0,n::text);
 perform pg_temp.chk(7,'D no EMPTY transfer is left behind on the Transfers page',not exists(select 1 from transfers t where t.id=tr and not exists(select 1 from transfer_line_items l where l.transfer_id=t.id)),'empty transfer still exists');
 -- E: old pre-112 request (held 0) cancelled by journey cancel releases nothing; other holds intact
 insert into sleep_journeys(id,store_id,customer_id,current_state,journey_number,created_at) values (j4,sa,c1,'Sold','SJ9',now()) on conflict do nothing;
 insert into transfer_requests(origin_location_id,destination_location_id,variant_id,quantity,held_quantity,source_type,source_reference_id,status,created_at) values (wh,sa,p4,1,0,'journey_mismatch',j4,'approved','2026-10-01');
 update sleep_journeys set cancelled_at=now() where id=j4;
 select committed_quantity into ho from inventory_positions where variant_id=p4 and location_id=wh;
 perform pg_temp.chk(8,'E old request cancelled with journey, other orders hold (2) intact',ho=2,'committed='||ho);
exception when others then perform pg_temp.chk(99,'harness error',false,sqlerrm);
end $$;
select n,name,ok,left(detail,80) d from res order by n;
rollback;
