-- 102: scope check_unit_consistency to the requested company.
-- 101 compared the requested company's units against inventory_positions of
-- EVERY company's tracked products, so one company's discrepancy report could
-- list another company's products and stock. Same signature, same behavior,
-- plus a company filter on the tracked-product list.

create or replace function public.check_unit_consistency(p_company_id uuid)
returns table (
  product_id uuid,
  location_id uuid,
  disposition public.disposition,
  units_on_hand bigint,
  mirror_on_hand integer,
  units_reserved bigint,
  mirror_committed integer
)
language sql
stable
security definer
set search_path = public
as $$
  with tracked_products as (
    select p.id
    from public.products p
    where p.company_id = p_company_id
      and public.is_unit_tracked(p.id)
  ),
  unit_counts as (
    select u.product_id, u.location_id, u.disposition,
      count(*) filter (where u.status in
        ('STOCK','RESERVED','STAGED','QUARANTINE','DAMAGED','RETURNED'))
        as on_hand_units,
      count(*) filter (where u.status = 'RESERVED') as reserved_units
    from public.units u
    where u.company_id = p_company_id
      and u.status <> 'VOID'
      and u.product_id in (select id from tracked_products)
    group by u.product_id, u.location_id, u.disposition
  ),
  mirror_counts as (
    select ip.variant_id as product_id, ip.location_id, ip.disposition,
      ip.on_hand_quantity, ip.committed_quantity
    from public.inventory_positions ip
    where ip.variant_id in (select id from tracked_products)
  )
  select
    coalesce(u.product_id, m.product_id) as product_id,
    coalesce(u.location_id, m.location_id) as location_id,
    coalesce(u.disposition, m.disposition) as disposition,
    coalesce(u.on_hand_units, 0) as units_on_hand,
    coalesce(m.on_hand_quantity, 0) as mirror_on_hand,
    coalesce(u.reserved_units, 0) as units_reserved,
    coalesce(m.committed_quantity, 0) as mirror_committed
  from unit_counts u
  full outer join mirror_counts m
    on m.product_id = u.product_id
    and m.location_id = u.location_id
    and m.disposition = u.disposition
  where coalesce(u.on_hand_units, 0) <> coalesce(m.on_hand_quantity, 0)
     or coalesce(u.reserved_units, 0) <> coalesce(m.committed_quantity, 0);
$$;

revoke execute on function public.check_unit_consistency(uuid)
  from authenticated, anon, public;

select
  position('p.company_id = p_company_id' in pg_get_functiondef('public.check_unit_consistency(uuid)'::regprocedure)) > 0 as company_filter_installed,
  not has_function_privilege('authenticated', 'public.check_unit_consistency(uuid)', 'execute') as still_locked_from_clients;
