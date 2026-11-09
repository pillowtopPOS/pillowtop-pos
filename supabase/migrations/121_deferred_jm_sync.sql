-- PillowTop POS m121 (v3): defer ONLY the request-sync trigger; keep the
-- unit observer immediate and take it off the sync path.
--
-- Root cause (unchanged): trg_jm_requirement_sync (114) is a per-row
-- AFTER trigger on journey_inventory_requirements. It fires the instant
-- a requirement row is inserted or quantity_required/location_id/status
-- changes — in the MIDDLE of evaluate_journey_inventory, before the
-- reserve loop runs. sync_requirement_request then sees stale
-- quantity_reserved (0 on insert, old value on a qty increase), computes
-- a phantom uncovered shortfall and creates a journey_mismatch request +
-- warehouse hold; a later re-fire cancels it, leaving a cancelled row
-- and a "Transfer requested" timeline line (SJ-MS00135 x3, SJ-MS00132).
--
-- trg_jir_units_observer (109) reaches the same sync through
-- reconcile_requirement_units -> sync_requirement_request, but it ALSO
-- does the unit assignment work. Deferring it (v2) fixed the phantom
-- but moved STOCK->RESERVED assignment to commit, which regressed
-- receive_purchase_order_line: that function runs evaluate, then
-- assign_received_units_to_orders, then reads units.assigned_requirement_id
-- to build its result — all before commit — so deferred reconcile could
-- not have run yet and the returned assignments/labels could miss units.
--
-- v3 design (harness-verified):
--   * trg_jir_units_observer stays an IMMEDIATE row trigger — unit
--     assignment timing is byte-for-byte unchanged.
--   * reconcile_requirement_units gains p_sync boolean default true.
--     observe_requirement_units (the trigger path) passes false, so the
--     observer still assigns/releases units immediately but never
--     creates/cancels transfer requests mid-flight. Every other caller
--     (unassign_unit, observe_journey_units, the 109 backfill, direct
--     RPCs) keeps the default and still syncs immediately.
--   * trg_jm_requirement_sync becomes a DEFERRABLE CONSTRAINT TRIGGER
--     (initially deferred): at COMMIT each queued row fires
--     jm_requirement_sync once, when quantity_reserved, unit
--     assignments and journey state are all settled. A covered order
--     computes shortfall = 0 and no request is ever created; a genuinely
--     uncovered order still gets exactly one request with correct
--     quantity and hold, in the same transaction.
--
-- The reconcile body below is the 117_transfer_receive_units.sql body
-- verbatim except: the signature gains p_sync, and the
-- sync_requirement_request call is wrapped in `if p_sync then`.
-- observe_requirement_units is the 109 body verbatim except the call
-- passes false as the second argument.
--
-- Notes:
--  * jm_journey_state_sync and trg_sj_units_observer stay immediate —
--    they key off the sleep_journeys row (already updated when they
--    fire) and cover Quoted/cancel transitions.
--  * p_sync is a plain parameter, not a GUC: it cannot leak past an
--    exception the way a set_config could.
--  * Nothing issues SET CONSTRAINTS ALL IMMEDIATE.

-- The signature changes, so the old 1-arg function must be dropped first
-- (CREATE OR REPLACE cannot alter a parameter list). No trigger or view
-- depends on it; it is SECURITY DEFINER and already revoked from
-- client roles.
drop function if exists public.reconcile_requirement_units(uuid);

create or replace function public.reconcile_requirement_units(p_requirement_id uuid, p_sync boolean default true)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_req public.journey_inventory_requirements%rowtype;
  v_journey public.sleep_journeys%rowtype;
  v_company uuid;
  v_mode text;
  v_desired integer;
  v_cross integer;
  v_assigned uuid[];
  v_local uuid[];
  v_count integer;
  v_unit uuid;
  v_shortfall integer;
  i integer;
