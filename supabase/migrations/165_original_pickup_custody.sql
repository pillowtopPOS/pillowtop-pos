-- ============================================================================
-- Migration 165: original-mattress pickup custody on exchange actions
--
-- The way the original mattress comes back is decided by the replacement
-- order's fulfillment method: a DELIVERY driver picks it up at the stop,
-- a PICKUP customer hands it over at the pickup location. This migration
-- records that custody event on sleep_trial_actions without touching
-- inventory: custody stays informational until receive_returned_unit
-- puts the unit into quarantine (the money rule R2 is unchanged).
--
-- Sections:
--   1. Custody columns + history on sleep_trial_actions
--   2. record_original_handover - record or overwrite the outcome
--   3. void_original_handover - reasoned correction, history kept
--   4. get_exchange_action - custody payload + cancel_warning (164 body)
--   5. list_open_trial_actions - custody fields for the worklists (163)
-- ============================================================================

-- ============================================================================
-- 1. Custody columns + history
--
-- original_pickup_outcome: null = not yet. PICKED_UP = with the driver,
-- HANDED_OVER = at a location waiting to be received, NOT_PICKED_UP and
-- NOT_HANDED_OVER = the customer kept it (reason required). Received is
-- still derived from original_received_on, which no code here writes.
--
-- original_pickup_history is append-only, same idea as refund_history:
-- every displaced state lands there with who/when/why it was displaced.
-- The live columns are never cleared by an overwrite; a void resets them
-- to not-yet after archiving the displaced state.
-- ============================================================================

alter table public.sleep_trial_actions
  add column if not exists original_pickup_outcome text,
  add column if not exists original_pickup_on date,
  add column if not exists original_pickup_location_id uuid
    references public.stores(id),
  add column if not exists original_pickup_by uuid
    references public.employees(id),
  add column if not exists original_pickup_reason text,
  add column if not exists original_pickup_event_id uuid,
  add column if not exists original_pickup_history jsonb
    not null default '[]'::jsonb;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'sleep_trial_actions_pickup_outcome_chk'
  ) then
    alter table public.sleep_trial_actions
      add constraint sleep_trial_actions_pickup_outcome_chk
      check (original_pickup_outcome is null
        or original_pickup_outcome in
           ('PICKED_UP', 'HANDED_OVER', 'NOT_PICKED_UP', 'NOT_HANDED_OVER'));
  end if;
end $$;

-- ============================================================================
-- 2. record_original_handover
--
-- Records the custody outcome on a COMMITTED action. Calling it again
-- overwrites the current outcome and archives the displaced state in
-- original_pickup_history (no separate void needed to change an answer).
--
-- Permission: the same gate used to record a fulfillment on the
-- replacement order, widened to cover both methods - a recorder may be
-- either a pickup finalizer (orders.mark_fulfilled) or a delivery
-- finalizer (can_finalize_delivery); the handover question can appear on
-- either dialog.
-- ============================================================================

