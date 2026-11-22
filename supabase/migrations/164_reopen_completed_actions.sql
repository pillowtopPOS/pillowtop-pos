-- ============================================================================
-- Migration 164: reopen completed returns/exchanges; every refund reversible
-- ============================================================================
-- Nothing is locked after a mistake. A COMPLETED return or exchange can be
-- reopened to COMMITTED: the trial item goes back to its in-progress state,
-- the recorded refund is voided (the event stays, marked VOIDED, and the
-- refund_history entry is kept) and its amount is held again as refund
-- owed, so a corrected refund can be recorded and the existing
-- auto-complete path closes the action and the journey all over again.
-- History is never erased: voided rows stay visible.
--
-- Sections:
--   1. sleep_trial_action_reopened event: enum value + event_to_state map
--      (journey state stays event-driven; no direct current_state write).
--   2. sleep_trial.reopen_action permission key: is_valid_permission_key
--      plus the seed function and its backfill (owner implicit, admin and
--      manager seeded; every existing key kept).
--   3. stv_action_reopen_closed_item + stv_action_reopen_block_reason
--      helpers (the fail-closed quarantine check, single-sourced).
--   4. reopen_sleep_trial_action.
--   5. void_payment_refund (162 s.4c body): a refund whose action is
--      COMPLETED now reopens it instead of refusing; the COMMITTED
--      un-stamp branch keeps the voided entry in refund_history.
--   6. void_returned_receipt (099 body): + COMMITTED-only and
--      un-refunded guards; the fail-closed quarantine check it already
--      had is kept.
--   7. get_exchange_action (097 body) + can_reopen, reopen_block_reason,
--      and can_void_refund on COMPLETED actions for reopen-capable
--      callers.
--   8. void_exchange_refund (091 body): a COMPLETED exchange delegates
--      to reopen_sleep_trial_action instead of refusing, so the legacy
--      void path stops being a trap too.
--
--    Lock verification for every RPC that lands or lifts a milestone:
--      receive_returned_unit       select ... for update (162)
--      record_payment_refund       select ... for update (162)
--      record_exchange_refund      select ... for update (162)
--      cancel_sleep_trial_action   select ... for update (162)
--      reopen_sleep_trial_action   select ... for update (this file)
--      void_returned_receipt       select ... for update (this file)
--      void_payment_refund         select ... for update (this file)
--      stv_try_complete_sleep_trial_action  select ... for update (162)
-- ============================================================================

-- ============================================================================
-- 1. sleep_trial_action_reopened: a COMPLETED action going back to
--    COMMITTED puts a live trial item back on the journey, so a journey
--    that its close-out had parked at Completed must derive back to
--    Sleep Trial. The state stays event-driven: one new enum value plus
--    one WHEN in event_to_state, and derive_journey_state (unchanged)
--    applies it like every other event.
-- ============================================================================

alter type public.journey_event_type
  add value if not exists 'sleep_trial_action_reopened';

-- 129 body plus the one new WHEN. A second trial_completed after a
-- reopen maps to Completed exactly like the first: the mapping is a pure
-- event-to-state lookup, so duplicates are idempotent by construction.
create or replace function public.event_to_state(evt public.journey_event_type)
returns public.journey_state
language plpgsql
stable
as $$
begin
  return case evt
    when 'quote_created' then 'Quoted'::public.journey_state
    when 'quote_sent' then 'Quoted'::public.journey_state
    when 'deposit_received' then 'Quoted'::public.journey_state
    when 'payment_completed' then 'Quoted'::public.journey_state
    when 'inventory_required' then 'Waiting for Inventory'::public.journey_state
    when 'inventory_received' then 'Ready to Schedule'::public.journey_state
    when 'delivery_scheduled' then 'Scheduled'::public.journey_state
    when 'delivery_unscheduled' then 'Ready to Schedule'::public.journey_state
    when 'delivery_completed' then 'Sleep Trial'::public.journey_state
    when 'trial_completed' then 'Completed'::public.journey_state
    when 'sleep_trial_action_reopened' then 'Sleep Trial'::public.journey_state
    when 'journey_updated_to_sold' then 'Sold'::public.journey_state
    when 'line_items_changed_balance_due' then 'Quoted'::public.journey_state
    else null
  end;
end;
$$;

