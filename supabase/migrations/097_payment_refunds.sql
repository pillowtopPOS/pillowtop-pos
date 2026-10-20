-- ============================================================================
-- REFUNDS-B1 (2 of 2): record refunds against payments
--
-- The app RECORDS refunds; it never moves money. A refund is a separate
-- journey_events row (event_type 'payment_refunded', added in 096) that
-- points back at the payment it refunds. Net paid therefore becomes:
--
--   total_paid = sum(SUCCEEDED deposit_received / payment_completed amounts)
--              - sum(SUCCEEDED payment_refunded amounts)
--
-- What this file does:
--   1. total_paid — 014:67-87 body plus the refund subtraction.
--   2. record_payment_refund — owner/admin/manager of the journey's company
--      records a refund against a SUCCEEDED payment (cap: refunds on a
--      payment cannot exceed what was paid on it), then re-evaluates
--      balance and inventory.
--   3. void_payment_refund — flips a refund to VOIDED with a
--      payment_reconciliation_events audit row, then re-evaluates
--      (total_paid goes back up). Deliberately does NOT route through
--      reconcile_payment_event, which only re-evaluates on SUCCEEDED.
--   4. Cancel guards — cancel_sleep_trial_action (091 body verbatim) and
--      get_exchange_action (094 body verbatim): "exists a SUCCEEDED
--      payment" becomes "net paid > 0", so a fully-refunded child can be
--      cancelled. get_exchange_action's jsonb_build_object calls stay at
--      or below the 80-argument scanner threshold.
--
-- Confirmed no other trigger reacts to a payment_refunded row:
--   derive_journey_state (020:139-232) acts only on the mapped
--   deposit_received/payment_completed branch and journey_cancelled;
--   inventory_journey_event_hook (028:310-320) only fires
--   evaluate_journey_inventory for deposit_received/payment_completed
--   SUCCEEDED. A refund row matches neither — the RPCs below call the
--   re-evaluations explicitly instead.
-- ============================================================================

-- 1. total_paid — net of recorded refunds -----------------------------------

create or replace function public.total_paid(p_journey_id uuid)
returns numeric
language plpgsql
stable
security invoker
set search_path = public
as $$
begin
  return coalesce(
    (
      select sum((event_data->>'amount')::numeric)
      from public.journey_events
      where public.journey_events.journey_id = p_journey_id
        and event_type in ('deposit_received', 'payment_completed')
        and outcome = 'SUCCEEDED'
        and (event_data->>'amount') ~ '^[0-9]+(\.[0-9]+)?$'
    ),
    0
  ) - coalesce(
    (
      select sum((event_data->>'amount')::numeric)
      from public.journey_events
      where public.journey_events.journey_id = p_journey_id
        and event_type = 'payment_refunded'
        and outcome = 'SUCCEEDED'
        and (event_data->>'amount') ~ '^[0-9]+(\.[0-9]+)?$'
    ),
    0
  );
end;
$$;

-- 2. record_payment_refund --------------------------------------------------
-- Records money already returned in the retailer's payment system.
-- Allowed on cancelled and delivered journeys — refund-after-cancel is the
-- common case. The two re-evaluations return early where they must
-- (delivered_at, cancelled_at, non-sale states), so a delivered journey
-- gets the record and the corrected balance with no state rewrite.

