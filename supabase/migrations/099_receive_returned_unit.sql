-- ============================================================================
-- EB-4a: Receive the returned mattress into quarantine
--
-- Spec: docs/exchange-builder-spec.md sections 9, 10, 11.1, 12.
-- A returned unit lands as a 'Returned' position at the location's
-- WAREHOUSE_QUARANTINE stores row (a child of the receiving location).
-- Inspection/outcomes/pre-owned are EB-4b — this migration only creates the
-- inspection shell (AWAITING_INSPECTION) so EB-4b has a row to drive.
-- ============================================================================

-- ============================================================================
-- 1. returned_unit_inspections (spec 11.1). Tenant scoped, RLS read via the
--    visibility helpers, NO direct client writes — every write goes through
--    security-definer RPCs below (and EB-4b's inspection RPCs later).
-- ============================================================================

create table if not exists public.returned_unit_inspections (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  action_id uuid not null references public.sleep_trial_actions (id) on delete cascade,
  journey_id uuid not null references public.sleep_journeys (id) on delete cascade,
  trial_item_id uuid references public.sleep_trial_items (id) on delete set null,
  variant_id uuid references public.products (id) on delete set null,
  location_id uuid not null references public.stores (id) on delete restrict,
  sublocation_id text,
  status text not null default 'AWAITING_INSPECTION' check (status in (
    'AWAITING_INSPECTION', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED')),
  outcome text check (outcome in (
    'PREOWNED_SELLABLE', 'DAMAGED_WRITEOFF', 'DONATE', 'DISPOSE')),
  template_snapshot jsonb,
  started_by uuid references public.employees (id) on delete set null,
  started_at timestamptz,
  completed_by uuid references public.employees (id) on delete set null,
  completed_at timestamptz,
  outcome_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.returned_unit_inspections is
  'EB-4: one row per received returned unit. EB-4a creates the AWAITING_INSPECTION '
  'shell at receive time; EB-4b drives IN_PROGRESS -> COMPLETED via inspection RPCs.';

create index if not exists idx_returned_unit_inspections_action
  on public.returned_unit_inspections (action_id);
create index if not exists idx_returned_unit_inspections_journey
  on public.returned_unit_inspections (journey_id);
create index if not exists idx_returned_unit_inspections_status
  on public.returned_unit_inspections (status) where status = 'AWAITING_INSPECTION';

alter table public.returned_unit_inspections enable row level security;

-- Read only: anyone who can see the journey can see its inspection rows.
drop policy if exists "Returned inspections readable" on public.returned_unit_inspections;
create policy "Returned inspections readable"
  on public.returned_unit_inspections for select
  to authenticated
  using (public.is_journey_visible(journey_id));

-- Deliberately NO insert/update/delete policies: direct client writes fail.

-- ============================================================================
-- 2. create_quarantine_area(location_id)
--    One-click provisioning of the WAREHOUSE_QUARANTINE child row for a
--    location (store or warehouse). Owner/admin only, idempotent.
--    RLS on stores blocks client inserts of that type (023), so this must be
--    security definer.
-- ============================================================================

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

-- ============================================================================
-- 3. Helper: resolve the quarantine area (child WAREHOUSE_QUARANTINE row) for
--    a receiving location. Returns the quarantine stores row id or null.
--    Accepts a quarantine row itself.
-- ============================================================================

create or replace function public.quarantine_area_for(p_location_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select s.id from public.stores s
      where s.id = p_location_id and s.location_type = 'WAREHOUSE_QUARANTINE'),
    (select s.id from public.stores s
      where s.parent_location_id = p_location_id
        and s.location_type = 'WAREHOUSE_QUARANTINE')
  );
$$;

revoke execute on function public.quarantine_area_for(uuid) from authenticated, anon;

-- ============================================================================
-- 4. Helper: is the caller a warehouse-based employee (home store is a
--    WAREHOUSE row)? Mirrors the 043 transfer-approval rule inline here so
--    the receive gate reads in one place.
-- ============================================================================

create or replace function public.is_warehouse_based_employee()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.employees e
    join public.stores s on s.id = e.home_store_id
    where e.auth_user_id = auth.uid()
      and e.is_active
      and s.location_type = 'WAREHOUSE'
  );
$$;

revoke execute on function public.is_warehouse_based_employee() from authenticated, anon;

-- ============================================================================
-- 5. receive_returned_unit(action_id, location_id, received_on)
--    Marks the original mattress received into the location's quarantine
--    area as Returned stock. Idempotent per action.
-- ============================================================================

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
  v_company := v_journey.company_id;

  if not public.is_store_visible(p_location_id) then
    raise exception 'That location is not part of your company.';
  end if;

  v_quarantine_id := public.quarantine_area_for(p_location_id);
  if v_quarantine_id is null then
    raise exception 'That location has no quarantine area. An owner or admin can create one in Settings (Locations).';
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

-- ============================================================================
-- 6. void_returned_receipt(action_id, reason)
--    Reverses a receipt recorded in error, only while the inspection is still
--    AWAITING_INSPECTION. Owner/admin or sleep_trial.complete_exchange.
-- ============================================================================

create or replace function public.void_returned_receipt(
  p_action_id uuid,
  p_reason text
)
returns uuid  -- the cancelled inspection id
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
  v_inspection public.returned_unit_inspections%rowtype;
begin
  if coalesce(public.current_employee_role()::text, '') not in ('owner', 'admin')
     and not public.has_permission('sleep_trial.complete_exchange') then
    raise exception 'You do not have permission to void a received return.';
  end if;

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'A reason is required to void a received return.';
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
  if v_action.original_received_on is null then
    raise exception 'The original mattress has not been marked received on this exchange.';
  end if;

  select * into v_inspection
  from public.returned_unit_inspections
  where action_id = p_action_id
    and status <> 'CANCELLED'
  order by created_at desc
  limit 1
  for update;

  if not found then
    raise exception 'No open inspection found for this receipt.';
  end if;
  if v_inspection.status <> 'AWAITING_INSPECTION' then
    raise exception 'This return is already being inspected, so the receipt can no longer be voided.';
  end if;

  select * into v_journey
  from public.sleep_journeys where id = v_action.journey_id;
  v_company := v_journey.company_id;

  select e.id, e.name into v_employee, v_employee_name
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Your employee record was not found or is inactive.';
  end if;

  -- Reverse the stock movement exactly (-1 at the same position).
  perform pg_advisory_xact_lock(
    hashtextextended(v_inspection.variant_id::text || ':' || v_inspection.location_id::text || ':Returned', 7137));

  update public.inventory_positions
  set on_hand_quantity = on_hand_quantity - 1,
      updated_at = now()
  where variant_id = v_inspection.variant_id
    and location_id = v_inspection.location_id
    and sublocation_id is not distinct from v_inspection.sublocation_id
    and disposition = 'Returned'
    and on_hand_quantity >= 1;

  if not found then
    raise exception 'The Returned position no longer has the received unit, so this receipt cannot be voided. Reconcile inventory first.';
  end if;

  insert into public.stock_ledger_entries (
    variant_id, location_id, disposition, quantity_delta,
    reason, reference_type, actor_id, correlation_id
  ) values (
    v_inspection.variant_id, v_inspection.location_id, 'Returned', -1,
    'return_receipt_voided', 'sleep_trial_action', v_employee::text, p_action_id
  );

  update public.sleep_trial_actions
  set original_received_on = null,
      original_location_id = null
  where id = p_action_id;

  update public.returned_unit_inspections
  set status = 'CANCELLED',
      outcome_note = 'Receipt voided: ' || btrim(p_reason),
      updated_at = now()
  where id = v_inspection.id;

  perform public.log_audit_event(
    p_company_id := v_company,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := p_action_id,
    p_event_type := 'RETURNED_RECEIPT_VOIDED',
    p_after := jsonb_build_object(
      'inspection_id', v_inspection.id,
      'reason', btrim(p_reason)),
    p_journey_id := v_action.journey_id,
    p_actor_employee_id := v_employee);

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain,
    source_record_id, is_internal
  ) values (
    v_action.journey_id, v_journey.customer_id,
    'internal_note', 'internal', 'internal', 'return_exchange',
    'Receipt of the original mattress was voided by '
      || coalesce(v_employee_name, 'an employee') || ': ' || btrim(p_reason),
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
      'Receipt of the original mattress was voided by '
        || coalesce(v_employee_name, 'an employee') || ': ' || btrim(p_reason),
      v_employee, 'sleep_trial_action', p_action_id, true
    );
  end if;

  return v_inspection.id;
end;
$$;

grant execute on function public.void_returned_receipt(uuid, text) to authenticated;