-- ============================================================================
-- 2. sleep_trial.reopen_action: owner implicit, admin + manager seeded,
--    per-employee overrides ride the existing mechanism. The seed below
--    is the full 162 union plus this key: every previously valid key is
--    kept (161 once dropped the 087/091-era keys).
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
    'sleep_trial.reopen_action',
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
      -- reopen_action (164): admin, manager (owner implicit)
      ('admin',    'sleep_trial.reopen_action'),
      ('manager',  'sleep_trial.reopen_action'),
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
-- 3a. stv_action_reopen_closed_item: the mirror of stv_action_close_item.
--     A CLOSED item whose close_reason matches the action kind goes back
--     to its in-progress state; close_reason and closed_at are cleared so
--     the evaluation helpers count it live again. Internal helper: no
--     grant, callers are the definer RPCs below.
-- ============================================================================

create or replace function public.stv_action_reopen_closed_item(
  p_item_id uuid,
  p_action text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.sleep_trial_items%rowtype;
  v_reason text;
  v_expected text;
  v_employee uuid;
begin
  if p_action not in ('EXCHANGE','RETURN') then
    raise exception 'action must be EXCHANGE or RETURN';
  end if;
  v_reason := case when p_action = 'EXCHANGE'
                   then 'EXCHANGED' else 'RETURNED' end;
  v_expected := case when p_action = 'EXCHANGE'
                     then 'EXCHANGE_IN_PROGRESS'
                     else 'RETURN_IN_PROGRESS' end;

  select * into v_item
  from public.sleep_trial_items
  where id = p_item_id
  for update;
  if not found then
    raise exception 'Trial item not found';
  end if;
  -- Only the matching closed state can reopen: an item closed some other
  -- way (TRIAL_ENDED etc.) is not this action's to bring back.
  if v_item.status <> 'CLOSED' or v_item.close_reason is distinct from v_reason then
    raise exception 'Trial item must be closed as % to reopen it (status %, close_reason %)',
      v_reason,
      v_item.status,
      v_item.close_reason;
  end if;

  update public.sleep_trial_items
  set status = v_expected,
      close_reason = null,
      closed_at = null,
      updated_at = now()
  where id = v_item.id;

  select e.id into v_employee
  from public.employees e where e.auth_user_id = auth.uid();

  perform public.log_audit_event(
    p_company_id := v_item.company_id,
    p_entity_type := 'sleep_trial_item',
    p_entity_id := v_item.id,
    p_event_type := 'SLEEP_TRIAL_ITEM_REOPENED',
    p_before := jsonb_build_object(
      'status', v_item.status, 'close_reason', v_item.close_reason),
    p_after := jsonb_build_object('status', v_expected),
    p_journey_id := v_item.journey_id,
    p_actor_employee_id := v_employee
  );
end;
$$;

revoke execute on function public.stv_action_reopen_closed_item(uuid, text)
  from public, anon, authenticated;

-- ============================================================================
-- 3b. stv_action_reopen_block_reason: the fail-closed quarantine check,
--     single-sourced so reopen_sleep_trial_action raises exactly what
--     get_exchange_action reports. A received original must still sit in
--     its quarantine position: a missing inspection row, a status past
--     AWAITING_INSPECTION or a position under 1 all refuse, naming the
--     last known location. Inventory is never created or destroyed to
--     make a reopen work. null means the reopen may proceed.
-- ============================================================================

create or replace function public.stv_action_reopen_block_reason(
  p_action public.sleep_trial_actions
)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_inspection public.returned_unit_inspections%rowtype;
  v_loc_name text;
  v_on_hand integer;
begin
  if p_action.status <> 'COMPLETED' then
    return null;
  end if;
  -- An original that was never received has no unit to account for.
  if p_action.original_received_on is null then
    return null;
  end if;

  select s.name into v_loc_name
  from public.stores s
  where s.id = p_action.original_location_id;

  select * into v_inspection
  from public.returned_unit_inspections
  where action_id = p_action.id
    and status <> 'CANCELLED'
  order by created_at desc
  limit 1;
  if not found then
    return 'The returned unit has no inspection record at '
      || coalesce(v_loc_name, 'the receiving warehouse')
      || '. Reconcile the quarantine before reopening.';
  end if;

  select s.name into v_loc_name
  from public.stores s
  where s.id = v_inspection.location_id;

  if v_inspection.status <> 'AWAITING_INSPECTION' then
    return 'The returned unit at '
      || coalesce(v_loc_name, 'the receiving warehouse')
      || ' already left quarantine (inspection '
      || lower(v_inspection.status) || '), so this '
      || lower(p_action.action) || ' cannot be reopened.';
  end if;

  select ip.on_hand_quantity into v_on_hand
  from public.inventory_positions ip
  where ip.variant_id = v_inspection.variant_id
    and ip.location_id = v_inspection.location_id
    and ip.sublocation_id is not distinct from v_inspection.sublocation_id
    and ip.disposition = 'Returned';

  if coalesce(v_on_hand, 0) < 1 then
    return 'The returned unit is no longer in quarantine at '
      || coalesce(v_loc_name, 'the receiving warehouse')
      || ', so this ' || lower(p_action.action)
      || ' cannot be reopened.';
  end if;
  return null;
end;
$$;

revoke execute on function public.stv_action_reopen_block_reason(public.sleep_trial_actions)
  from public, anon, authenticated;

-- ============================================================================
-- 4. reopen_sleep_trial_action: a COMPLETED return/exchange goes back to
--    COMMITTED so a refund mistake can be corrected. Everything the
--    completion wrote is reversed except history:
--      * the linked refund event flips to VOIDED (row kept), its
--        reconciliation row is logged and the refund_reversal adjustment
--        puts the money back on net paid, exactly like a manual void;
--      * the action's refund stamp is cleared but the voided record is
--        first appended to refund_history, so nothing is lost;
--      * the trial item reopens to its in-progress state via
--        stv_action_reopen_closed_item;
--      * a journey parked at Completed derives back to Sleep Trial
--        through the new sleep_trial_action_reopened event.
--    The quarantine hold (3b) runs BEFORE any write: a unit that left
--    quarantine refuses the whole reopen.
-- ============================================================================

create or replace function public.reopen_sleep_trial_action(
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
  v_recorded_by_name text;
  v_block text;
  v_snapshot jsonb;
  v_refund public.journey_events%rowtype;
  v_log_id uuid;
  v_reversal_amount numeric;
  v_sale_id uuid;
  v_sale_tenant uuid;
  v_prev_committed numeric;
  v_insp_id uuid;
begin
  if not public.has_permission('sleep_trial.reopen_action') then
    raise exception 'Missing permission: sleep_trial.reopen_action';
  end if;

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'A reason is required to reopen a completed action.';
  end if;

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
  -- Idempotent-safe: only a COMPLETED row can reopen, re-checked under
  -- the row lock so two callers racing the same action cannot both
  -- write. The loser sees COMMITTED and stops here.
  if v_action.status <> 'COMPLETED' then
    raise exception 'Only a completed % can be reopened (status %)',
      lower(v_action.action), v_action.status;
  end if;

  select * into v_journey
  from public.sleep_journeys
  where id = v_action.journey_id;
  if v_journey.cancelled_at is not null then
    raise exception 'This order was cancelled; its completed actions cannot be reopened.';
  end if;

  select e.id, e.name into v_employee, v_employee_name
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;

  -- Fail-closed quarantine hold, evaluated while the action row is
  -- locked: receive/complete/inspect all serialize on this lock or the
  -- inspection row lock below, so the check cannot go stale mid-write.
  select rui.id into v_insp_id
  from public.returned_unit_inspections rui
  where rui.action_id = p_action_id
    and rui.status <> 'CANCELLED'
  order by rui.created_at desc
  limit 1
  for update;

  v_block := public.stv_action_reopen_block_reason(v_action);
  if v_block is not null then
    raise exception '%', v_block;
  end if;

  -- The recorded refund is voided, not erased: the event row stays with
  -- outcome VOIDED, and the 091-shaped snapshot lands in refund_history
  -- before the stamp columns are cleared.
  if v_action.refund_recorded_at is not null then
    select e.name into v_recorded_by_name
    from public.employees e
    where e.id = v_action.refund_recorded_by;

    v_snapshot := jsonb_build_object(
      'refund_method', v_action.refund_method,
      'refund_amount_cents', v_action.refund_amount_cents,
      'refund_reference', v_action.refund_reference,
      'recorded_by', v_action.refund_recorded_by,
      'recorded_by_name', v_recorded_by_name,
      'recorded_at', v_action.refund_recorded_at,
      'voided_by', v_employee,
      'voided_by_name', v_employee_name,
      'voided_at', now(),
      'void_reason', btrim(p_reason));

    select * into v_refund
    from public.journey_events
    where journey_id = v_action.journey_id
      and event_type = 'payment_refunded'
      and outcome = 'SUCCEEDED'
      and event_data->>'action_id' = p_action_id::text
    order by created_at desc
    limit 1
    for update;

    if found then
      update public.journey_events
      set outcome = 'VOIDED',
          reconciled_at = now()
      where id = v_refund.id;

      insert into public.payment_reconciliation_events (
        payment_id, previous_outcome, new_outcome, previous_event_type,
        new_event_type, reconciliation_source, actor_id, notes
      ) values (
        v_refund.id, v_refund.outcome, 'VOIDED', v_refund.event_type,
        v_refund.event_type, 'manual', auth.uid()::text, btrim(p_reason)
      ) returning id into v_log_id;

      -- Reversal adjustment: put back exactly what this refund's
      -- 'refund' adjustment took out, same rule as void_payment_refund.
      select -coalesce(sum(a.adjustment_amount), 0)
        into v_reversal_amount
      from public.written_sale_adjustments a
      join public.written_sales ws on ws.id = a.written_sale_id
      where ws.order_id = v_refund.journey_id
        and a.adjustment_type = 'refund'
        and a.correlation_id = v_refund.id;

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

      if v_sale_id is not null and v_reversal_amount > 0
         and v_journey.cancelled_at is null then
        insert into public.written_sale_adjustments (
          written_sale_id, tenant_id, order_id, adjustment_amount,
          previous_qualifying_committed_amount,
          new_qualifying_committed_amount,
          adjustment_type, adjustment_reason, actor_id, correlation_id
        ) values (
          v_sale_id, v_sale_tenant, v_refund.journey_id, v_reversal_amount,
          v_prev_committed, v_prev_committed + v_reversal_amount,
          'refund_reversal', btrim(p_reason), auth.uid()::text,
          v_refund.id
        );
      end if;
    end if;

    update public.sleep_trial_actions
    set refund_history = refund_history || jsonb_build_array(v_snapshot),
        refund_method = null,
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
        'voided_refund_event_id', v_refund.id,
        'reason', btrim(p_reason)),
      p_journey_id := v_action.journey_id,
      p_actor_employee_id := v_employee);
  end if;

  -- Back to COMMITTED: refund_owed_cents stays, so the 162 hold rules
  -- count the money again the moment the row lands.
  update public.sleep_trial_actions
  set status = 'COMMITTED',
      completed_at = null,
      completed_by = null
  where id = v_action.id;

  perform public.stv_action_reopen_closed_item(
    v_action.trial_item_id, v_action.action);

  perform public.log_audit_event(
    p_company_id := v_action.company_id,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action.id,
    p_event_type := v_action.action || '_REOPENED',
    p_after := jsonb_build_object(
      'status', 'COMMITTED',
      'reason', btrim(p_reason),
      'voided_refund_event_id', v_refund.id),
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
         then 'Return reopened by '
              || coalesce(v_employee_name, 'an employee')
              || ': ' || btrim(p_reason)
         else 'Exchange reopened by '
              || coalesce(v_employee_name, 'an employee')
              || ': ' || btrim(p_reason)
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
      'The exchange that created this order was reopened by '
        || coalesce(v_employee_name, 'an employee')
        || ': ' || btrim(p_reason),
      v_employee, 'sleep_trial_action', v_action.id, true
    );
  end if;

  -- Event-driven state restore: the action being COMMITTED again means
  -- a live trial item exists, so a journey parked at Completed derives
  -- back to Sleep Trial through the event like every other transition.
  -- Cancelled journeys are refused above; non-Completed journeys need
  -- no event.
  if v_journey.current_state = 'Completed' then
    insert into public.journey_events (
      journey_id, event_type, event_data, triggered_by
    ) values (
      v_action.journey_id,
      'sleep_trial_action_reopened',
      jsonb_build_object(
        'action_id', v_action.id,
        'action', v_action.action,
        'reason', btrim(p_reason)),
      auth.uid()::text
    );
  end if;

  -- Net paid changed when a refund event voided: re-run the balance and
  -- inventory evaluations without releasing reservations, same rule as
  -- void_payment_refund.
  if v_refund.id is not null then
    perform public.reevaluate_journey_balance(v_action.journey_id, false);
    perform public.evaluate_journey_inventory(v_action.journey_id);
  end if;
