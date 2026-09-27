-- PillowTop POS: company-wide restock generation mode (automatic vs manual)
--
-- 'automatic' preserves the existing threshold_auto cron behavior for all
-- current companies. Switching to 'manual' stops the cron from auto-creating
-- restock requests for that company's stores; restock needs instead surface on
-- the Transfers page for a manager to review and request deliberately.

-- 1. Enum + column

do $$
begin
  if not exists (select 1 from pg_type where typname = 'restock_generation_mode') then
    create type public.restock_generation_mode as enum ('automatic', 'manual');
  end if;
end $$;

grant usage on type public.restock_generation_mode to authenticated;

alter table public.companies
  add column if not exists restock_generation_mode public.restock_generation_mode
  not null default 'automatic';

-- 2. Gate the threshold-check loop on the destination store's company mode.
--    Stores whose company is in 'manual' mode are skipped entirely; the manual
--    Restock tab is the only path to a restock request for those companies.
--    Consolidation (the second loop) is unchanged and still runs for everyone.

create or replace function public.run_transfer_cron_for_date(p_run_date date)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_target_date date := p_run_date + interval '1 day';
  v_target_dow integer := extract(dow from v_target_date);
  v_store record;
  v_par record;
  v_ats integer;
  v_need integer;
  v_origin record;
  v_route record;
  v_new_transfer_id uuid;
  v_total integer;
  v_existing_request_id uuid;
  v_existing_transfer_id uuid;
begin
  -- Threshold check: for every active store with an assigned warehouse whose
  -- company is in 'automatic' restock mode, compare Prime ATS per product to
  -- that store's par-level reorder_point.
  for v_store in
    select s.id, s.company_id, s.assigned_warehouse_id
    from public.stores s
    join public.companies c on c.id = s.company_id
    where s.is_active = true
      and s.assigned_warehouse_id is not null
      and s.assigned_warehouse_id <> s.id
      and c.restock_generation_mode = 'automatic'
  loop
    for v_par in
      select pl.id as par_level_id, pl.variant_id, pl.reorder_point, pl.target_quantity
      from public.par_levels pl
      where pl.store_id = v_store.id
    loop
      select coalesce(ip.on_hand_quantity, 0) - coalesce(ip.committed_quantity, 0)
      into v_ats
      from public.inventory_positions ip
      where ip.variant_id = v_par.variant_id
        and ip.location_id = v_store.id
        and ip.disposition = 'Prime'
        and ip.sublocation_id is null;

      if v_ats is null then v_ats := 0; end if;

      if v_ats <= v_par.reorder_point then
        v_need := v_par.target_quantity - v_ats;
        if v_need > 0 then
          -- Do not create a duplicate unconsolidated threshold_auto request for
          -- this exact product + origin + destination.
          select id into v_existing_request_id
          from public.transfer_requests
          where origin_location_id = v_store.assigned_warehouse_id
            and destination_location_id = v_store.id
            and variant_id = v_par.variant_id
            and source_type = 'threshold_auto'
            and status not in ('consolidated', 'cancelled', 'rejected')
          limit 1;

          if v_existing_request_id is null then
            insert into public.transfer_requests (
              origin_location_id,
              destination_location_id,
              variant_id,
              quantity,
              source_type,
              source_reference_id,
              status
            ) values (
              v_store.assigned_warehouse_id,
              v_store.id,
              v_par.variant_id,
              v_need,
              'threshold_auto',
              v_par.par_level_id,
              'approved'
            );
          end if;
        end if;
      end if;
    end loop;
  end loop;

  -- Consolidation: for every destination whose transfer_schedule_day is tomorrow,
  -- and every origin with approved requests bound for that destination, create one
  -- consolidated transfer per exact origin->destination route.
  for v_route in
    select distinct
      r.origin_location_id,
      r.destination_location_id
    from public.transfer_requests r
    join public.stores d on d.id = r.destination_location_id
    where r.status = 'approved'
      and d.transfer_schedule_day = v_target_dow
      and d.is_active = true
  loop
    select id into v_existing_transfer_id
    from public.transfers
    where origin_location_id = v_route.origin_location_id
      and destination_location_id = v_route.destination_location_id
      and scheduled_date = v_target_date
    limit 1;

    if v_existing_transfer_id is not null then
      continue;
    end if;

    insert into public.transfers (
      origin_location_id,
      destination_location_id,
      status,
      scheduled_date
    ) values (
      v_route.origin_location_id,
      v_route.destination_location_id,
      'pending',
      v_target_date
    ) returning id into v_new_transfer_id;

    -- Aggregate per-variant quantities for this route
    insert into public.transfer_line_items (
      transfer_id,
      variant_id,
      quantity_requested
    )
    select
      v_new_transfer_id,
      r.variant_id,
      sum(r.quantity)
    from public.transfer_requests r
    where r.status = 'approved'
      and r.origin_location_id = v_route.origin_location_id
      and r.destination_location_id = v_route.destination_location_id
    group by r.variant_id;

    -- Mark the contributing requests as consolidated
    update public.transfer_requests
      set status = 'consolidated',
          transfer_id = v_new_transfer_id
    where status = 'approved'
      and origin_location_id = v_route.origin_location_id
      and destination_location_id = v_route.destination_location_id;
  end loop;
end;
$$;

-- This function is intended to be called only from /api/cron via a service-role
-- connection. It is not exposed to client-side authenticated users.
revoke execute on function public.run_transfer_cron_for_date(date) from authenticated;
revoke execute on function public.run_transfer_cron_for_date(date) from public;
grant execute on function public.run_transfer_cron_for_date(date) to service_role;