create or replace function public.record_original_handover(
  p_action_id   uuid,
  p_outcome     text,
  p_location_id uuid default null,
  p_reason      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action     public.sleep_trial_actions%rowtype;
  v_journey    public.sleep_journeys%rowtype;
  v_employee   uuid;
  v_emp_name   text;
  v_loc_name   text;
  v_reason     text := nullif(btrim(coalesce(p_reason, '')), '');
  v_tz         text;
  v_today      date;
  v_note       text;
  v_note_id    uuid;
begin
  if auth.uid() is null then
    raise exception 'Not signed in.';
  end if;

  select e.id, e.name into v_employee, v_emp_name
  from public.employees e
  where e.auth_user_id = auth.uid() and e.is_active;
  if v_employee is null then
    raise exception 'Not signed in as an active employee.';
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

  if v_action.status <> 'COMMITTED' then
    raise exception
      'Only a committed action can record an original pickup (status %).',
      v_action.status;
  end if;

  if v_action.original_received_on is not null then
    raise exception
      'The original was already received on % - void the receipt to correct it.',
      v_action.original_received_on;
  end if;

  if p_outcome not in
     ('PICKED_UP', 'HANDED_OVER', 'NOT_PICKED_UP', 'NOT_HANDED_OVER') then
    raise exception 'Invalid pickup outcome %.', p_outcome;
  end if;

  if p_outcome in ('NOT_PICKED_UP', 'NOT_HANDED_OVER')
     and v_reason is null then
    raise exception
      'A reason is required when the old mattress is not picked up.';
  end if;

  if p_outcome = 'HANDED_OVER' and p_location_id is null then
    raise exception 'A location is required to record a handover.';
  end if;

  -- A location, whenever given, must be a store of the same company.
  if p_location_id is not null then
    select s.name into v_loc_name
    from public.stores s
    where s.id = p_location_id
      and s.company_id = v_action.company_id;
    if v_loc_name is null then
      raise exception 'That location is not part of this company.';
    end if;
  end if;

  -- Same gate as record_journey_fulfillment, covering both methods: the
  -- question shows on the delivery dialog (can_finalize_delivery) and on
  -- the pickup dialog (orders.mark_fulfilled).
  if not (public.has_permission('orders.mark_fulfilled')
          or public.can_finalize_delivery()) then
    raise exception
      'You do not have permission to record a mattress pickup.';
  end if;

  select * into v_journey
  from public.sleep_journeys
  where id = v_action.journey_id;

  select coalesce(nullif(s.timezone, ''), 'America/Phoenix') into v_tz
  from public.stores s where s.id = v_journey.store_id;
  v_today := (now() at time zone v_tz)::date;

  -- Overwrite semantics: archive the displaced state before stamping the
  -- new one. The void fields record who replaced it and why.
  if v_action.original_pickup_outcome is not null then
    update public.sleep_trial_actions
    set original_pickup_history =
          original_pickup_history || jsonb_build_object(
            'outcome', v_action.original_pickup_outcome,
            'location_id', v_action.original_pickup_location_id,
            'location_name',
              (select s.name from public.stores s
               where s.id = v_action.original_pickup_location_id),
            'reason', v_action.original_pickup_reason,
            'recorded_at', v_action.original_pickup_on,
            'recorded_by', v_action.original_pickup_by,
            'recorded_by_name',
              (select e.name from public.employees e
               where e.id = v_action.original_pickup_by),
            'voided_at', now(),
            'voided_by', v_employee,
            'void_reason',
              'Superseded by a new outcome: ' || p_outcome)
    where id = v_action.id;
  end if;

  update public.sleep_trial_actions
  set original_pickup_outcome = p_outcome,
      original_pickup_on = v_today,
      original_pickup_location_id = p_location_id,
      original_pickup_by = v_employee,
      original_pickup_reason = v_reason
  where id = v_action.id;

  perform public.log_audit_event(
    p_company_id := v_action.company_id,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action.id,
    p_event_type := 'ORIGINAL_PICKUP_RECORDED',
    p_after := jsonb_build_object(
      'outcome', p_outcome,
      'location_id', p_location_id,
      'reason', v_reason),
    p_journey_id := v_action.journey_id,
    p_actor_employee_id := v_employee);

  v_note := case p_outcome
    when 'PICKED_UP'
      then 'Old mattress picked up by the driver'
    when 'HANDED_OVER'
      then 'Old mattress handed over at ' || v_loc_name
    when 'NOT_PICKED_UP'
      then 'Old mattress not picked up: ' || v_reason
    else 'Old mattress not handed over: ' || v_reason
  end;

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain,
    source_record_id, is_internal
  ) values (
    v_action.journey_id, v_journey.customer_id,
    'internal_note', 'internal', 'internal', 'return_exchange',
    v_note || ' by ' || coalesce(v_emp_name, 'an employee'),
    v_employee, 'sleep_trial_action', v_action.id, true
  ) returning id into v_note_id;

  if v_action.child_journey_id is not null then
    insert into public.journey_interactions (
      journey_id, customer_id, interaction_type, channel, direction,
      topic, summary, created_by_employee_id, source_domain,
      source_record_id, is_internal
    ) values (
      v_action.child_journey_id, v_journey.customer_id,
      'internal_note', 'internal', 'internal', 'return_exchange',
      v_note || ' by ' || coalesce(v_emp_name, 'an employee'),
      v_employee, 'sleep_trial_action', v_action.id, true
    );
  end if;

  update public.sleep_trial_actions
  set original_pickup_event_id = v_note_id
  where id = v_action.id;

  return jsonb_build_object(
    'action_id', v_action.id,
    'outcome', p_outcome,
    'on', v_today,
    'location_id', p_location_id,
    'location_name', v_loc_name);
end;
$$;

revoke all on function public.record_original_handover(uuid, text, uuid, text)
  from public, anon;
grant execute on function public.record_original_handover(uuid, text, uuid, text)
  to authenticated;

-- ============================================================================
-- 3. void_original_handover
--
-- Reasoned correction for a pickup or handover recorded by mistake: the
-- displaced state is archived in original_pickup_history with the void
-- reason, then the live columns reset to not-yet. Refused once the
-- original is received - that correction lives in void_returned_receipt.
--
-- Permission: whoever recorded the outcome can fix their own entry; a
-- manager can fix anyone's (sleep_trial.complete_exchange is seeded to
-- admin and manager, owner implicit - the same set that completes the
-- forward step).
-- ============================================================================

