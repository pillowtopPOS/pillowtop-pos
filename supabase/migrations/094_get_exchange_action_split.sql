-- ============================================================================
-- EB-2c fix 2 — get_exchange_action argument-count split (Oct 12, 2026)
--
-- 093 broke this function in the database:
--   ERROR 54023: cannot pass more than 100 arguments to a function
-- PostgreSQL caps a single function call at 100 arguments; every key AND
-- value of jsonb_build_object counts, so a flat call tops out at 50 keys.
-- The 091 body had exactly 50 keys (100 arguments — at the limit); 093's
-- child_overpaid_cents + add_ons_total_cents pushed it to 52 keys (104
-- arguments). PL/pgSQL does not validate this at CREATE time, so the
-- migration "succeeded" and every call failed.
--
-- RULE FOR THE FUTURE: never put more than 40 keys (80 arguments) in one
-- jsonb_build_object/json_build_object call. Split the result and join
-- with || — the merged object is identical. The scanner at
-- scripts/check_jsonb_args.py enforces this on every migration.
--
-- This file is the 093 body verbatim with only the return split into two
-- calls. 093 itself is NOT edited — it already ran; this supersedes its
-- version of the function.
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
    select exists (
      select 1 from public.journey_events je
      where je.journey_id = v_action.child_journey_id
        and je.event_type in ('deposit_received','payment_completed')
        and je.outcome = 'SUCCEEDED')
    into v_child_has_payment;
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
