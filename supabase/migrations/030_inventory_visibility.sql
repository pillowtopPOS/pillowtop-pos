-- PillowTop POS: role-aware physical inventory visibility

alter table public.companies
  add column if not exists managers_can_view_physical_inventory
  boolean not null default false;

-- The public view is owned by postgres (BYPASSRLS) and keeps ATS visible while
-- masking physical on-hand quantities for unauthorized roles.
create or replace view public.inventory_positions_public as
select
  ip.id,
  ip.variant_id,
  ip.location_id,
  ip.sublocation_id,
  ip.disposition,
  case
    when public.current_employee_role()::text in ('owner', 'admin') then ip.on_hand_quantity
    when public.current_employee_role()::text = 'manager'
      and exists (
        select 1
        from public.stores s
        join public.companies c on c.id = s.company_id
        where s.id = ip.location_id
          and c.managers_can_view_physical_inventory = true
      )
      then ip.on_hand_quantity
    else null
  end as on_hand_quantity,
  ip.on_hand_quantity - ip.committed_quantity as ats,
  ip.updated_at
from public.inventory_positions ip
where public.is_store_visible(ip.location_id);

alter view public.inventory_positions_public owner to postgres;
grant select on public.inventory_positions_public to authenticated;

-- Raw positions are no longer directly readable by authenticated clients.
-- All client reads must use inventory_positions_public.
revoke select on public.inventory_positions from authenticated;
drop policy if exists "Inventory positions viewable by authenticated users" on public.inventory_positions;

-- Keep the table protected from direct authenticated writes as established in
-- Phase 7b; adjustment writes continue through the security-definer RPC.
revoke insert, update, delete on public.inventory_positions from authenticated;