create or replace function public.void_original_handover(
  p_action_id uuid,
  p_reason    text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action   public.sleep_trial_actions%rowtype;
  v_journey  public.sleep_journeys%rowtype;
  v_employee uuid;
  v_emp_name text;
  v_reason   text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if auth.uid() is null then
    raise exception 'Not signed in.';
  end if;

  select e.id, e.name into v_employee, v_emp_name
  from public.employees e
  where e.auth_user_id = auth.uid() and e.is_active;
  if v_employee is null then
    raise exception 'Not signed in as an active employee.';
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

  if v_action.status <> 'COMMITTED' then
    raise exception
      'Only a committed action can void an original pickup (status %).',
      v_action.status;
  end if;

  if v_action.original_received_on is not null then
    raise exception
      'The original was already received - use the receipt void to correct it.';
  end if;

  if v_action.original_pickup_outcome is null then
    raise exception 'There is no recorded pickup or handover to void.';
  end if;

  if not (public.has_permission('sleep_trial.complete_exchange')
          or v_action.original_pickup_by = v_employee) then
    raise exception
      'Only a manager or the employee who recorded it can void this entry.';
  end if;

  if v_reason is null then
    raise exception 'A reason is required to void a recorded handover.';
  end if;

  select * into v_journey
  from public.sleep_journeys
  where id = v_action.journey_id;

  update public.sleep_trial_actions
  set original_pickup_history =
        original_pickup_history || jsonb_build_object(
          'outcome', v_action.original_pickup_outcome,
          'location_id', v_action.original_pickup_location_id,
          'location_name',
            (select s.name from public.stores s
             where s.id = v_action.original_pickup_location_id),
          'reason', v_action.original_pickup_reason,
          'recorded_at', v_action.original_pickup_on,
          'recorded_by', v_action.original_pickup_by,
          'recorded_by_name',
            (select e.name from public.employees e
             where e.id = v_action.original_pickup_by),
          'voided_at', now(),
          'voided_by', v_employee,
          'void_reason', v_reason),
      original_pickup_outcome = null,
      original_pickup_on = null,
      original_pickup_location_id = null,
      original_pickup_by = null,
      original_pickup_reason = null,
      original_pickup_event_id = null
  where id = v_action.id;

  perform public.log_audit_event(
    p_company_id := v_action.company_id,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action.id,
    p_event_type := 'ORIGINAL_PICKUP_VOIDED',
    p_after := jsonb_build_object('reason', v_reason),
    p_journey_id := v_action.journey_id,
    p_actor_employee_id := v_employee);

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain,
    source_record_id, is_internal
  ) values (
    v_action.journey_id, v_journey.customer_id,
    'internal_note', 'internal', 'internal', 'return_exchange',
    'Old mattress handover voided: ' || v_reason
      || ' by ' || coalesce(v_emp_name, 'an employee'),
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
      'Old mattress handover voided: ' || v_reason
        || ' by ' || coalesce(v_emp_name, 'an employee'),
      v_employee, 'sleep_trial_action', v_action.id, true
    );
  end if;

  return jsonb_build_object('action_id', v_action.id, 'voided', true);
end;
$$;

revoke all on function public.void_original_handover(uuid, text)
  from public, anon;
grant execute on function public.void_original_handover(uuid, text)
  to authenticated;


-- ============================================================================
-- 4. get_exchange_action (164 body): the payload grows the custody fields
--    and cancel_warning, a non-blocking note for the cancel dialog set
--    when the original is recorded picked up or handed over but has not
--    been received. Nothing else changes.
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
  v_pickup_loc_name text;
  v_pickup_by_name text;
  v_custody text;
  v_cancel_warning text;
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

  -- 165: original-mattress custody, derived from the pickup columns.
  -- Received still wins: receive_returned_unit sets
  -- original_received_on and no pickup column outranks it.
  if v_action.original_pickup_location_id is not null then
    select s.name into v_pickup_loc_name
    from public.stores s
    where s.id = v_action.original_pickup_location_id;
  end if;
  if v_action.original_pickup_by is not null then
    select e.name into v_pickup_by_name
    from public.employees e
    where e.id = v_action.original_pickup_by;
  end if;
  v_custody := case
    when v_action.original_received_on is not null then 'received'
    when v_action.original_pickup_outcome = 'PICKED_UP' then 'with_driver'
    when v_action.original_pickup_outcome = 'HANDED_OVER'
      then 'waiting_to_receive'
    else 'not_yet' end;
  if v_action.original_pickup_outcome = 'HANDED_OVER'
     and v_action.original_received_on is null then
    v_cancel_warning :=
      'The old mattress was handed over at '
      || coalesce(v_pickup_loc_name, 'an unknown location')
      || ' on ' || to_char(v_action.original_pickup_on, 'Mon DD')
      || '. It has to go back to the customer.';
  elsif v_action.original_pickup_outcome = 'PICKED_UP'
     and v_action.original_received_on is null then
    v_cancel_warning :=
      'The old mattress was picked up on '
      || to_char(v_action.original_pickup_on, 'Mon DD')
      || '. It has to go back to the customer.';
  end if;

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
    'reopen_block_reason', v_reopen_reason,
    'original_pickup_outcome', v_action.original_pickup_outcome,
    'original_pickup_on', v_action.original_pickup_on,
    'original_pickup_location_id', v_action.original_pickup_location_id,
    'original_pickup_location_name', v_pickup_loc_name,
    'original_pickup_by', v_action.original_pickup_by,
    'original_pickup_by_name', v_pickup_by_name,
    'original_pickup_reason', v_action.original_pickup_reason,
    'original_pickup_custody', v_custody,
    'cancel_warning', v_cancel_warning);
