-- ============================================================================
-- INV-QTY — read-only audit: active requirements out of sync with line qty
--
-- Lists every pending/ready journey_inventory_requirements row whose
-- quantity_required differs from the sum of that journey's effective line
-- quantities (same effective-location rule as evaluate_journey_inventory:
-- pickup -> coalesce(line pickup_location_id, journey store_id);
-- delivery/other -> the store's assigned_warehouse_id, else the store).
--
-- A requirement whose (variant, location) no longer matches ANY line group
-- shows effective_qty = 0 — that is the "line deleted/changed location"
-- case, which the supersede branch already fixes on next evaluation.
--
-- READ-ONLY. No backfill, no mass re-evaluation: each mismatch corrects
-- itself the next time that journey is evaluated (migration 095 makes
-- evaluation reconcile quantities instead of skipping existing rows).
--
-- Columns: journey, customer, variant (product), what the requirement
-- currently asks (required) and holds (reserved), the effective sum it
-- SHOULD ask, its status, and the company's reservation policy.
-- ============================================================================

with effective as (
  select
    jli.journey_id,
    jli.product_id as variant_id,
    case
      when coalesce(jli.fulfillment_type_override, sj.fulfillment_type) = 'pickup'
        then coalesce(jli.pickup_location_id, sj.store_id)
      else coalesce(s.assigned_warehouse_id, sj.store_id)
    end as location_id,
    sum(jli.quantity) as effective_qty
  from public.journey_line_items jli
  join public.sleep_journeys sj on sj.id = jli.journey_id
  join public.stores s on s.id = sj.store_id
  where jli.product_id is not null
  group by 1, 2, 3
)
select
  jir.journey_id,
  c.first_name || ' ' || c.last_name       as customer_name,
  p.item_name || ' (' || p.sku || ')'      as variant,
  jir.location_id,
  jir.quantity_required,
  jir.quantity_reserved,
  coalesce(e.effective_qty, 0)             as effective_qty,
  jir.status,
  coalesce(rp.trigger_type, 'paid_in_full') as reservation_policy,
  case
    when e.effective_qty is null then 'no matching lines (will supersede)'
    when e.effective_qty > jir.quantity_required then 'under-required (will grow)'
    else 'over-required (will shrink)'
  end as mismatch_kind,
  jir.created_at
from public.journey_inventory_requirements jir
join public.sleep_journeys sj on sj.id = jir.journey_id
join public.customers c on c.id = sj.customer_id
join public.products p on p.id = jir.variant_id
left join public.stores s on s.id = sj.store_id
left join public.reservation_policies rp on rp.company_id = s.company_id
left join effective e
  on e.journey_id = jir.journey_id
  and e.variant_id is not distinct from jir.variant_id
  and e.location_id = jir.location_id
where jir.status in ('pending', 'ready')
  and jir.quantity_required <> coalesce(e.effective_qty, 0)
order by jir.created_at;