begin
  select * into v_req
  from public.journey_inventory_requirements
  where id = p_requirement_id;
  if not found then
    return;
  end if;

  -- Requirement-level request sync runs even for untracked products
  -- (order-time sourcing is product-agnostic); the unit work below is not.
  if p_sync then
    perform public.sync_requirement_request(p_requirement_id);
  end if;

  if not public.is_unit_tracked(v_req.variant_id) then
    return;
  end if;

  select * into v_journey
  from public.sleep_journeys where id = v_req.journey_id;
  select s.company_id, c.unit_assignment_mode
    into v_company, v_mode
  from public.stores s
  join public.companies c on c.id = s.company_id
  where s.id = v_journey.store_id;

  if v_mode <> 'AUTOMATIC' then
    return;
  end if;

  select count(*) into v_cross
  from public.units
  where assigned_requirement_id = v_req.id
    and location_id is distinct from v_req.location_id
    and status in ('RESERVED', 'IN_TRANSIT');

  if v_req.status in ('cancelled', 'superseded')
     or v_journey.cancelled_at is not null
     or v_journey.current_state = 'Quoted' then
    v_desired := 0;
  elsif v_req.status = 'fulfilled' then
    for v_unit in
      select id from public.units
      where assigned_requirement_id = v_req.id
        and status in ('RESERVED', 'STAGED')
    loop
      perform public.move_unit(v_unit, 'DELIVERED', null,
        jsonb_build_object('journey_id', v_req.journey_id));
    end loop;
    return;
  else
    v_desired := least(v_req.quantity_required,
                       v_req.quantity_reserved + v_cross);
  end if;

  select array_agg(id order by unit_number)
    into v_assigned
  from public.units
  where assigned_requirement_id = v_req.id;
  v_count := coalesce(array_length(v_assigned, 1), 0);

  if v_desired = 0 then
    for i in reverse v_count..1 loop
      -- A unit riding a transfer (IN_TRANSIT) is physically on the truck:
      -- never flip it to STOCK at the origin. Receive handles it on arrival
      -- (a dead order's unit arrives as ordinary STOCK).
      if (select status from public.units where id = v_assigned[i]) <> 'IN_TRANSIT' then
        perform public.move_unit(v_assigned[i], 'STOCK', null, '{}'::jsonb);
      end if;
    end loop;
    v_count := 0;
    if v_req.status in ('cancelled', 'superseded')
       or v_journey.cancelled_at is not null
       or v_journey.current_state = 'Quoted' then
      perform public.cancel_journey_mismatch_requests(
        v_req.journey_id, v_req.variant_id, v_req.location_id);
    end if;
  else
    select coalesce(array_agg(id order by unit_number), '{}')
      into v_local
    from public.units
    where assigned_requirement_id = v_req.id
      and location_id = v_req.location_id;

    while v_count > v_desired loop
      if coalesce(array_length(v_local, 1), 0) = 0 then
        exit;
      end if;
      v_unit := v_local[array_length(v_local, 1)];
      v_local := v_local[1:array_length(v_local, 1) - 1];
      perform public.move_unit(v_unit, 'STOCK', null, '{}'::jsonb);
      v_count := v_count - 1;
    end loop;
  end if;

  if v_count < v_desired then
    for v_unit in
      select id from public.units
      where product_id = v_req.variant_id
        and location_id = v_req.location_id
        and disposition = 'Prime'
        and status = 'STOCK'
        and assigned_requirement_id is null
      order by unit_number
      limit v_desired - v_count
      for update skip locked
    loop
      perform public.move_unit(v_unit, 'RESERVED', null,
        jsonb_build_object('requirement_id', v_req.id));
      v_count := v_count + 1;
    end loop;

    v_shortfall := v_desired - v_count;
    if v_shortfall > 0 and not exists (
      select 1 from public.audit_events ae
      where ae.entity_type = 'journey_inventory_requirement'
        and ae.entity_id = v_req.id
        and ae.event_type = 'UNIT_ASSIGNMENT_SHORTFALL'
        and (ae.after->>'shortfall')::int = v_shortfall
        and (ae.after->>'required')::int = v_desired
      order by ae.occurred_at desc
      limit 1
    ) then
      insert into public.audit_events (
        company_id, actor_type, entity_type, entity_id, journey_id,
        event_type, after
      ) values (
        v_company, 'SYSTEM', 'journey_inventory_requirement', v_req.id,
        v_req.journey_id, 'UNIT_ASSIGNMENT_SHORTFALL',
        jsonb_build_object('required', v_desired, 'assigned', v_count,
          'shortfall', v_shortfall, 'variant_id', v_req.variant_id,
          'location_id', v_req.location_id)
      );
    end if;
  end if;
end;
$function$;

revoke execute on function public.reconcile_requirement_units(uuid, boolean)
  from public, anon, authenticated;

-- observe_requirement_units: 109 body verbatim; the only change is the
-- reconcile call passes p_sync => false so the observer assigns units
-- immediately but leaves request creation/cancellation to the deferred
-- trg_jm_requirement_sync at commit.
create or replace function public.observe_requirement_units()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    perform public.reconcile_requirement_units(new.id, false);
  exception when others then
    -- The audit write itself is guarded: a logging failure can never
    -- fail a sale either.
    begin
      insert into public.audit_events (
        company_id, actor_type, entity_type, entity_id, journey_id,
        event_type, after
      )
      select s.company_id, 'SYSTEM', 'journey_inventory_requirement', new.id,
        new.journey_id, 'UNIT_ASSIGNMENT_ERROR',
        jsonb_build_object('error', sqlerrm)
      from public.sleep_journeys sj
      join public.stores s on s.id = sj.store_id
      where sj.id = new.journey_id;
    exception when others then
      null;
    end;
  end;
  return new;
end;
$$;

revoke execute on function public.observe_requirement_units() from public, anon;

-- The one deferred observer: request sync only.
drop trigger if exists trg_jm_requirement_sync on public.journey_inventory_requirements;

create constraint trigger trg_jm_requirement_sync
  after insert or update of quantity_required, location_id, status
  on public.journey_inventory_requirements
  deferrable initially deferred
  for each row execute function public.jm_requirement_sync();
