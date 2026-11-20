-- ============================================================================
-- Migration 162 - slice 2b, batch A: refund rules, auto-complete, timezone
-- fix and cancel wording for returns.
--
-- Product rules (Zach):
--   R1. Anyone with an employee role may record a refund through a new
--       payments.record_refund key, but without payments.adjust_refund_amount
--       (admin + manager seeded, owner implicit) the amount must be exactly
--       the system-computed one. Void refund is unchanged.
--   R2. A refund linked to a RETURN refuses until the original is received;
--       linked to an EXCHANGE it refuses until the original is received AND
--       the replacement is delivered.
--   R3. Actions complete automatically inside the RPC that lands the last
--       milestone; complete_sleep_trial_action stays as a manual fallback.
--   R4. The received-date floor compares committed_at in the journey store
--       timezone, not server UTC.
--   R5. cancel_sleep_trial_action is return-aware and checks
--       sleep_trial.start_return for RETURN actions.
--   A.  Held money: refund_owed_cents on COMMITTED un-refunded actions is
--       held; unlinked refunds may not touch it.
--
--   1. receive_returned_unit: store-timezone dates + try-complete call.
--   2. cancel_sleep_trial_action: action-aware permission and wording.
--   3. payments.record_refund + payments.adjust_refund_amount keys,
--      is_valid_permission_key, seed (restores keys 161 dropped) + backfill.
--   4. record_payment_refund (hold + R1 + R2) and record_exchange_refund
--      (R1 + R2 + try-complete).
--   5. stv_action_complete_block_reason, stv_try_complete_sleep_trial_action,
--      call sites and the child-payment trigger.
--   6. One-shot backfill: complete already-satisfied COMMITTED actions.
--
-- Rollback: re-run the 100, 097, 149, 161, 091 and 088 function bodies.
-- ============================================================================

-- ============================================================================
-- 1. receive_returned_unit (100 body): dates resolve in the journey store
--    timezone, messages are action-aware, and a fully-satisfied action
--    auto-completes in the same transaction (R3, R4)
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
  v_location_type text;
  v_tz text;
  v_noun text;
begin
  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id
  for update;

  if not found then
    raise exception 'That return or exchange was not found.';
  end if;
  if not public.is_journey_visible(v_action.journey_id) then
    raise exception 'That return or exchange is not part of your company.';
  end if;

  v_noun := lower(v_action.action);

  -- Caller: warehouse staff or a manager. Receiving is the gate that
  -- unlocks the refund, so it is deliberately narrower than starting
  -- the action: inventory.inspect_returns is seeded to admin and
  -- manager (owner is implicit in has_permission).
  if not public.is_warehouse_based_employee()
     and not public.has_permission('inventory.inspect_returns') then
    raise exception 'Only warehouse staff or a manager can mark an original mattress received.';
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
    raise exception 'This % is %, not committed, so nothing can be marked received.',
      v_noun, lower(v_action.status);
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
  -- The resolved quarantine must be active under an active warehouse. This
  -- also refuses a quarantine row parented to a store when that row is
  -- passed directly as p_location_id.
  if not exists (
    select 1
    from public.stores q
    join public.stores p on p.id = q.parent_location_id
    where q.id = v_quarantine_id
      and q.is_active
      and p.is_active
      and p.location_type = 'WAREHOUSE'
  ) then
    raise exception 'Returned mattresses are received at the warehouse. Pick the warehouse.';
  end if;
  select name into v_quarantine_name from public.stores where id = v_quarantine_id;

  -- Date guards in the journey store timezone (R4). committed_at is a
  -- timestamptz; casting it straight to date uses server UTC, which after
  -- the evening UTC rollover reads as tomorrow and wrongly rejects a
  -- same-day receipt. business_today(store_id) applies the same timezone
  -- to the future check.
  select coalesce(s.timezone, c.business_timezone)
    into v_tz
  from public.stores s
  join public.companies c on c.id = s.company_id
  where s.id = v_journey.store_id;
  v_tz := coalesce(v_tz, 'UTC');
  v_committed_on := coalesce(
    (v_action.committed_at at time zone v_tz)::date,
    (v_action.created_at at time zone v_tz)::date);
  if p_received_on > public.business_today(v_journey.store_id) then
    raise exception 'The received date cannot be in the future.';
  end if;
  if p_received_on < v_committed_on then
    raise exception 'The received date cannot be before this % was committed (%).',
      v_noun, v_committed_on;
  end if;

  -- The unit: the original trial item's product.
  select product_id into v_variant
  from public.sleep_trial_items where id = v_action.trial_item_id;
  if v_variant is null then
    raise exception 'The original item on this action has no product to receive.';
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

  -- R3: receiving may be the last milestone (a return whose refund was
  -- already recorded, or one that owes nothing). Complete in the same
  -- transaction under the action lock this function already holds.
  perform public.stv_try_complete_sleep_trial_action(p_action_id, v_employee);

  return v_inspection_id;
end;
$$;

grant execute on function public.receive_returned_unit(uuid, uuid, date) to authenticated;

-- ============================================================================
-- 2. cancel_sleep_trial_action (097 body): the permission matches the
--    action (start_return for RETURN, start_exchange for EXCHANGE) and
--    every message names the right action (R5)
-- ============================================================================