end;
$$;

revoke execute on function public.reopen_sleep_trial_action(uuid, text)
  from public, anon;
grant execute on function public.reopen_sleep_trial_action(uuid, text)
  to authenticated;

-- ============================================================================
-- 5. void_payment_refund (162 s.4c body): a refund stamped on a
--    COMPLETED action can no longer be voided in place because voiding
--    it IS a reopen - it now delegates to reopen_sleep_trial_action,
--    which performs the void and the reopen under the same lock. The
--    COMMITTED un-stamp branch also snapshots the refund into
--    refund_history first, so the voided entry stays readable on the
--    card exactly like the 091 exchange path.
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
  v_recorded_by_name text;
  v_snapshot jsonb;
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

  -- A refund recorded through record_payment_refund with p_action_id
  -- carries 'action_id' in its event_data and stamped the action's
  -- refund fields. On a COMPLETED action the void IS the reopen, so it
  -- delegates to reopen_sleep_trial_action BEFORE the void caller check
  -- below: reopen needs sleep_trial.reopen_action, which it enforces
  -- itself (164). COMMITTED and unlinked voids keep the original gate.
  if v_refund.event_data ? 'action_id' then
    select * into v_action
    from public.sleep_trial_actions
    where id = (v_refund.event_data ->> 'action_id')::uuid
    for update;
    if found and v_action.status = 'COMPLETED' then
      perform public.reopen_sleep_trial_action(v_action.id, p_reason);
      return p_refund_event_id;
    end if;
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

  -- Voiding a linked refund un-stamps the action so the refund
  -- milestone is unmet again (COMPLETED delegated above).
  if v_action.id is not null then
    if v_action.status = 'COMMITTED' then
        select e.name into v_recorded_by_name
        from public.employees e
        where e.id = v_action.refund_recorded_by;

        -- Snapshot FIRST, same 091 shape: the voided record stays
        -- readable in refund_history after the stamp columns clear.
        v_snapshot := jsonb_build_object(
          'refund_method', v_action.refund_method,
          'refund_amount_cents', v_action.refund_amount_cents,
          'refund_reference', v_action.refund_reference,
          'recorded_by', v_action.refund_recorded_by,
          'recorded_by_name', v_recorded_by_name,
          'recorded_at', v_action.refund_recorded_at,
          'voided_by', v_emp_id,
          'voided_at', now(),
          'void_reason', btrim(p_reason));

        update public.sleep_trial_actions
        set refund_history = refund_history || jsonb_build_array(v_snapshot),
            refund_method = null,
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
-- 6. void_returned_receipt (099 body) + two guards that were missing:
--    the action must still be COMMITTED (a completed action reopens
--    through section 4 instead) and must not carry a recorded refund
--    (the refund void or the reopen clears it first). The fail-closed
--    quarantine check it already had is unchanged: no open inspection or
--    a Returned position under 1 refuses before any write.
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
  -- 164: undoing a receipt must be at least as available as receiving
  -- it, so this is the same gate receive_returned_unit uses (162):
  -- warehouse-based staff or inventory.inspect_returns (seeded to
  -- admin and manager; owner is implicit in has_permission).
  if not public.is_warehouse_based_employee()
     and not public.has_permission('inventory.inspect_returns') then
    raise exception 'Only warehouse staff or a manager can void a received return.';
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
  -- 164: receipt voids are a COMMITTED-state correction. A COMPLETED
  -- action must go through reopen_sleep_trial_action so the refund and
  -- the trial item reopen together.
  if v_action.status <> 'COMMITTED' then
    raise exception 'Only a committed action can void a receipt (status %).',
      v_action.status;
  end if;
  if v_action.refund_recorded_at is not null then
    raise exception 'A refund was already recorded - void it before voiding the receipt.';
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
  v_company := v_action.company_id;

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

