-- ============================================================================
-- EB-4a amendment: quarantine only under a warehouse
--
-- Migration 099 stays as the history of what was installed. This migration
-- supersedes two of its functions:
--   * create_quarantine_area now refuses non-WAREHOUSE locations.
--   * receive_returned_unit now requires the receiving location to be a
--     WAREHOUSE (or its quarantine row); a STORE raises a plain-English
--     message telling the user to pick the warehouse.
-- Every other rule, guard and message from 099 is unchanged.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- create_quarantine_area: warehouse parents only
-- ----------------------------------------------------------------------------

create or replace function public.create_quarantine_area(p_location_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_loc public.stores%rowtype;
  v_existing uuid;
  v_quarantine_id uuid;
begin
  if coalesce(public.current_employee_role()::text, '') not in ('owner', 'admin') then
    raise exception 'Only an owner or admin can create a quarantine area.';
  end if;

  select * into v_loc from public.stores where id = p_location_id;
  if not found then
    raise exception 'That location does not exist.';
  end if;
  if not public.is_store_visible(p_location_id) then
    raise exception 'That location is not part of your company.';
  end if;
  if not v_loc.is_active then
    raise exception 'That location is inactive. Activate it before adding a quarantine area.';
  end if;
  if v_loc.location_type = 'WAREHOUSE_QUARANTINE' then
    raise exception 'That location is already a quarantine area.';
  end if;
  if v_loc.location_type <> 'WAREHOUSE' then
    raise exception 'Quarantine areas can only be created for a warehouse.';
  end if;

  -- Idempotent: an existing quarantine child is returned, never duplicated.
  select s.id into v_existing
  from public.stores s
  where s.parent_location_id = p_location_id
    and s.location_type = 'WAREHOUSE_QUARANTINE';
  if found then
    return v_existing;
  end if;

  insert into public.stores (
    company_id, name, location_type, parent_location_id, is_active
  ) values (
    v_loc.company_id, v_loc.name || ' — Quarantine', 'WAREHOUSE_QUARANTINE',
    p_location_id, true
  ) returning id into v_quarantine_id;

  return v_quarantine_id;
end;
$$;

grant execute on function public.create_quarantine_area(uuid) to authenticated;

-- ----------------------------------------------------------------------------
-- receive_returned_unit: warehouse receiving only
-- ----------------------------------------------------------------------------

create or replace function public.receive_returned_unit(
  p_action_id uuid,
  p_location_id uuid,
  p_received_on date
)
returns uuid  -- returned_unit_inspections.id
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_journey public.sleep_journeys%rowtype;
  v_company uuid;
  v_employee uuid;
  v_employee_name text;
  v_quarantine_id uuid;
  v_quarantine_name text;
  v_variant uuid;
  v_inspection_id uuid;
  v_committed_on date;
  v_location_type text;
begin
  -- Caller: anyone who could start an exchange, plus warehouse-based staff.
  -- Receiving is a recorded fact, not a business decision.
  if not public.has_permission('sleep_trial.start_exchange')
     and not public.is_warehouse_based_employee() then
    raise exception 'You do not have permission to mark an original mattress received.';
  end if;

  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id
  for update;

  if not found then
    raise exception 'That exchange was not found.';
  end if;
  if not public.is_journey_visible(v_action.journey_id) then
    raise exception 'That exchange is not part of your company.';
  end if;

  -- Idempotent: already received -> return the existing inspection, no +1.
  if v_action.original_received_on is not null then
    select id into v_inspection_id
    from public.returned_unit_inspections
    where action_id = p_action_id
      and status <> 'CANCELLED'
    order by created_at desc
    limit 1;
    return v_inspection_id;
  end if;

  if v_action.status <> 'COMMITTED' then
    raise exception 'This exchange is %, not committed, so nothing can be marked received.', lower(v_action.status);
  end if;

  select * into v_journey
  from public.sleep_journeys where id = v_action.journey_id;
  v_company := v_action.company_id;

  if not public.is_store_visible(p_location_id) then
    raise exception 'That location is not part of your company.';
  end if;

  -- Returned mattresses are received at the warehouse, never a store.
  select location_type into v_location_type
  from public.stores where id = p_location_id;
  if v_location_type = 'STORE' then
    raise exception 'Returned mattresses are received at the warehouse. Pick the warehouse.';
  end if;

  v_quarantine_id := public.quarantine_area_for(p_location_id);
  if v_quarantine_id is null then
    raise exception 'That location has no quarantine area. An owner or admin can create one for the warehouse.';
  end if;
  select name into v_quarantine_name from public.stores where id = v_quarantine_id;

  -- Date guards.
  v_committed_on := coalesce(v_action.committed_at::date, v_action.created_at::date);
  if p_received_on > current_date then
    raise exception 'The received date cannot be in the future.';
  end if;
  if p_received_on < v_committed_on then
    raise exception 'The received date cannot be before this exchange was committed (%).', v_committed_on;
  end if;

  -- The unit: the original trial item's product.
  select product_id into v_variant
  from public.sleep_trial_items where id = v_action.trial_item_id;
  if v_variant is null then
    raise exception 'The original item on this exchange has no product to receive.';
  end if;

  select e.id, e.name into v_employee, v_employee_name
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Your employee record was not found or is inactive.';
  end if;

  -- Stock: +1 Returned at the quarantine area. Lock order matches the rest of
  -- the codebase (variant:location:disposition).
  perform pg_advisory_xact_lock(
    hashtextextended(v_variant::text || ':' || v_quarantine_id::text || ':Returned', 7137));

  insert into public.inventory_positions (
    variant_id, location_id, sublocation_id, disposition,
    on_hand_quantity, committed_quantity
  ) values (
    v_variant, v_quarantine_id, null, 'Returned', 1, 0
  )
  on conflict (variant_id, location_id, sublocation_id, disposition)
  do update set
    on_hand_quantity = inventory_positions.on_hand_quantity + 1,
    updated_at = now();

  insert into public.stock_ledger_entries (
    variant_id, location_id, disposition, quantity_delta,
    reason, reference_type, actor_id, correlation_id
  ) values (
    v_variant, v_quarantine_id, 'Returned', 1,
    'return_received', 'sleep_trial_action', v_employee::text, p_action_id
  );

  -- Action stamp (drives the milestone + the cancel block + Complete).
  update public.sleep_trial_actions
  set original_received_on = p_received_on,
      original_location_id = p_location_id
  where id = p_action_id;

  -- Inspection shell for EB-4b.
  insert into public.returned_unit_inspections (
    company_id, action_id, journey_id, trial_item_id, variant_id,
    location_id, sublocation_id, status
  ) values (
    v_company, p_action_id, v_action.journey_id, v_action.trial_item_id,
    v_variant, v_quarantine_id, null, 'AWAITING_INSPECTION'
  ) returning id into v_inspection_id;

  perform public.log_audit_event(
    p_company_id := v_company,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := p_action_id,
    p_event_type := 'RETURNED_UNIT_RECEIVED',
    p_after := jsonb_build_object(
      'received_on', p_received_on,
      'received_at_location_id', p_location_id,
      'quarantine_location_id', v_quarantine_id,
      'variant_id', v_variant,
      'inspection_id', v_inspection_id),
    p_journey_id := v_action.journey_id,
    p_actor_employee_id := v_employee);

  -- Activity lines on both journeys.
  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain,
    source_record_id, is_internal
  ) values (
    v_action.journey_id, v_journey.customer_id,
    'internal_note', 'internal', 'internal', 'return_exchange',
    'Original mattress received at ' || coalesce(v_quarantine_name, 'quarantine')
      || ' by ' || coalesce(v_employee_name, 'an employee') || '.',
    v_employee, 'sleep_trial_action', p_action_id, true
  );
  if v_action.child_journey_id is not null then
    insert into public.journey_interactions (
      journey_id, customer_id, interaction_type, channel, direction,
      topic, summary, created_by_employee_id, source_domain,
      source_record_id, is_internal
    ) values (
      v_action.child_journey_id, v_journey.customer_id,
      'internal_note', 'internal', 'internal', 'return_exchange',
      'Original mattress received at ' || coalesce(v_quarantine_name, 'quarantine')
        || ' by ' || coalesce(v_employee_name, 'an employee') || '.',
      v_employee, 'sleep_trial_action', p_action_id, true
    );
  end if;

  return v_inspection_id;
end;
$$;

grant execute on function public.receive_returned_unit(uuid, uuid, date) to authenticated;