create or replace function public.cancel_sleep_trial_action(
  p_action_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_journey public.sleep_journeys%rowtype;
  v_employee uuid;
  v_employee_name text;
  v_noun text;
  v_perm text;
begin
  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id
  for update;
  if not found then
    raise exception 'Sleep trial action not found';
  end if;
  if not public.is_journey_visible(v_action.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select e.id, e.name into v_employee, v_employee_name
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;

  v_noun := lower(v_action.action);
  v_perm := case when v_action.action = 'RETURN'
                 then 'sleep_trial.start_return'
                 else 'sleep_trial.start_exchange' end;
  if not public.has_permission(v_perm) then
    raise exception 'Missing permission: %', v_perm;
  end if;

  if v_action.status <> 'COMMITTED' then
    raise exception 'Only a committed % can be cancelled (status %)',
      v_noun, v_action.status;
  end if;

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'A reason is required to cancel a %', v_noun;
  end if;
  if v_action.original_received_on is not null then
    raise exception 'The original mattress was already received - this % cannot be cancelled',
      v_noun;
  end if;
  if v_action.refund_recorded_at is not null then
    raise exception 'A refund was already recorded on this % - it cannot be cancelled',
      v_noun;
  end if;
  if exists (
    select 1 from public.sleep_journeys sj
    where sj.id = v_action.child_journey_id
      and sj.delivered_at is not null) then
    raise exception 'The replacement was already delivered - this % cannot be cancelled',
      v_noun;
  end if;
  if coalesce(public.total_paid(v_action.child_journey_id), 0) > 0 then
    raise exception 'The replacement has a payment on record - resolve it before cancelling the %',
      v_noun;
  end if;

  select * into v_journey
  from public.sleep_journeys
  where id = v_action.journey_id;

  -- Let the BEFORE INSERT guard pass for this action only, then cancel
  -- the child through the standard event (state, follow-ups, written
  -- sale and inventory hooks all hang off journey_cancelled).
  perform set_config('pillowtop.exchange_cancel', v_action.id::text, true);
  if v_action.child_journey_id is not null then
    insert into public.journey_events (
      journey_id, event_type, event_data, triggered_by
    ) values (
      v_action.child_journey_id,
      'journey_cancelled',
      jsonb_build_object(
        'reason', coalesce(nullif(btrim(p_reason), ''), 'Exchange cancelled')),
      auth.uid()::text
    );
  end if;

  perform public.stv_action_reopen_item(v_action.trial_item_id);

  update public.sleep_trial_actions
  set status = 'CANCELLED',
      cancelled_by = v_employee,
      cancelled_at = now(),
      cancel_reason = nullif(btrim(p_reason), '')
  where id = v_action.id;

  perform public.log_audit_event(
    p_company_id := v_action.company_id,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action.id,
    p_event_type := v_action.action || '_CANCELLED',
    p_after := jsonb_build_object(
      'status', 'CANCELLED',
      'reason', nullif(btrim(p_reason), ''),
      'child_journey_id', v_action.child_journey_id),
    p_journey_id := v_action.journey_id,
    p_actor_employee_id := v_employee);

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain,
    source_record_id, is_internal
  ) values (
    v_action.journey_id, v_journey.customer_id,
    'internal_note', 'internal', 'internal', 'return_exchange',
    initcap(v_noun) || ' cancelled by ' || coalesce(v_employee_name, 'an employee')
      || coalesce(' - ' || nullif(btrim(p_reason), ''), ''),
    v_employee, 'sleep_trial_action', v_action.id, true
  );
  if v_action.child_journey_id is not null then
    insert into public.journey_interactions (
      journey_id, customer_id, interaction_type, channel, direction,
      topic, summary, created_by_employee_id, source_domain,
      source_record_id, is_internal
    ) values (
      v_action.child_journey_id, v_journey.customer_id,
      'internal_note', 'internal', 'internal', 'return_exchange',
      'Replacement journey cancelled with the exchange',
      v_employee, 'sleep_trial_action', v_action.id, true
    );
  end if;
end;
$$;

revoke execute on function public.cancel_sleep_trial_action(uuid, text)
  from public, anon;
grant execute on function public.cancel_sleep_trial_action(uuid, text)
  to authenticated;

-- ============================================================================
-- 3. Permission keys: payments.record_refund (all roles) and
--    payments.adjust_refund_amount (admin + manager; owner is implicit in
--    has_permission). is_valid_permission_key gets both keys and the seed
--    grants them.
--
--    Note: 161's seed dropped the 087/091-era keys (complete_exchange,
--    void_refund, inspect_returns, manage_inspection_checklist, and the
--    admin grant on reduce_below_committed). Existing companies kept them
--    through on-conflict-do-nothing, but a company created after 161 would
--    never have received them. The seed below restores the full union.
-- ============================================================================

create or replace function public.is_valid_permission_key(p_key text)
returns boolean
language sql
immutable
as $$
  select p_key in (
    'sleep_trial.manage_concerns',
    'sleep_trial.start_exchange',
    'sleep_trial.start_return',
    'sleep_trial.request_exceptions',
    'sleep_trial.approve_exceptions',
    'sleep_trial.approve_own_exceptions',
    'sleep_trial.override_protector',
    'sleep_trial.correct_dates',
    'sleep_trial.manage_policy',
    'sleep_trial.view_policy_details',
    'inventory.reduce_below_committed',
    'sleep_trial.complete_exchange',
    'inventory.inspect_returns',
    'inventory.manage_inspection_checklist',
    'sleep_trial.void_refund',
    'units.assign',
    'units.unassign',
    'units.override_set',
    'units.swap',
    'units.void',
    'units.manage_settings',
    'inventory.receive_po',
    'delivery.manage_trucks',
    'delivery.manage_calendar',
    'delivery.book_inside_cutoff',
    'delivery.log_confirmation_calls',
    'delivery.set_windows',
    'orders.mark_fulfilled',
    'orders.backdate_fulfillment',
    'delivery.finalize',
    'orders.pickup_any_location',
    'payments.record_refund',
    'payments.adjust_refund_amount'
  );
$$;

revoke execute on function public.is_valid_permission_key(text) from anon;