-- ============================================================================
-- 7. get_exchange_action (097 body): the payload grows can_reopen and
--    reopen_block_reason, and can_void_refund now also answers true on a
--    COMPLETED action for reopen-capable callers, because voiding that
--    refund IS the reopen path.
-- ============================================================================

create or replace function public.get_exchange_action(
  p_action_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_repl_name text;
  v_creator_name text;
  v_committed_by_name text;
  v_completed_by_name text;
  v_cancelled_by_name text;
  v_refund_recorded_by_name text;
  v_child public.sleep_journeys%rowtype;
  v_child_paid numeric := 0;
  v_child_paid_at timestamptz;
  v_child_has_payment boolean := false;
  v_child_reserved boolean := false;
  v_child_overpaid int := 0;
  v_add_ons_total int := 0;
  v_can_start boolean;
  v_can_complete boolean;
  v_can_void boolean;
  v_can_reopen boolean;
  v_reopen_reason text;
  v_money_done boolean;
  v_money_at timestamptz;
  v_money_by uuid;
  v_money_by_name text;
  v_block_code text;
  v_block_msg text;
  v_blockers jsonb;
begin
  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id;
  if not found then
    raise exception 'Exchange action not found';
  end if;
  if not public.is_journey_visible(v_action.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select p.item_name into v_repl_name
  from public.products p
  where p.id = v_action.replacement_product_id;

  select e.name into v_creator_name
  from public.employees e
  where e.id = v_action.created_by;
  select e.name into v_committed_by_name
  from public.employees e
  where e.id = v_action.committed_by;
  select e.name into v_completed_by_name
  from public.employees e
  where e.id = v_action.completed_by;
  select e.name into v_cancelled_by_name
  from public.employees e
  where e.id = v_action.cancelled_by;
  select e.name into v_refund_recorded_by_name
  from public.employees e
  where e.id = v_action.refund_recorded_by;

  if v_action.child_journey_id is not null then
    select * into v_child
    from public.sleep_journeys
    where id = v_action.child_journey_id;

    v_child_paid := coalesce(public.total_paid(v_action.child_journey_id), 0);
    v_child_has_payment := v_child_paid > 0;
    select max(je.created_at) into v_child_paid_at
    from public.journey_events je
    where je.journey_id = v_action.child_journey_id
      and je.event_type in ('deposit_received','payment_completed')
      and je.outcome = 'SUCCEEDED';

    -- "Replacement reserved" = the child's own inventory requirement is
    -- fully reserved  -  the same journey_inventory_requirements.status the
    -- readiness evaluator (028) flips to 'ready'. Rows only exist once the
    -- company's reservation trigger fires (default paid_in_full), so a
    -- child whose payment hasn't been taken yet reads open: PillowTop
    -- hasn't actually reserved anything. No ready timestamp is stored, so
    -- the milestone carries no date.
    select
      exists (
        select 1
        from public.journey_inventory_requirements r
        where r.journey_id = v_action.child_journey_id
          and r.status <> 'cancelled')
      and not exists (
        select 1
        from public.journey_inventory_requirements r
        where r.journey_id = v_action.child_journey_id
          and r.status = 'pending')
    into v_child_reserved;

    -- EB-2c: how much the customer overpaid (positive only when
    -- total_paid exceeds the current price  -  e.g. an add-on was removed
    -- after payment). Dollar values -> integer cents.
    v_child_overpaid := greatest(
      0,
      round(v_child_paid * 100)::int
        - round(coalesce(v_child.price, 0) * 100)::int);

    -- EB-2c: add-ons are the child's non-flagged lines.
    select coalesce(
             round(sum(jli.quantity * jli.unit_price) * 100)::int, 0)
    into v_add_ons_total
    from public.journey_line_items jli
    where jli.journey_id = v_action.child_journey_id
      and jli.exchange_action_id is null
      and jli.exchange_line_role is null;
  end if;

  v_can_start := public.has_permission('sleep_trial.start_exchange');
  v_can_complete := public.has_permission('sleep_trial.complete_exchange');
  v_can_void := public.has_permission('sleep_trial.void_refund');

  -- 164: reopening needs its own key (admin/manager seeded, owner
  -- implicit); the fail-closed quarantine reason comes back null when
  -- the original is still held or was never received.
  v_can_reopen := v_action.status = 'COMPLETED'
    and public.has_permission('sleep_trial.reopen_action');
  v_reopen_reason := public.stv_action_reopen_block_reason(v_action);

  -- Money settled: a recorded refund when one is owed, else the child's
  -- price fully paid (a $0 replacement is settled by definition).
  v_money_done :=
    (coalesce(v_action.refund_owed_cents, 0) > 0
       and v_action.refund_recorded_at is not null)
    or (coalesce(v_action.refund_owed_cents, 0) <= 0
        and v_child.id is not null
        and v_child_paid >= coalesce(v_child.price, 0));
  if coalesce(v_action.refund_owed_cents, 0) > 0
     and v_action.refund_recorded_at is not null then
    v_money_at := v_action.refund_recorded_at;
    v_money_by := v_action.refund_recorded_by;
    v_money_by_name := v_refund_recorded_by_name;
  else
    v_money_at := v_child_paid_at;
    v_money_by := null;
    v_money_by_name := null;
  end if;

  -- Cancel blockers, same order and wording as cancel_sleep_trial_action.
  v_block_code := null;
  v_block_msg := null;
  if v_action.status <> 'COMMITTED' then
    v_block_code := 'not_committed';
    v_block_msg := 'Only a committed exchange can be cancelled';
  elsif v_action.original_received_on is not null then
    v_block_code := 'original_received';
    v_block_msg := 'The original mattress was already received  -  this exchange cannot be cancelled';
  elsif v_action.refund_recorded_at is not null then
    v_block_code := 'refund_recorded';
    v_block_msg := 'A refund was already recorded on this exchange  -  it cannot be cancelled';
  elsif v_child.id is not null and v_child.delivered_at is not null then
    v_block_code := 'replacement_delivered';
    v_block_msg := 'The replacement was already delivered  -  this exchange cannot be cancelled';
  elsif v_child_has_payment then
    v_block_code := 'payment_on_record';
    v_block_msg := 'The replacement has a payment on record  -  resolve it before cancelling the exchange';
  end if;

  -- Complete blockers in the exact check order of
  -- complete_sleep_trial_action (all unmet, not just the first).
  select coalesce(jsonb_agg(t.m order by t.ord), '[]'::jsonb)
  into v_blockers
  from (
    values
      (1, 'The replacement has not been delivered yet',
          v_action.replacement_delivered_on is null),
      (2, 'The original mattress has not been marked received yet',
          v_action.original_received_on is null),
      (3, 'The replacement still has an unpaid balance',
          v_child.id is not null
            and coalesce(v_child.price, 0) > 0
            and v_child_paid < v_child.price),
      (4, 'The owed refund has not been recorded yet',
          coalesce(v_action.refund_owed_cents, 0) > 0
            and v_action.refund_recorded_at is null)
  ) as t(ord, m, is_open)
  where t.is_open;

  -- Split return: see the header  -  one jsonb_build_object call cannot
  -- exceed 100 arguments (50 keys). 38 + 16 = 54 keys total.
  return jsonb_build_object(
    'action_id', v_action.id,
    'status', v_action.status,
    'action', v_action.action,
    'trial_item_id', v_action.trial_item_id,
    'journey_id', v_action.journey_id,
    'child_journey_id', v_action.child_journey_id,
    'replacement_product_id', v_action.replacement_product_id,
    'replacement_product_name', v_repl_name,
    'replacement_price_cents', v_action.replacement_price_cents,
    'original_credit_cents', v_action.original_credit_cents,
    'exchange_fee_cents', v_action.exchange_fee_cents,
    'other_fees_cents', v_action.other_fees_cents,
    'tax_cents', v_action.tax_cents,
    'net_cents', v_action.net_cents,
    'refund_owed_cents', v_action.refund_owed_cents,
    'refund_method', v_action.refund_method,
    'refund_amount_cents', v_action.refund_amount_cents,
    'refund_reference', v_action.refund_reference,
    'refund_recorded_at', v_action.refund_recorded_at,
    'refund_recorded_by', v_action.refund_recorded_by,
    'refund_recorded_by_name', v_refund_recorded_by_name,
    'refund_history', v_action.refund_history,
    'original_received_on', v_action.original_received_on,
    'replacement_delivered_on', v_action.replacement_delivered_on,
    'completed_at', v_action.completed_at,
    'completed_by', v_action.completed_by,
    'completed_by_name', v_completed_by_name,
    'cancelled_at', v_action.cancelled_at,
    'cancelled_by', v_action.cancelled_by,
    'cancelled_by_name', v_cancelled_by_name,
    'cancel_reason', v_action.cancel_reason,
    'fulfillment_method', v_action.fulfillment_method,
    'created_by', v_action.created_by,
    'created_by_name', v_creator_name,
    'created_at', v_action.created_at,
    'committed_at', v_action.committed_at,
    'committed_by', v_action.committed_by,
    'committed_by_name', v_committed_by_name)
  || jsonb_build_object(
    'child_price', v_child.price,
    'child_total_paid', v_child_paid,
    'child_has_succeeded_payment', v_child_has_payment,
    'child_overpaid_cents', v_child_overpaid,
    'add_ons_total_cents', v_add_ons_total,
    'milestones', jsonb_build_object(
      'replacement_reserved', jsonb_build_object(
        'done', v_child_reserved,
        'at', null,
        'by', null),
      'replacement_delivered', jsonb_build_object(
        'done', v_action.replacement_delivered_on is not null,
        'at', v_action.replacement_delivered_on,
        'by', null),
      'original_received', jsonb_build_object(
        'done', v_action.original_received_on is not null,
        'at', v_action.original_received_on,
        'by', null),
      'money_settled', jsonb_build_object(
        'done', v_money_done,
        'at', v_money_at,
        'by', v_money_by_name),
      'completed', jsonb_build_object(
        'done', v_action.completed_at is not null,
        'at', v_action.completed_at,
        'by', v_completed_by_name)),
    'can_cancel', v_can_start and v_action.status = 'COMMITTED',
    'cancel_block_code', v_block_code,
    'cancel_block_message', v_block_msg,
    'can_record_refund', v_can_complete
      and v_action.status = 'COMMITTED'
      and coalesce(v_action.refund_owed_cents, 0) > 0
      and v_action.refund_recorded_at is null,
    -- On a COMPLETED action void and reopen are the same path, so
    -- sleep_trial.reopen_action alone unlocks the button there; a
    -- COMMITTED void still needs sleep_trial.void_refund.
    'can_void_refund', v_action.refund_recorded_at is not null
      and ((v_action.status = 'COMMITTED' and v_can_void)
           or (v_action.status = 'COMPLETED'
               and public.has_permission('sleep_trial.reopen_action'))),
    'can_complete', v_can_complete
      and v_action.status = 'COMMITTED',
    'complete_blockers', v_blockers,
    'can_reopen', v_can_reopen,
    'reopen_block_reason', v_reopen_reason);
end;
$$;

revoke execute on function public.get_exchange_action(uuid) from public, anon;
grant execute on function public.get_exchange_action(uuid) to authenticated;

-- ============================================================================
-- 8. void_exchange_refund (091 body): the legacy direct-action void. A
--    COMPLETED exchange can no longer be voided in place - voiding its
--    refund IS a reopen, so it delegates to reopen_sleep_trial_action
--    which performs the whole job under the same row lock. COMMITTED
--    keeps the original snapshot-then-clear semantics unchanged.
-- ============================================================================

create or replace function public.void_exchange_refund(
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
  v_recorded_by_name text;
  v_snapshot jsonb;
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

  -- 164: on a COMPLETED exchange the void IS the reopen (the recorded
  -- refund voids, the item reopens, the journey derives back). It
  -- delegates BEFORE the void_refund gate because the reopen path runs
  -- on sleep_trial.reopen_action, which reopen_sleep_trial_action
  -- enforces itself; COMMITTED falls through to the original
  -- snapshot-then-clear below.
  if v_action.status = 'COMPLETED' then
    perform public.reopen_sleep_trial_action(v_action.id, p_reason);
    return;
  end if;

  if not public.has_permission('sleep_trial.void_refund') then
    raise exception 'Missing permission: sleep_trial.void_refund';
  end if;
  select e.id, e.name into v_employee, v_employee_name
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'A reason is required to void a refund';
  end if;
  if v_action.status <> 'COMMITTED' then
    raise exception 'Only a committed exchange can void a refund (status %)',
      v_action.status;
  end if;
  if v_action.refund_recorded_at is null then
    raise exception 'No recorded refund to void on this exchange';
  end if;

  select e.name into v_recorded_by_name
  from public.employees e
  where e.id = v_action.refund_recorded_by;

  -- Snapshot FIRST: the voided record stays readable in refund_history
  -- forever; the active columns are cleared afterwards.
  v_snapshot := jsonb_build_object(
    'refund_method', v_action.refund_method,
    'refund_amount_cents', v_action.refund_amount_cents,
    'refund_reference', v_action.refund_reference,
    'recorded_by', v_action.refund_recorded_by,
    'recorded_by_name', v_recorded_by_name,
    'recorded_at', v_action.refund_recorded_at,
    'voided_by', v_employee,
    'voided_by_name', v_employee_name,
    'voided_at', now(),
    'void_reason', btrim(p_reason));

  update public.sleep_trial_actions
  set refund_history = refund_history || jsonb_build_array(v_snapshot),
      refund_method = null,
      refund_amount_cents = null,
      refund_reference = null,
      refund_recorded_by = null,
      refund_recorded_at = null
  where id = v_action.id;

  perform public.log_audit_event(
    p_company_id := v_action.company_id,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action.id,
    p_event_type := 'EXCHANGE_REFUND_VOIDED',
    p_before := v_snapshot,
    p_after := jsonb_build_object(
      'refund_recorded_at', null,
      'refund_history_count',
        jsonb_array_length(v_action.refund_history) + 1),
    p_journey_id := v_action.journey_id,
    p_actor_employee_id := v_employee);

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
    'Exchange refund voided by ' || coalesce(v_employee_name, 'an employee')
      || ' - ' || btrim(p_reason)
      || ' (was ' || coalesce(v_action.refund_method, '?')
      || ' $' || to_char(coalesce(v_action.refund_amount_cents, 0) / 100.0,
                          'FM999999990.00') || ')',
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
      'Exchange refund voided - the refund is owed again',
      v_employee, 'sleep_trial_action', v_action.id, true
    );
  end if;
end;
$$;

revoke execute on function public.void_exchange_refund(uuid, text)
  from public, anon;
grant execute on function public.void_exchange_refund(uuid, text)
  to authenticated;