create or replace function public.record_payment_refund(
  p_payment_id uuid,
  p_amount numeric,
  p_method text,
  p_reason text,
  p_reference text default null
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

  -- Same caller check as reconcile_payment_event (028:377-384): an owner,
  -- admin or manager employee of the journey's company.
  if not exists (
    select 1 from public.employees e
    join public.stores es on es.id = e.home_store_id
    join public.sleep_journeys sj on sj.id = v_payment.journey_id
    join public.stores js on js.id = sj.store_id
    where e.auth_user_id = auth.uid() and es.company_id = js.company_id
      and e.role::text in ('owner', 'admin', 'manager')
  ) then
    raise exception 'Only owner, admin, or manager may record a refund';
  end if;
  select id into v_emp_id from public.employees where auth_user_id = auth.uid();

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

  insert into public.journey_events (
    journey_id, event_type, event_data, triggered_by, outcome
  ) values (
    v_payment.journey_id,
    'payment_refunded',
    jsonb_build_object(
      'amount', p_amount,
      'method', p_method,
      'refunds_payment_id', p_payment_id,
      'reason', btrim(p_reason),
      'reference', nullif(btrim(coalesce(p_reference, '')), '')
    ),
    auth.uid()::text,
    'SUCCEEDED'
  )
  returning id into v_new_id;

  -- Net paid dropped: re-run the balance and inventory evaluations so a
  -- now-underpaid journey releases reservations and reads balance due.
  perform public.reevaluate_journey_balance(v_payment.journey_id);
  perform public.evaluate_journey_inventory(v_payment.journey_id);

  return v_new_id;
end;
$$;

revoke execute on function public.record_payment_refund(uuid, numeric, text, text, text) from public, anon;
grant execute on function public.record_payment_refund(uuid, numeric, text, text, text) to authenticated;

-- 3. void_payment_refund ----------------------------------------------------
-- Reversal path: the refund entry is never deleted — it flips to VOIDED
-- (stops subtracting in total_paid) with a reconciliation audit row.

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

  -- Same caller check as record_payment_refund.
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

  -- Net paid went back up: re-run the balance and inventory evaluations.
  perform public.reevaluate_journey_balance(v_refund.journey_id);
  perform public.evaluate_journey_inventory(v_refund.journey_id);

  return p_refund_event_id;
end;
$$;

revoke execute on function public.void_payment_refund(uuid, text) from public, anon;
grant execute on function public.void_payment_refund(uuid, text) to authenticated;

-- 4. Cancel guards ----------------------------------------------------------
-- cancel_sleep_trial_action: 091_exchange_ui_support.sql body verbatim,
-- with the child payment guard changed from "a SUCCEEDED payment exists"
-- to "net paid > 0" so a fully-refunded child can be cancelled.

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

  select e.id, e.name into v_employee, v_employee_name
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;
  if not public.has_permission('sleep_trial.start_exchange') then
    raise exception 'Missing permission: sleep_trial.start_exchange';
  end if;

  if v_action.status <> 'COMMITTED' then
    raise exception 'Only a committed exchange can be cancelled (status %)',
      v_action.status;
  end if;

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'A reason is required to cancel an exchange';
  end if;
  if v_action.original_received_on is not null then
    raise exception 'The original mattress was already received — this exchange cannot be cancelled';
  end if;
  if v_action.refund_recorded_at is not null then
    raise exception 'A refund was already recorded on this exchange — it cannot be cancelled';
  end if;
  if exists (
    select 1 from public.sleep_journeys sj
    where sj.id = v_action.child_journey_id
      and sj.delivered_at is not null) then
    raise exception 'The replacement was already delivered — this exchange cannot be cancelled';
  end if;
  if coalesce(public.total_paid(v_action.child_journey_id), 0) > 0 then
    raise exception 'The replacement has a payment on record — resolve it before cancelling the exchange';
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
    p_event_type := 'EXCHANGE_CANCELLED',
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
    'Exchange cancelled by ' || coalesce(v_employee_name, 'an employee')
      || coalesce(' — ' || nullif(btrim(p_reason), ''), ''),
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

-- get_exchange_action: 094_get_exchange_action_split.sql body verbatim,
-- with v_child_has_payment changed from "a SUCCEEDED payment exists" to
-- "net paid > 0" (v_child_paid is total_paid, computed just above).

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
    -- fully reserved — the same journey_inventory_requirements.status the
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
    -- total_paid exceeds the current price — e.g. an add-on was removed
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
    v_block_msg := 'The original mattress was already received — this exchange cannot be cancelled';
  elsif v_action.refund_recorded_at is not null then
    v_block_code := 'refund_recorded';
    v_block_msg := 'A refund was already recorded on this exchange — it cannot be cancelled';
  elsif v_child.id is not null and v_child.delivered_at is not null then
    v_block_code := 'replacement_delivered';
    v_block_msg := 'The replacement was already delivered — this exchange cannot be cancelled';
  elsif v_child_has_payment then
    v_block_code := 'payment_on_record';
    v_block_msg := 'The replacement has a payment on record — resolve it before cancelling the exchange';
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

  -- Split return: see the header — one jsonb_build_object call cannot
  -- exceed 100 arguments (50 keys). 38 + 14 = the same 52 keys as 093.
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
    'can_void_refund', v_can_void
      and v_action.status = 'COMMITTED'
      and v_action.refund_recorded_at is not null,
    'can_complete', v_can_complete
      and v_action.status = 'COMMITTED',
    'complete_blockers', v_blockers);
end;
$$;

revoke execute on function public.get_exchange_action(uuid) from public, anon;
grant execute on function public.get_exchange_action(uuid) to authenticated;