create or replace function public.seed_sleep_trial_permission_defaults(p_company_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.role_permission_grants (company_id, role, permission_key)
  select p_company_id, g.role, g.permission_key
  from (
    values
      -- manage_concerns: all roles
      ('owner',    'sleep_trial.manage_concerns'),
      ('admin',    'sleep_trial.manage_concerns'),
      ('manager',  'sleep_trial.manage_concerns'),
      ('sales',    'sleep_trial.manage_concerns'),
      ('employee', 'sleep_trial.manage_concerns'),
      -- start_exchange: all roles
      ('owner',    'sleep_trial.start_exchange'),
      ('admin',    'sleep_trial.start_exchange'),
      ('manager',  'sleep_trial.start_exchange'),
      ('sales',    'sleep_trial.start_exchange'),
      ('employee', 'sleep_trial.start_exchange'),
      -- start_return: all roles (161)
      ('owner',    'sleep_trial.start_return'),
      ('admin',    'sleep_trial.start_return'),
      ('manager',  'sleep_trial.start_return'),
      ('sales',    'sleep_trial.start_return'),
      ('employee', 'sleep_trial.start_return'),
      -- request_exceptions: all roles
      ('owner',    'sleep_trial.request_exceptions'),
      ('admin',    'sleep_trial.request_exceptions'),
      ('manager',  'sleep_trial.request_exceptions'),
      ('sales',    'sleep_trial.request_exceptions'),
      ('employee', 'sleep_trial.request_exceptions'),
      -- approve_exceptions: owner, admin, manager
      ('owner',    'sleep_trial.approve_exceptions'),
      ('admin',    'sleep_trial.approve_exceptions'),
      ('manager',  'sleep_trial.approve_exceptions'),
      -- approve_own_exceptions: owner, admin
      ('owner',    'sleep_trial.approve_own_exceptions'),
      ('admin',    'sleep_trial.approve_own_exceptions'),
      -- override_protector: owner, admin
      ('owner',    'sleep_trial.override_protector'),
      ('admin',    'sleep_trial.override_protector'),
      -- correct_dates: owner, admin, manager
      ('owner',    'sleep_trial.correct_dates'),
      ('admin',    'sleep_trial.correct_dates'),
      ('manager',  'sleep_trial.correct_dates'),
      -- manage_policy: owner, admin
      ('owner',    'sleep_trial.manage_policy'),
      ('admin',    'sleep_trial.manage_policy'),
      -- view_policy_details: all roles
      ('owner',    'sleep_trial.view_policy_details'),
      ('admin',    'sleep_trial.view_policy_details'),
      ('manager',  'sleep_trial.view_policy_details'),
      ('sales',    'sleep_trial.view_policy_details'),
      ('employee', 'sleep_trial.view_policy_details'),
      -- reduce_below_committed (084 owner/manager, 085 admin):
      -- owner, admin, manager
      ('owner',    'inventory.reduce_below_committed'),
      ('admin',    'inventory.reduce_below_committed'),
      ('manager',  'inventory.reduce_below_committed'),
      -- complete_exchange (087): owner, admin
      ('owner',    'sleep_trial.complete_exchange'),
      ('admin',    'sleep_trial.complete_exchange'),
      -- inspect_returns (087): owner, admin, manager
      ('owner',    'inventory.inspect_returns'),
      ('admin',    'inventory.inspect_returns'),
      ('manager',  'inventory.inspect_returns'),
      -- manage_inspection_checklist (087): owner, admin
      ('owner',    'inventory.manage_inspection_checklist'),
      ('admin',    'inventory.manage_inspection_checklist'),
      -- void_refund (091): owner, admin
      ('owner',    'sleep_trial.void_refund'),
      ('admin',    'sleep_trial.void_refund'),
      -- record_refund (162): all roles (R1)
      ('owner',    'payments.record_refund'),
      ('admin',    'payments.record_refund'),
      ('manager',  'payments.record_refund'),
      ('sales',    'payments.record_refund'),
      ('employee', 'payments.record_refund'),
      -- adjust_refund_amount (162): admin, manager
      ('admin',    'payments.adjust_refund_amount'),
      ('manager',  'payments.adjust_refund_amount')
  ) as g(role, permission_key)
  on conflict (company_id, role, permission_key) do nothing;
end;
$$;

revoke execute on function public.seed_sleep_trial_permission_defaults(uuid)
  from public, anon, authenticated;

-- Backfill every existing company (new ones get it through the
-- companies-insert trigger installed in 066).
select public.seed_sleep_trial_permission_defaults(id) from public.companies;

-- ============================================================================
-- 4a. record_payment_refund (161 body): permission key replaces the role
--     list (R1), linked refunds are gated on milestones (R2) and unlinked
--     refunds may not touch money held for open actions (requirement A)
-- ============================================================================

create or replace function public.record_payment_refund(
  p_payment_id uuid,
  p_amount numeric,
  p_method text,
  p_reason text,
  p_reference text default null,
  p_action_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payment public.journey_events%rowtype;
  v_payment_amount numeric;
  v_already_refunded numeric;
  v_emp_id uuid;
  v_new_id uuid;
  v_sale_id uuid;
  v_sale_tenant uuid;
  v_prev_committed numeric;
  v_adjust numeric;
  v_action public.sleep_trial_actions%rowtype;
  v_event_data jsonb;
  v_can_adjust boolean;
  v_price numeric;
  v_net_cents integer;
  v_effective_cents integer;
  v_credit_cents integer;
  v_held_cents integer;
  v_held_return_cents integer;
  v_allowed_cents integer;
  v_amount_cents integer;
begin
  -- Lock the payment row first: the refund cap must be checked against a
  -- stable row, and this serializes two refunds against the same payment.
  select * into v_payment
  from public.journey_events
  where id = p_payment_id
  for update;

  if not found then
    raise exception 'Payment event not found';
  end if;

  -- Same-company caller check, before any other work on the payment:
  -- has_permission() only proves what the caller may do inside their own
  -- company, so the caller's active employee must belong to the journey's
  -- company (employee home store company = journey store company).
  if not exists (
    select 1 from public.employees e
    join public.stores es on es.id = e.home_store_id
    join public.sleep_journeys sj on sj.id = v_payment.journey_id
    join public.stores js on js.id = sj.store_id
    where e.auth_user_id = auth.uid() and e.is_active
      and es.company_id = js.company_id
  ) then
    raise exception 'Not authorized for this journey';
  end if;

  if v_payment.event_type not in ('deposit_received', 'payment_completed')
     or v_payment.outcome <> 'SUCCEEDED' then
    raise exception 'Refunds can only be recorded against a successful payment';
  end if;
  if p_amount is null or p_amount <= 0 then
    raise exception 'Refund amount must be greater than zero';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'A reason is required to record a refund';
  end if;

  -- R1: any employee with payments.record_refund may record a refund;
  -- payments.adjust_refund_amount decides whether the amount can differ
  -- from the system-computed one.
  if not public.has_permission('payments.record_refund') then
    raise exception 'You do not have permission to record a refund. Ask a manager.';
  end if;
  v_can_adjust := public.has_permission('payments.adjust_refund_amount');
  select e.id into v_emp_id
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_emp_id is null then
    raise exception 'Employee record not found';
  end if;

  v_amount_cents := round(p_amount * 100)::int;

  -- Linked refund: the action is locked and validated here so the event
  -- and the action stamp land in one transaction. The link is checked
  -- server-side: journey, action kind, committed and not yet refunded.
  if p_action_id is not null then
    select * into v_action
    from public.sleep_trial_actions
    where id = p_action_id
    for update;
    if not found then
      raise exception 'Sleep trial action not found';
    end if;
    if v_action.journey_id <> v_payment.journey_id then
      raise exception 'That action does not belong to this order';
    end if;
    if v_action.action not in ('RETURN', 'EXCHANGE') then
      raise exception 'Refunds can only be linked to a return or exchange action';
    end if;
    if v_action.status <> 'COMMITTED' then
      raise exception 'Only a committed action can take a refund (status %)',
        v_action.status;
    end if;
    if v_action.refund_recorded_at is not null then
      raise exception 'A refund was already recorded on this action';
    end if;

    -- R2: the refund is the last money step, so the physical steps must
    -- have landed first. A return needs the original back; an exchange
    -- needs the original back and the replacement delivered.
    if v_action.original_received_on is null then
      raise exception 'The original mattress has not been received yet. Mark it received first.';
    end if;
    if v_action.action = 'EXCHANGE'
       and v_action.replacement_delivered_on is null then
      raise exception 'The replacement has not been delivered yet. Deliver it before recording the refund.';
    end if;

    if not v_can_adjust
       and v_amount_cents is distinct from v_action.refund_owed_cents then
      raise exception 'This refund must be exactly $%, the amount owed on the %.',
        to_char(coalesce(v_action.refund_owed_cents, 0) / 100.0, 'FM999999990.00'),
        lower(v_action.action);
    end if;
  else
    -- Requirement A: refund_owed_cents on committed, un-refunded actions
    -- is held money. Credit due only drops for RETURN actions (the order
    -- price is what falls), so the non-adjust amount subtracts only the
    -- RETURN share; the adjust-caller cap still protects all held money,
    -- exchange refunds included.
    select coalesce(sum(a.refund_owed_cents), 0),
           coalesce(sum(a.refund_owed_cents)
                      filter (where a.action = 'RETURN'), 0)
      into v_held_cents, v_held_return_cents
    from public.sleep_trial_actions a
    where a.journey_id = v_payment.journey_id
      and a.status = 'COMMITTED'
      and a.refund_recorded_at is null
      and coalesce(a.refund_owed_cents, 0) > 0;

    select coalesce(sj.price, 0) into v_price
    from public.sleep_journeys sj
    where sj.id = v_payment.journey_id;

    v_net_cents := round(public.total_paid(v_payment.journey_id) * 100)::int;
    v_effective_cents := greatest(
      round(v_price * 100)::int - coalesce((
        select sum(a.refund_owed_cents)
        from public.sleep_trial_actions a
        where a.journey_id = v_payment.journey_id
          and a.action = 'RETURN'
          and a.status in ('COMMITTED', 'COMPLETED')
      ), 0),
      0);
    v_credit_cents := greatest(v_net_cents - v_effective_cents, 0);
    v_allowed_cents := v_credit_cents - v_held_return_cents;

    if not v_can_adjust then
      if v_allowed_cents <= 0 then
        if v_held_return_cents > 0 then
          raise exception 'No unlinked refund is due on this order; the credit is held for an open return. Record it from the return card.';
        else
          raise exception 'No refund is due on this order.';
        end if;
      end if;
      if v_amount_cents is distinct from v_allowed_cents then
        raise exception 'This refund must be exactly $%, the credit due minus money held for open returns.',
          to_char(v_allowed_cents / 100.0, 'FM999999990.00');
      end if;
    elsif v_amount_cents > v_net_cents - v_held_cents then
      raise exception 'This refund would touch money held for a committed return or exchange. Record that refund from the return card.';
    end if;
  end if;

  -- Cap: refunds recorded against one payment cannot exceed what was paid.
  v_payment_amount := coalesce((v_payment.event_data->>'amount')::numeric, 0);
  select coalesce(sum((je.event_data->>'amount')::numeric), 0)
  into v_already_refunded
  from public.journey_events je
  where je.journey_id = v_payment.journey_id
    and je.event_type = 'payment_refunded'
    and je.outcome = 'SUCCEEDED'
    and je.event_data->>'refunds_payment_id' = p_payment_id::text;

  if v_already_refunded + p_amount > v_payment_amount then
    raise exception 'This refund is more than what was paid on that payment.';
  end if;

  -- The event carries the same keys as before; 'action_id' joins it only
  -- when the refund settles a return so void_payment_refund can find and
  -- un-stamp the action.
  v_event_data := jsonb_build_object(
    'amount', p_amount,
    'method', p_method,
    'refunds_payment_id', p_payment_id,
    'reason', btrim(p_reason),
    'reference', nullif(btrim(coalesce(p_reference, '')), '')
  );
  if p_action_id is not null then
    v_event_data := v_event_data
      || jsonb_build_object('action_id', p_action_id);
  end if;

  insert into public.journey_events (
    journey_id, event_type, event_data, triggered_by, outcome
  ) values (
    v_payment.journey_id,
    'payment_refunded',
    v_event_data,
    auth.uid()::text,
    'SUCCEEDED'
  )
  returning id into v_new_id;

  -- Stamp the action so the refund milestone is satisfied by this same
  -- call, then try to complete: the refund is often the last step (R3).
  if p_action_id is not null then
    update public.sleep_trial_actions
    set refund_method = p_method,
        refund_amount_cents = round(p_amount * 100)::int,
        refund_reference = nullif(btrim(coalesce(p_reference, '')), ''),
        refund_recorded_by = v_emp_id,
        refund_recorded_at = now()
    where id = v_action.id;

    perform public.log_audit_event(
      p_company_id := v_action.company_id,
      p_entity_type := 'sleep_trial_action',
      p_entity_id := v_action.id,
      p_event_type := v_action.action || '_REFUND_RECORDED',
      p_after := jsonb_build_object(
        'refund_method', p_method,
        'refund_amount_cents', round(p_amount * 100)::int,
        'refund_owed_cents', v_action.refund_owed_cents,
        'payment_refund_event_id', v_new_id,
        'refund_reference', nullif(btrim(coalesce(p_reference, '')), '')),
      p_journey_id := v_action.journey_id,
      p_actor_employee_id := v_emp_id);

    perform public.stv_try_complete_sleep_trial_action(p_action_id, v_emp_id);
  end if;

  -- Written-sale ledger: the refund reduces the committed order amount by
  -- the refunded dollars, against the same written sale (so it lands on
  -- the same salesperson attribution). correlation_id links the
  -- adjustment back to the refund event; void_payment_refund writes the
  -- matching reversal.
  select ws.id, ws.tenant_id,
         ws.qualifying_order_amount + coalesce(adj.total, 0)
    into v_sale_id, v_sale_tenant, v_prev_committed
  from public.written_sales ws
  left join (
    select written_sale_id, sum(adjustment_amount) as total
    from public.written_sale_adjustments
    group by written_sale_id
  ) adj on adj.written_sale_id = ws.id
  where ws.order_id = v_payment.journey_id;

  -- Clamp to what is still committed: after a cancellation the committed
  -- amount is already 0 and a later refund must not push it negative.
  if v_sale_id is not null then
    v_adjust := least(p_amount, greatest(v_prev_committed, 0));
    if v_adjust > 0 then
      insert into public.written_sale_adjustments (
        written_sale_id, tenant_id, order_id, adjustment_amount,
        previous_qualifying_committed_amount,
        new_qualifying_committed_amount,
        adjustment_type, adjustment_reason, actor_id, correlation_id
      ) values (
        v_sale_id, v_sale_tenant, v_payment.journey_id, -v_adjust,
        v_prev_committed, v_prev_committed - v_adjust,
        'refund', btrim(p_reason), auth.uid()::text, v_new_id
      );
    end if;
  end if;

  -- Net paid dropped: re-run the balance and inventory evaluations. The
  -- balance re-evaluation still flips a now-underpaid journey to Quoted
  -- and logs the balance-due event, but does NOT release reservations:
  -- refunds never release stock (cancel or an explicit supersede does).
  perform public.reevaluate_journey_balance(v_payment.journey_id, false);
  perform public.evaluate_journey_inventory(v_payment.journey_id);

  return v_new_id;
end;
$$;

revoke execute on function public.record_payment_refund(uuid, numeric, text, text, text, uuid)
  from public, anon;
grant execute on function public.record_payment_refund(uuid, numeric, text, text, text, uuid)
  to authenticated;

-- ============================================================================
-- 4b. record_exchange_refund (091 body): payments.record_refund replaces
--     the complete_exchange gate (R1), a differing amount now needs
--     payments.adjust_refund_amount, the physical milestones must have
--     landed first (R2), and a satisfied action auto-completes (R3)
-- ============================================================================

create or replace function public.record_exchange_refund(
  p_action_id uuid,
  p_method text,
  p_amount_cents integer,
  p_reference text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_journey public.sleep_journeys%rowtype;
  v_employee uuid;
  v_employee_name text;
begin
  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id
  for update;
  if not found then
    raise exception 'Exchange action not found';
  end if;
  if not public.is_journey_visible(v_action.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;
  if v_action.action <> 'EXCHANGE' then
    raise exception 'This function records exchange refunds. Record a return refund from the payment refund dialog.';
  end if;

  if not public.has_permission('payments.record_refund') then
    raise exception 'You do not have permission to record a refund. Ask a manager.';
  end if;
  select e.id, e.name into v_employee, v_employee_name
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;

  if v_action.status <> 'COMMITTED' then
    raise exception 'Only a committed exchange can record a refund (status %)',
      v_action.status;
  end if;
  if coalesce(v_action.refund_owed_cents, 0) <= 0 then
    raise exception 'No refund is owed on this exchange';
  end if;
  if v_action.refund_recorded_at is not null then
    raise exception 'A refund was already recorded on this exchange';
  end if;

  -- R2: the money step comes last, after both physical steps.
  if v_action.original_received_on is null then
    raise exception 'The original mattress has not been received yet. Mark it received first.';
  end if;
  if v_action.replacement_delivered_on is null then
    raise exception 'The replacement has not been delivered yet. Deliver it before recording the refund.';
  end if;

  if p_method not in ('card','cash','check','store_credit','none') then
    raise exception 'refund method must be card, cash, check, store_credit or none';
  end if;
  if p_amount_cents is null or p_amount_cents < 0 then
    raise exception 'refund amount must be a non-negative integer cents value';
  end if;
  -- R1: a differing settled amount needs payments.adjust_refund_amount
  -- and, as before, a reference documenting it.
  if p_amount_cents is distinct from v_action.refund_owed_cents then
    if not public.has_permission('payments.adjust_refund_amount') then
      raise exception 'This refund must be exactly $%, the amount owed on the exchange.',
        to_char(v_action.refund_owed_cents / 100.0, 'FM999999990.00');
    end if;
    if nullif(btrim(coalesce(p_reference, '')), '') is null then
      raise exception 'The amount differs from the owed refund - a reference is required to document a different settled amount';
    end if;
  end if;

  update public.sleep_trial_actions
  set refund_method = p_method,
      refund_amount_cents = p_amount_cents,
      refund_reference = nullif(btrim(p_reference), ''),
      refund_recorded_by = v_employee,
      refund_recorded_at = now()
  where id = v_action.id;

  perform public.log_audit_event(
    p_company_id := v_action.company_id,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action.id,
    p_event_type := 'EXCHANGE_REFUND_RECORDED',
    p_after := jsonb_build_object(
      'refund_method', p_method,
      'refund_amount_cents', p_amount_cents,
      'refund_owed_cents', v_action.refund_owed_cents,
      'refund_reference', nullif(btrim(p_reference), '')),
    p_journey_id := v_action.journey_id,
    p_actor_employee_id := v_employee);

  -- R3: the refund is the last milestone for an exchange that owes money
  -- back to the customer; both physical steps are already verified above.
  perform public.stv_try_complete_sleep_trial_action(p_action_id, v_employee);

  select * into v_journey
  from public.sleep_journeys
  where id = v_action.journey_id;

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain,
    source_record_id, is_internal
  ) values (
    v_action.journey_id, v_journey.customer_id,
    'internal_note', 'internal', 'internal', 'return_exchange',
    'Exchange refund recorded by ' || coalesce(v_employee_name, 'an employee')
      || ' - ' || p_method
      || ' $' || to_char(p_amount_cents / 100.0, 'FM999999990.00')
      || coalesce(' (ref ' || nullif(btrim(p_reference), '') || ')', ''),
    v_employee, 'sleep_trial_action', v_action.id, true
  );
  if v_action.child_journey_id is not null then
    insert into public.journey_interactions (
      journey_id, customer_id, interaction_type, channel, direction,
      topic, summary, created_by_employee_id, source_domain,
      source_record_id, is_internal
    ) values (
      v_action.child_journey_id, v_journey.customer_id,
      'internal_note', 'internal', 'internal', 'return_exchange',
      'Exchange refund recorded - see the original journey for details',
      v_employee, 'sleep_trial_action', v_action.id, true
    );
  end if;
end;
$$;

revoke execute on function public.record_exchange_refund(uuid, text, integer, text)
  from public, anon;
grant execute on function public.record_exchange_refund(uuid, text, integer, text)
  to authenticated;

-- ============================================================================
-- 4c. void_payment_refund (161 body): linked refunds can now stamp
--     EXCHANGE actions too, so the un-stamp branch and the completed
--     refusal are action-aware instead of saying 'return' and logging
--     RETURN_REFUND_VOIDED for every action type. Everything else,
--     including the owner/admin/manager caller check, is unchanged.
-- ============================================================================

create or replace function public.void_payment_refund(
  p_refund_event_id uuid,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_refund public.journey_events%rowtype;
  v_log_id uuid;
  v_reversal_amount numeric;
  v_sale_id uuid;
  v_sale_tenant uuid;
  v_prev_committed numeric;
  v_action public.sleep_trial_actions%rowtype;
  v_emp_id uuid;
begin
  select * into v_refund
  from public.journey_events
  where id = p_refund_event_id
  for update;

  if not found or v_refund.event_type <> 'payment_refunded' then
    raise exception 'Refund event not found';
  end if;
  if v_refund.outcome = 'VOIDED' then
    raise exception 'This refund was already voided';
  end if;
  if v_refund.outcome <> 'SUCCEEDED' then
    raise exception 'Only a recorded refund can be voided';
  end if;
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'A reason is required to void a refund';
  end if;

  -- Same caller check as before: void stays owner/admin/manager.
  if not exists (
    select 1 from public.employees e
    join public.stores es on es.id = e.home_store_id
    join public.sleep_journeys sj on sj.id = v_refund.journey_id
    join public.stores js on js.id = sj.store_id
    where e.auth_user_id = auth.uid() and es.company_id = js.company_id
      and e.role::text in ('owner', 'admin', 'manager')
  ) then
    raise exception 'Only owner, admin, or manager may void a refund';
  end if;
  select id into v_emp_id from public.employees where auth_user_id = auth.uid();

  -- A refund recorded through record_payment_refund with p_action_id
  -- carries 'action_id' in its event_data and stamped the action's
  -- refund fields. Voiding it must un-stamp the action so the refund
  -- milestone is unmet again. A completed action is refused: its refund
  -- is part of the close-out.
  if v_refund.event_data ? 'action_id' then
    select * into v_action
    from public.sleep_trial_actions
    where id = (v_refund.event_data ->> 'action_id')::uuid
    for update;
    if found then
      if v_action.status = 'COMPLETED' then
        raise exception 'This refund closed a completed % and cannot be voided here',
          lower(v_action.action);
      end if;
      if v_action.status = 'COMMITTED' then
        update public.sleep_trial_actions
        set refund_method = null,
            refund_amount_cents = null,
            refund_reference = null,
            refund_recorded_by = null,
            refund_recorded_at = null
        where id = v_action.id;

        perform public.log_audit_event(
          p_company_id := v_action.company_id,
          p_entity_type := 'sleep_trial_action',
          p_entity_id := v_action.id,
          p_event_type := v_action.action || '_REFUND_VOIDED',
          p_after := jsonb_build_object(
            'voided_refund_event_id', p_refund_event_id,
            'reason', btrim(p_reason)),
          p_journey_id := v_action.journey_id,
          p_actor_employee_id := v_emp_id);
      end if;
    end if;
  end if;

  update public.journey_events
  set outcome = 'VOIDED',
      reconciled_at = now()
  where id = p_refund_event_id;

  -- Same audit shape reconcile_payment_event writes.
  insert into public.payment_reconciliation_events (
    payment_id, previous_outcome, new_outcome, previous_event_type,
    new_event_type, reconciliation_source, actor_id, notes
  ) values (
    p_refund_event_id, v_refund.outcome, 'VOIDED', v_refund.event_type,
    v_refund.event_type, 'manual', auth.uid()::text, btrim(p_reason)
  ) returning id into v_log_id;

  -- Reversal adjustment: put back exactly what this refund's 'refund'
  -- adjustment took out (clamped refunds reverse the clamped amount, not
  -- the raw refund amount; a refund that wrote no adjustment reverses
  -- nothing). correlation_id points at the refund event being reversed.
  select -coalesce(sum(a.adjustment_amount), 0)
    into v_reversal_amount
  from public.written_sale_adjustments a
  join public.written_sales ws on ws.id = a.written_sale_id
  where ws.order_id = v_refund.journey_id
    and a.adjustment_type = 'refund'
    and a.correlation_id = p_refund_event_id;

  select ws.id, ws.tenant_id,
         ws.qualifying_order_amount + coalesce(adj.total, 0)
    into v_sale_id, v_sale_tenant, v_prev_committed
  from public.written_sales ws
  left join (
    select written_sale_id, sum(adjustment_amount) as total
    from public.written_sale_adjustments
    group by written_sale_id
  ) adj on adj.written_sale_id = ws.id
  where ws.order_id = v_refund.journey_id;

  -- A cancelled journey's committed amount is already zeroed by the
  -- 'cancellation' adjustment: voiding a refund must not add money back.
  -- The void itself, the audit row, and the re-evaluations still happen.
  if v_sale_id is not null and v_reversal_amount > 0
     and not exists (
       select 1 from public.sleep_journeys sj
       where sj.id = v_refund.journey_id
         and sj.cancelled_at is not null
     ) then
    insert into public.written_sale_adjustments (
      written_sale_id, tenant_id, order_id, adjustment_amount,
      previous_qualifying_committed_amount,
      new_qualifying_committed_amount,
      adjustment_type, adjustment_reason, actor_id, correlation_id
    ) values (
      v_sale_id, v_sale_tenant, v_refund.journey_id, v_reversal_amount,
      v_prev_committed, v_prev_committed + v_reversal_amount,
      'refund_reversal', btrim(p_reason), auth.uid()::text, p_refund_event_id
    );
  end if;

  -- Net paid went back up: re-run the balance and inventory evaluations
  -- without releasing reservations (same rule as record_payment_refund).
  perform public.reevaluate_journey_balance(v_refund.journey_id, false);
  perform public.evaluate_journey_inventory(v_refund.journey_id);

  return p_refund_event_id;
end;
$$;

revoke execute on function public.void_payment_refund(uuid, text) from public, anon;
grant execute on function public.void_payment_refund(uuid, text) to authenticated;

-- ============================================================================
-- 5. Auto-complete (R3)
--
--    stv_action_complete_block_reason returns the first unmet milestone as
--    the same message complete_sleep_trial_action raises, or null when the
--    action is ready. stv_try_complete_sleep_trial_action takes the action
--    lock itself, re-checks under it, and performs the same completion the
--    manual RPC does, without the permission gate. Two last-steps landing
--    together serialize on the action row lock; the loser sees COMPLETED.
--
--    Lock verification for every RPC that lands a milestone:
--      receive_returned_unit       select ... for update (this file, s.1)
--      record_payment_refund       select ... for update (this file, s.4a)
--      record_exchange_refund      select ... for update (this file, s.4b)
--      cancel_sleep_trial_action   select ... for update (this file, s.2)
--      void_returned_receipt       select ... for update (099)
--      void_payment_refund         select ... for update (161)
--      stv_exchange_delivered_sync update ... returning (row lock, below)
--      stv_child_payment_sync      delegates to try-complete, which locks
-- ============================================================================

create or replace function public.stv_action_complete_block_reason(
  p_action public.sleep_trial_actions
)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_child public.sleep_journeys%rowtype;
begin
  -- Same milestone order as complete_sleep_trial_action. A return has no
  -- replacement journey, so the delivery and child-balance checks only
  -- apply to exchanges (child_journey_id is null for returns anyway).
  if p_action.action = 'EXCHANGE'
     and p_action.replacement_delivered_on is null then
    return 'The replacement has not been delivered yet';
  end if;
  if p_action.original_received_on is null then
    return 'The original mattress has not been received yet';
  end if;
  select * into v_child
  from public.sleep_journeys
  where id = p_action.child_journey_id;
  if v_child.id is not null
     and coalesce(v_child.price, 0) > 0
     and public.total_paid(v_child.id) < v_child.price then
    return 'The replacement still has an unpaid balance';
  end if;
  if coalesce(p_action.refund_owed_cents, 0) > 0
     and p_action.refund_recorded_at is null then
    return 'The owed refund has not been recorded yet';
  end if;
  return null;
end;
$$;

revoke execute on function public.stv_action_complete_block_reason(public.sleep_trial_actions)
  from public, anon, authenticated;

create or replace function public.stv_try_complete_sleep_trial_action(
  p_action_id uuid,
  p_actor uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_journey public.sleep_journeys%rowtype;
  v_employee_name text;
  v_block text;
begin
  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id
  for update;

  if not found or v_action.status <> 'COMMITTED' then
    return false;
  end if;

  v_block := public.stv_action_complete_block_reason(v_action);
  if v_block is not null then
    return false;
  end if;

  select * into v_journey
  from public.sleep_journeys
  where id = v_action.journey_id;
  select e.name into v_employee_name
  from public.employees e
  where e.id = p_actor;

  perform public.stv_action_close_item(v_action.trial_item_id, v_action.action);

  update public.sleep_trial_actions
  set status = 'COMPLETED',
      completed_by = p_actor,
      completed_at = now()
  where id = v_action.id;

  perform public.log_audit_event(
    p_company_id := v_action.company_id,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action.id,
    p_event_type := v_action.action || '_COMPLETED',
    p_after := jsonb_build_object(
      'status', 'COMPLETED',
      'child_journey_id', v_action.child_journey_id,
      'auto_completed', true),
    p_journey_id := v_action.journey_id,
    p_actor_employee_id := p_actor);

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain,
    source_record_id, is_internal
  ) values (
    v_action.journey_id, v_journey.customer_id,
    'internal_note', 'internal', 'internal', 'return_exchange',
    case when v_action.action = 'RETURN'
         then 'Return completed by '
              || coalesce(v_employee_name, 'the system')
              || ', original closed as RETURNED'
         else 'Exchange completed by '
              || coalesce(v_employee_name, 'the system')
              || ', original closed as EXCHANGED'
    end,
    p_actor, 'sleep_trial_action', v_action.id, true
  );
  if v_action.child_journey_id is not null then
    insert into public.journey_interactions (
      journey_id, customer_id, interaction_type, channel, direction,
      topic, summary, created_by_employee_id, source_domain,
      source_record_id, is_internal
    ) values (
      v_action.child_journey_id, v_journey.customer_id,
      'internal_note', 'internal', 'internal', 'return_exchange',
      'Exchange completed - this replacement fulfilled it',
      p_actor, 'sleep_trial_action', v_action.id, true
    );
  end if;

  -- Same close-out as complete_sleep_trial_action: when no live trial
  -- item remains, write trial_completed so derive_journey_state takes
  -- the journey to Completed. Best-effort, never blocks the completion.
  begin
    if not exists (
      select 1
      from public.sleep_trial_items sti
      where sti.journey_id = v_action.journey_id
        and sti.status in
          ('ACTIVE','EXCHANGE_IN_PROGRESS','RETURN_IN_PROGRESS')
    ) and exists (
      select 1
      from public.sleep_journeys sj
      where sj.id = v_action.journey_id
        and sj.current_state = 'Sleep Trial'
        and sj.cancelled_at is null
    ) then
      insert into public.journey_events (
        journey_id, event_type, event_data, triggered_by
      ) values (
        v_action.journey_id, 'trial_completed', '{}'::jsonb, 'system'
      );

      insert into public.journey_interactions (
        journey_id, customer_id, interaction_type, channel, direction,
        topic, summary, created_by_employee_id, source_domain,
        source_record_id, is_internal
      ) values (
        v_action.journey_id, v_journey.customer_id,
        'internal_note', 'internal', 'internal', 'return_exchange',
        case when v_action.action = 'RETURN'
             then 'Sleep trial completed: the return was completed'
             else 'Sleep trial completed: the exchange was completed'
        end,
        p_actor, 'sleep_trial_action', v_action.id, true
      );
    end if;
  exception
    when others then
      raise warning
        'stv_try_complete_sleep_trial_action: trial_completed close-out skipped: %',
        sqlerrm;
  end;

  return true;
end;
$$;

revoke execute on function public.stv_try_complete_sleep_trial_action(uuid, uuid)
  from public, anon, authenticated;

-- Call site: replacement delivered. 088 body plus the try-complete call
-- after the delivered stamp; the action row lock is already held by the
-- update ... returning above.
create or replace function public.stv_exchange_delivered_sync()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company uuid;
  v_employee uuid;
begin
  if new.exchange_action_id is null
     or new.delivered_at is null
     or new.delivered_at is not distinct from old.delivered_at then
    return new;
  end if;

  update public.sleep_trial_actions a
  set replacement_delivered_on = new.delivered_at
  where a.id = new.exchange_action_id
    and a.replacement_delivered_on is distinct from new.delivered_at
  returning a.company_id into v_company;

  if v_company is null then
    return new;
  end if;

  select e.id into v_employee
  from public.employees e
  where e.auth_user_id = auth.uid();

  perform public.log_audit_event(
    p_company_id := v_company,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := new.exchange_action_id,
    p_event_type := 'EXCHANGE_REPLACEMENT_DELIVERED',
    p_after := jsonb_build_object(
      'replacement_delivered_on', new.delivered_at,
      'child_journey_id', new.id),
    p_journey_id := new.id,
    p_actor_employee_id := v_employee);

  -- R3: delivery may be the last milestone.
  perform public.stv_try_complete_sleep_trial_action(
    new.exchange_action_id, v_employee);

  return new;
end;
$$;

revoke execute on function public.stv_exchange_delivered_sync()
  from public, anon, authenticated;

drop trigger if exists trg_exchange_delivered_sync on public.sleep_journeys;
create trigger trg_exchange_delivered_sync
  after update of delivered_at on public.sleep_journeys
  for each row
  execute function public.stv_exchange_delivered_sync();

-- Call site: money settled on a replacement journey. Child payments land
-- as journey_events inserts (deposit_received / payment_completed), not
-- through a dedicated RPC, so an insert trigger is the hook. The lock is
-- taken inside stv_try_complete_sleep_trial_action.
create or replace function public.stv_child_payment_complete_sync()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action_id uuid;
  v_employee uuid;
begin
  if new.event_type not in ('deposit_received', 'payment_completed')
     or new.outcome is distinct from 'SUCCEEDED' then
    return new;
  end if;

  select e.id into v_employee
  from public.employees e
  where e.auth_user_id = auth.uid();

  for v_action_id in
    select a.id
    from public.sleep_trial_actions a
    where a.child_journey_id = new.journey_id
      and a.status = 'COMMITTED'
  loop
    perform public.stv_try_complete_sleep_trial_action(
      v_action_id, v_employee);
  end loop;

  return new;
end;
$$;

revoke execute on function public.stv_child_payment_complete_sync()
  from public, anon, authenticated;

drop trigger if exists trg_child_payment_complete on public.journey_events;
create trigger trg_child_payment_complete
  after insert on public.journey_events
  for each row
  execute function public.stv_child_payment_complete_sync();

-- ----------------------------------------------------------------------------
-- 5b. complete_sleep_trial_action (161 body): stays as the manual
--     fallback; the only change is the committed-status message naming
--     the actual action instead of always saying exchange.
-- ----------------------------------------------------------------------------

create or replace function public.complete_sleep_trial_action(p_action_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_journey public.sleep_journeys%rowtype;
  v_child public.sleep_journeys%rowtype;
  v_employee uuid;
  v_employee_name text;
begin
  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id
  for update;
  if not found then
    raise exception 'Sleep trial action not found';
  end if;
  if not public.is_journey_visible(v_action.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  if not public.has_permission('sleep_trial.complete_exchange') then
    raise exception 'Missing permission: sleep_trial.complete_exchange';
  end if;
  select e.id, e.name into v_employee, v_employee_name
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;

  if v_action.status <> 'COMMITTED' then
    raise exception 'Only a committed % can be completed (status %)',
      lower(v_action.action), v_action.status;
  end if;

  select * into v_journey
  from public.sleep_journeys
  where id = v_action.journey_id;
  select * into v_child
  from public.sleep_journeys
  where id = v_action.child_journey_id;

  -- Milestones in order; refuse with the first unmet one. A return has
  -- no replacement journey, so only the receive and refund milestones
  -- apply to it.
  if v_action.action = 'EXCHANGE'
     and v_action.replacement_delivered_on is null then
    raise exception 'The replacement has not been delivered yet';
  end if;
  if v_action.original_received_on is null then
    raise exception 'The original mattress has not been received yet';
  end if;
  if v_child.id is not null
     and coalesce(v_child.price, 0) > 0
     and public.total_paid(v_child.id) < v_child.price then
    raise exception 'The replacement still has an unpaid balance';
  end if;
  if coalesce(v_action.refund_owed_cents, 0) > 0
     and v_action.refund_recorded_at is null then
    raise exception 'The owed refund has not been recorded yet';
  end if;

  perform public.stv_action_close_item(v_action.trial_item_id, v_action.action);

  update public.sleep_trial_actions
  set status = 'COMPLETED',
      completed_by = v_employee,
      completed_at = now()
  where id = v_action.id;

  perform public.log_audit_event(
    p_company_id := v_action.company_id,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action.id,
    p_event_type := v_action.action || '_COMPLETED',
    p_after := jsonb_build_object(
      'status', 'COMPLETED',
      'child_journey_id', v_action.child_journey_id),
    p_journey_id := v_action.journey_id,
    p_actor_employee_id := v_employee);

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain,
    source_record_id, is_internal
  ) values (
    v_action.journey_id, v_journey.customer_id,
    'internal_note', 'internal', 'internal', 'return_exchange',
    case when v_action.action = 'RETURN'
         then 'Return completed by '
              || coalesce(v_employee_name, 'an employee')
              || ', original closed as RETURNED'
         else 'Exchange completed by '
              || coalesce(v_employee_name, 'an employee')
              || ', original closed as EXCHANGED'
    end,
    v_employee, 'sleep_trial_action', v_action.id, true
  );
  if v_action.child_journey_id is not null then
    insert into public.journey_interactions (
      journey_id, customer_id, interaction_type, channel, direction,
      topic, summary, created_by_employee_id, source_domain,
      source_record_id, is_internal
    ) values (
      v_action.child_journey_id, v_journey.customer_id,
      'internal_note', 'internal', 'internal', 'return_exchange',
      'Exchange completed - this replacement fulfilled it',
      v_employee, 'sleep_trial_action', v_action.id, true
    );
  end if;

  -- 092 close-out: the item just closed as EXCHANGED or RETURNED. When no
  -- live trial item remains on the original journey, its sleep trial is
  -- over: write the same trial_completed event the automatic timer
  -- inserts (empty event_data, triggered_by 'system'; automation.ts:44-50)
  -- and let derive_journey_state take the journey to Completed. Other
  -- live items (multi-mattress orders) leave the journey alone, as does
  -- any state where trial_completed wouldn't apply. Best-effort: this
  -- step can warn in the log but must never undo a completed action.
  begin
    if not exists (
      select 1
      from public.sleep_trial_items sti
      where sti.journey_id = v_action.journey_id
        and sti.status in
          ('ACTIVE','EXCHANGE_IN_PROGRESS','RETURN_IN_PROGRESS')
    ) and exists (
      select 1
      from public.sleep_journeys sj
      where sj.id = v_action.journey_id
        and sj.current_state = 'Sleep Trial'
        and sj.cancelled_at is null
    ) then
      insert into public.journey_events (
        journey_id, event_type, event_data, triggered_by
      ) values (
        v_action.journey_id, 'trial_completed', '{}'::jsonb, 'system'
      );

      insert into public.journey_interactions (
        journey_id, customer_id, interaction_type, channel, direction,
        topic, summary, created_by_employee_id, source_domain,
        source_record_id, is_internal
      ) values (
        v_action.journey_id, v_journey.customer_id,
        'internal_note', 'internal', 'internal', 'return_exchange',
        case when v_action.action = 'RETURN'
             then 'Sleep trial completed: the return was completed'
             else 'Sleep trial completed: the exchange was completed'
        end,
        v_employee, 'sleep_trial_action', v_action.id, true
      );
    end if;
  exception
    when others then
      raise warning
        'complete_sleep_trial_action: trial_completed close-out skipped: %',
        sqlerrm;
  end;
end;
$$;

revoke execute on function public.complete_sleep_trial_action(uuid)
  from public, anon;
grant execute on function public.complete_sleep_trial_action(uuid)
  to authenticated;

-- ============================================================================
-- 6. One-shot backfill: COMMITTED actions whose milestones were all met
--    before this migration (their last step landed while auto-complete
--    did not exist) complete now. Re-runnable: already completed rows are
--    skipped by the status check inside the helper.
-- ============================================================================

do $$
declare
  v_action_id uuid;
begin
  for v_action_id in
    select a.id
    from public.sleep_trial_actions a
    where a.status = 'COMMITTED'
  loop
    perform public.stv_try_complete_sleep_trial_action(v_action_id, null);
  end loop;
end;
$$;
