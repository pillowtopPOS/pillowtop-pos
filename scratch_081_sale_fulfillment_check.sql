-- Read-only inspection for migration 081_sale_fulfillment_deduction.
-- Safe to run before and after applying the migration. Returns rows only;
-- writes nothing.
--
-- Statement 1: the 18 delivered test journeys — every requirement row with
-- its status, and the Prime position (on_hand / committed) it holds stock
-- against. Before 081 these show status 'ready'/'pending' with committed >
-- 0; after a delivery consume they show 'fulfilled'/'superseded' and the
-- position quantities already reduced.
with target_journeys(id) as (
  values
    ('ea0e644e-5baf-42b2-b6fa-faeaec3c813b'::uuid),
    ('b7981111-1c50-4416-82d8-2112d2a3b96a'::uuid),
    ('8f4ef10b-0a8d-439a-be77-37e0e19553b1'::uuid),
    ('1d2783df-3a87-4631-8480-986eedad7ac3'::uuid),
    ('165278b1-4a49-4e74-9dcd-008acaac1311'::uuid),
    ('762c7340-28d8-4757-bd4c-3dba47431022'::uuid),
    ('a11ee4dc-8dbf-45b1-bee8-badd0dd9ae1b'::uuid),
    ('0b74c7f6-827e-4e51-837e-9327aa15b501'::uuid),
    ('5b1ce485-e472-4b8d-aa3f-69de73363d57'::uuid),
    ('53c92553-004d-4933-9379-3928294bd9a2'::uuid),
    ('4f3a42f1-727f-452c-b3bb-2913a000267e'::uuid),
    ('d4e10dd2-90c0-47ef-aa88-c1465c8bc0f8'::uuid),
    ('7bc0741d-437a-4212-b079-0a4d7e5484d2'::uuid),
    ('2d16a017-9b67-408c-8367-f32091ecb3e3'::uuid),
    ('0ea4660e-1531-4a5a-9745-91918f1c0dec'::uuid),
    ('a3ec90b9-0128-4b61-ac5d-9bdbfc31e04b'::uuid),
    ('b578f388-e7e3-4186-95d2-7021a1255da3'::uuid),
    ('3bd36da3-0d94-4744-9d3a-434dfcbaf919'::uuid)
)
select
  sj.id as journey_id,
  c.first_name || ' ' || c.last_name as customer,
  sj.current_state,
  sj.delivered_at,
  jir.id as requirement_id,
  jir.status as requirement_status,
  jir.variant_id,
  jir.location_id,
  jir.quantity_required,
  jir.quantity_reserved,
  ip.on_hand_quantity,
  ip.committed_quantity
from public.sleep_journeys sj
join target_journeys t on t.id = sj.id
join public.customers c on c.id = sj.customer_id
left join public.journey_inventory_requirements jir
  on jir.journey_id = sj.id
left join public.inventory_positions ip
  on ip.variant_id = jir.variant_id
  and ip.location_id = jir.location_id
  and ip.disposition = 'Prime'
  and ip.sublocation_id is null
order by c.last_name, c.first_name, jir.variant_id, jir.location_id;

-- Statement 2: every delivered journey that still has a 'pending'
-- requirement — rows the new delivered_at guard leaves inert but which
-- should be cleaned up (superseded) in the one-off script. Includes any
-- delivered journey, not just the 18 above.
select
  sj.id as journey_id,
  c.first_name || ' ' || c.last_name as customer,
  sj.current_state,
  sj.delivered_at,
  count(*) as pending_requirements
from public.sleep_journeys sj
join public.customers c on c.id = sj.customer_id
join public.journey_inventory_requirements jir
  on jir.journey_id = sj.id
  and jir.status = 'pending'
where sj.delivered_at is not null
group by sj.id, c.first_name, c.last_name, sj.current_state, sj.delivered_at
order by sj.delivered_at;