end;
$$;

revoke execute on function public.get_exchange_action(uuid) from public, anon;
grant execute on function public.get_exchange_action(uuid) to authenticated;

-- ============================================================================
-- 5. list_open_trial_actions (163 body): same row shape plus the custody
--    columns so Inventory "Returns to receive" and My Work "Needs you"
--    can say where the original is without a per-row fetch.
-- ============================================================================

drop function if exists public.list_open_trial_actions();

create function public.list_open_trial_actions()
returns table (
  action_id uuid,
  action text,
  journey_id uuid,
  journey_number text,
  journey_state text,
  customer_name text,
  trial_item_id uuid,
  product_name text,
  store_id uuid,
  store_name text,
  started_by_employee_id uuid,
  started_by_name text,
  committed_at timestamptz,
  days_committed integer,
  original_received_on date,
  replacement_delivered_on date,
  child_journey_id uuid,
  refund_owed_cents integer,
  refund_recorded_at timestamptz,
  is_stalled boolean,
  original_pickup_outcome text,
  original_pickup_on date,
  original_pickup_location_id uuid,
  original_pickup_location_name text,
  original_pickup_by_name text,
  original_pickup_reason text,
  original_pickup_custody text
)
language sql
stable
security definer
set search_path = public
as $$
  select
    a.id as action_id,
    a.action,
    a.journey_id,
    sj.journey_number,
    sj.current_state as journey_state,
    btrim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, ''))
      as customer_name,
    a.trial_item_id,
    ti.product_name_snapshot as product_name,
    sj.store_id,
    s.name as store_name,
    coalesce(a.committed_by, a.created_by) as started_by_employee_id,
    e.name as started_by_name,
    a.committed_at,
    floor(extract(epoch from (now() - a.committed_at)) / 86400)::int
      as days_committed,
    a.original_received_on,
    a.replacement_delivered_on,
    a.child_journey_id,
    a.refund_owed_cents,
    a.refund_recorded_at,
    (
      a.committed_at
        < now() - make_interval(days => co.exchange_stalled_days)
      and (
        a.original_received_on is null
        or (a.action = 'EXCHANGE'
              and a.replacement_delivered_on is null)
        or (a.action = 'EXCHANGE'
              and coalesce(cj.price, 0) > 0
              and public.total_paid(cj.id) < cj.price)
        or (coalesce(a.refund_owed_cents, 0) > 0
              and a.refund_recorded_at is null)
      )
    ) as is_stalled,
    a.original_pickup_outcome,
    a.original_pickup_on,
    a.original_pickup_location_id,
    pkl.name as original_pickup_location_name,
    pke.name as original_pickup_by_name,
    a.original_pickup_reason,
    case
      when a.original_received_on is not null then 'received'
      when a.original_pickup_outcome = 'PICKED_UP' then 'with_driver'
      when a.original_pickup_outcome = 'HANDED_OVER'
        then 'waiting_to_receive'
      else 'not_yet'
    end as original_pickup_custody
  from public.sleep_trial_actions a
  join public.sleep_journeys sj on sj.id = a.journey_id
  join public.customers c on c.id = sj.customer_id
  join public.stores s on s.id = sj.store_id
  join public.companies co on co.id = s.company_id
  left join public.sleep_trial_items ti on ti.id = a.trial_item_id
  left join public.employees e
    on e.id = coalesce(a.committed_by, a.created_by)
  left join public.sleep_journeys cj on cj.id = a.child_journey_id
  left join public.stores pkl on pkl.id = a.original_pickup_location_id
  left join public.employees pke on pke.id = a.original_pickup_by
  where a.status = 'COMMITTED'
    and a.action in ('RETURN', 'EXCHANGE')
    and public.is_journey_visible(a.journey_id)
  order by a.committed_at;
$$;

revoke execute on function public.list_open_trial_actions()
  from public, anon;
grant execute on function public.list_open_trial_actions()
  to authenticated;
