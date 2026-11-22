-- 167_cap_credit_at_money_received.sql
--
-- Cap exchange and return credit at the money actually received for the
-- mattress.
--
-- Problem: original_credit_cents came straight from
-- sleep_trial_items.fee_basis_cents (the line's unit_price stamped once at
-- trial start). A price cut made after the trial started, or a mattress
-- sold below its stamped price, could produce a credit or a refund owed
-- larger than the cash the customer ever paid.
--
-- Rule: credit_used = least(fee_basis_cents, money_received_for_this_item)
-- where money_received_for_this_item is the item's pro-rata share, by
-- merchandise line price, of the journey's money received. Money received
-- on a journey = recorded payments minus non-voided recorded refunds
-- (voided refunds carry outcome VOIDED and total_paid already excludes
-- them), PLUS any exchange credit applied on that journey (the negative
-- 'credit' exchange lines on a replacement order count as money received,
-- so returning or exchanging a replacement mattress does not credit $0).
-- Trial items with no line (BACKFILL rows) cap at the journey's whole
-- money received.
--
-- What changes:
--   1. New internal helper public.stv_money_received_for_item(uuid).
--   2. quote_sleep_trial_action: copied from 088 verbatim except the
--      credit line and two new payload keys (list_credit_cents,
--      credit_capped).
--   3. commit_sleep_trial_action: copied from 161 verbatim except the two
--      credit lines (RETURN and EXCHANGE branches). Commit recomputes, so
--      a stale quote cannot slip through.
--
-- Existing COMMITTED actions are not rewritten. No data backfill.

-- ============================================================================
-- 1. stv_money_received_for_item: internal, no grant to authenticated.
-- ============================================================================

create or replace function public.stv_money_received_for_item(p_trial_item_id uuid)
returns int
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_item public.sleep_trial_items%rowtype;
  v_received numeric;
  v_own_price numeric;
  v_merch_total numeric;
begin
  select * into v_item
  from public.sleep_trial_items
  where id = p_trial_item_id;
  if not found then
    raise exception 'Trial item not found';
  end if;

  -- Journey money received: recorded payments minus non-voided refunds
  -- (total_paid counts only SUCCEEDED events, so VOIDED refunds do not
  -- subtract), plus exchange credit applied on this journey. Credit lines
  -- carry a negative unit_price; abs of their sum counts them as money
  -- received so a replacement mattress keeps real value.
  v_received := coalesce(public.total_paid(v_item.journey_id), 0)
    + coalesce(
        (
          select abs(sum(jli.quantity * jli.unit_price))
          from public.journey_line_items jli
          where jli.journey_id = v_item.journey_id
            and jli.exchange_line_role = 'credit'
        ),
        0);

  -- Pro-rata share by merchandise price. Merchandise = lines with
  -- exchange_line_role null or 'replacement' (positive merchandise;
  -- 'credit', 'exchange_fee' and 'other_fees' lines are excluded from the
  -- denominator).
  if v_item.line_item_id is not null then
    select jli.quantity * jli.unit_price into v_own_price
    from public.journey_line_items jli
    where jli.id = v_item.line_item_id;

    select sum(jli.quantity * jli.unit_price) into v_merch_total
    from public.journey_line_items jli
    where jli.journey_id = v_item.journey_id
      and (jli.exchange_line_role is null
           or jli.exchange_line_role = 'replacement');

    if coalesce(v_merch_total, 0) > 0 and v_own_price is not null then
      return greatest(0, round(v_received * v_own_price / v_merch_total * 100)::int);
    end if;
  end if;

  -- Fallback, never null: no line (BACKFILL), a missing own line, or a
  -- zero/negative merchandise total all cap at the whole journey's
  -- money received.
  return greatest(0, round(v_received * 100)::int);
end;
$$;

revoke all on function public.stv_money_received_for_item(uuid)
  from public, anon, authenticated;

-- ============================================================================
-- 2. quote_sleep_trial_action: 088 body verbatim, with two changes:
--    - the credit is capped at money received for this item
--    - the payload adds list_credit_cents and credit_capped
-- ============================================================================

create or replace function public.quote_sleep_trial_action(
  p_trial_item_id uuid,
  p_action text,
  p_replacement_product_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.sleep_trial_items%rowtype;
  v_company uuid;
  v_eval jsonb;
  v_action_result jsonb;
  v_fee_cents int;
  v_credit_cents int;
  v_repl_price_cents int;
  v_net int;
  v_used int;
  v_repl_entry jsonb;
  v_preview jsonb;
  v_exc record;
  v_exc_check jsonb;
  v_applicable jsonb;
begin
  if p_action not in ('EXCHANGE','RETURN') then
    raise exception 'action must be EXCHANGE or RETURN';
  end if;

  select * into v_item
  from public.sleep_trial_items
  where id = p_trial_item_id;
  if not found then
    raise exception 'Trial item not found';
  end if;
  if not public.is_journey_visible(v_item.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select st.company_id into v_company
  from public.sleep_journeys sj
  join public.stores st on st.id = sj.store_id
  where sj.id = v_item.journey_id;

  v_eval := public.stv_eval_one(p_trial_item_id, null);
  v_action_result := case p_action
    when 'EXCHANGE' then v_eval #> '{actions,EXCHANGE}'
    else v_eval #> '{actions,RETURN}' end;

  v_fee_cents := coalesce(
    (v_action_result #>> '{fee,amount_cents}')::int, 0);

  -- A null fee basis must not silently read as a zero credit (EB-1 bug):
  -- the credit is the mattress's recorded sale price and is required.
  if v_item.fee_basis_cents is null then
    raise exception
      'This mattress has no recorded sale price (fee basis), so a credit amount cannot be computed';
  end if;
  -- 167: never credit more than the money actually received for this
  -- mattress (pro-rata share of payments minus refunds plus applied
  -- exchange credit; whole journey when the item has no line).
  v_credit_cents := least(v_item.fee_basis_cents,
    public.stv_money_received_for_item(p_trial_item_id));

  -- Replacement default price: sale-aware, same rule as the client's
  -- getEffectivePrice - sale_price first, then price (dollars -> cents).
  v_repl_price_cents := null;
  if p_replacement_product_id is not null then
    select round(coalesce(p.sale_price, p.price) * 100)::int
    into v_repl_price_cents
    from public.products p
    where p.id = p_replacement_product_id
      and p.company_id = v_company;
    if not found then
      raise exception 'Replacement product not found in this company';
    end if;
  end if;

  -- net = replacement + fee - credit (other fees / tax are added later on
  -- the record; quote assumes zero). Signed: positive = customer owes.
  v_net := coalesce(v_repl_price_cents, 0)
           + coalesce(v_fee_cents, 0)
           - coalesce(v_credit_cents, 0);

  -- Replacement trial preview (policy rule base.exchange.replacement_trial,
  -- a list of {n, rule, nights?} indexed by exchange number; missing entry
  -- means NONE - docs/sleep-trial-engine.md Section 17).
  v_used := coalesce(
    (v_eval #>> '{display,exchanges_used}')::int, 0);
  v_repl_entry := null;
  if v_item.resolved_terms #> '{exchange,replacement_trial}' is not null then
    select e.val into v_repl_entry
    from jsonb_array_elements(
      v_item.resolved_terms #> '{exchange,replacement_trial}') as e(val)
    where (e.val ->> 'n')::int = v_used + 1
    limit 1;
  end if;
  if v_item.resolved_terms -> 'exchange' is null then
    v_preview := null;
  else
    v_preview := jsonb_build_object(
      'exchange_number', v_used + 1,
      'rule', coalesce(v_repl_entry ->> 'rule', 'NONE'),
      'nights', nullif(v_repl_entry ->> 'nights', '')::int,
      'replacement_minimum',
        v_item.resolved_terms #> '{exchange,replacement_minimum}');
  end if;

  -- Applicable usable approved exception for this item + action: newest
  -- APPROVED row first; validate each (may lazily mark EXPIRED/STALE) and
  -- take the first usable one. Never consumed here - consumption happens
  -- at commit (EB-2).
  v_applicable := null;
  for v_exc in
    select e.id, e.exception_type::text as exception_type, e.approved_terms
    from public.sleep_trial_exceptions e
    where e.trial_item_id = p_trial_item_id
      and e.action = p_action
      and e.status = 'APPROVED'
    order by e.decided_at desc
  loop
    v_exc_check := public.stv_validate_trial_item_exception(v_exc.id);
    if coalesce((v_exc_check ->> 'usable')::boolean, false) then
      v_applicable := jsonb_build_object(
        'exception_id', v_exc.id,
        'exception_type', v_exc.exception_type,
        'approved_terms', v_exc.approved_terms,
        'usable', true);
      exit;
    end if;
  end loop;

  return jsonb_build_object(
    'trial_item_id', p_trial_item_id,
    'journey_id', v_item.journey_id,
    'action', p_action,
    'evaluation', v_eval,
    'action_result', v_action_result,
    'locked_fee_cents', v_fee_cents,
    'original_credit_cents', v_credit_cents,
    'list_credit_cents', v_item.fee_basis_cents,
    'credit_capped', (v_credit_cents < v_item.fee_basis_cents),
    'replacement_product_id', p_replacement_product_id,
    'replacement_price_cents', v_repl_price_cents,
    'net_cents', v_net,
    'refund_owed_cents', greatest(-v_net, 0),
    'commission_basis_cents', v_net,
    'replacement_trial_preview', v_preview,
    'applicable_exception', v_applicable,
    'quoted_at', now());
end;
$$;

revoke execute on function public.quote_sleep_trial_action(uuid, text, uuid)
  from public, anon;
grant execute on function public.quote_sleep_trial_action(uuid, text, uuid)
  to authenticated;

-- ============================================================================
-- 3. commit_sleep_trial_action: 161 body verbatim, with two changes:
--    the credit lines in the RETURN branch and the EXCHANGE branch both
--    cap at money received for the item. Recomputed at commit so a stale
--    quote cannot slip through.
-- ============================================================================

create or replace function public.commit_sleep_trial_action(p_action_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_item public.sleep_trial_items%rowtype;
  v_journey public.sleep_journeys%rowtype;
  v_employee uuid;
  v_employee_name text;
  v_eval jsonb;
  v_x jsonb;
  v_applied_id uuid;
  v_check jsonb;
  v_exc record;
  v_waiver_id uuid;
  v_waiver_fee int;
  v_policy_fee int;
  v_locked_fee int;
  v_used int;
  v_repl_entry jsonb;
  v_repl_rule text;
  v_credit int;
  v_pos_total int;
  v_credit_line int;
  v_net int;
  v_child uuid;
  v_active_store uuid;
  v_child_store uuid;
  v_repl_name text;
  v_fulfillment public.fulfillment_type;
  v_exc_ids uuid[] := '{}'::uuid[];
begin
  -- Lock order: action, trial item, then inserts.
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

  -- RETURN branch (161): no child journey. The action is COMMITTED once
  -- its item moves to RETURN_IN_PROGRESS; receiving, the refund and the
  -- close-out happen later through receive_returned_unit,
  -- record_payment_refund (with p_action_id) and
  -- complete_sleep_trial_action. Returns null because there is no child.
  if v_action.action = 'RETURN' then
    if not public.has_permission('sleep_trial.start_return') then
      raise exception 'Missing permission: sleep_trial.start_return';
    end if;

    select e.id, e.name into v_employee, v_employee_name
    from public.employees e
    where e.auth_user_id = auth.uid()
      and e.is_active;
    if v_employee is null then
      raise exception 'Employee record not found';
    end if;

    -- Idempotent retry, same rule as the exchange path.
    if v_action.status = 'COMMITTED' then
      return null;
    end if;
    if v_action.status <> 'DRAFT' then
      raise exception 'Only a draft can be committed (status %)', v_action.status;
    end if;

    select * into v_item
    from public.sleep_trial_items
    where id = v_action.trial_item_id
    for update;
    if not found then
      raise exception 'Trial item not found';
    end if;
    if v_item.status <> 'ACTIVE' then
      raise exception 'This mattress''s trial is not active (status %)',
        v_item.status;
    end if;

    select * into v_journey
    from public.sleep_journeys
    where id = v_action.journey_id;

    -- The refund is the item's recorded sale price minus the return fee;
    -- a null basis must not read as a zero refund.
    if v_item.fee_basis_cents is null then
      raise exception 'This mattress has no recorded sale price (fee basis), so a refund amount cannot be computed';
    end if;
    -- 167: never credit more than the money actually received for this
    -- mattress.
    v_credit := least(v_item.fee_basis_cents,
      public.stv_money_received_for_item(v_item.id));

    -- Gate: evaluate before the item moves to in-progress.
    v_eval := public.stv_eval_one(v_action.trial_item_id, null);
    v_x := v_eval #> '{actions,RETURN}';
    if coalesce(v_x ->> 'status', '') <> 'ELIGIBLE' then
      raise exception 'This return is not eligible right now: %',
        coalesce(v_x ->> 'explanation', v_x ->> 'reason_code', 'unknown reason');
    end if;

    -- The evaluator's applied exception must still be usable before it is
    -- consumed; a stale or expired approval gets a friendly refusal.
    v_applied_id := nullif(v_x ->> 'applied_exception_id', '')::uuid;
    if v_applied_id is not null then
      v_check := public.stv_validate_trial_item_exception(v_applied_id);
      if not coalesce((v_check ->> 'usable')::boolean, false) then
        raise exception 'The approval covering this return is no longer valid (%) - request a new approval',
          coalesce(v_check ->> 'detail', v_check ->> 'reason', 'not usable');
      end if;
    end if;

    -- Fee waiver, separate from the gate: the newest usable APPROVED
    -- FEE_WAIVER for this item + RETURN sets the charged fee (0 by
    -- default, or an approved reduced amount in approved_terms).
    v_policy_fee := coalesce((v_x #>> '{fee,amount_cents}')::int, 0);
    v_locked_fee := v_policy_fee;
    v_waiver_id := null;
    v_waiver_fee := null;
    for v_exc in
      select e.id, e.approved_terms
      from public.sleep_trial_exceptions e
      where e.trial_item_id = v_action.trial_item_id
        and e.action = 'RETURN'
        and e.exception_type::text = 'FEE_WAIVER'
        and e.status = 'APPROVED'
      order by e.decided_at desc
    loop
      v_check := public.stv_validate_trial_item_exception(v_exc.id);
      if coalesce((v_check ->> 'usable')::boolean, false) then
        v_waiver_id := v_exc.id;
        -- Approved fee terms mirror the policy fee-schedule keys: a flat
        -- amount, or percent_bp of the fee basis rounded half-up (070).
        v_waiver_fee := case
          when v_exc.approved_terms ? 'fee_amount_cents' then
            (v_exc.approved_terms ->> 'fee_amount_cents')::int
          when v_exc.approved_terms ? 'fee_flat_cents' then
            (v_exc.approved_terms ->> 'fee_flat_cents')::int
          when v_exc.approved_terms ? 'fee_percent_bp' then
            ((v_credit::bigint
              * coalesce((v_exc.approved_terms ->> 'fee_percent_bp')::int, 0)
              + 5000) / 10000)::int
          else 0 end;
        exit;
      end if;
    end loop;
    if v_waiver_id is not null then
      -- Fee never exceeds the credit, same invariant as the evaluator.
      v_locked_fee := least(greatest(v_waiver_fee, 0), v_credit);
    end if;

    -- Now the item moves to in-progress (re-locks and re-validates ACTIVE
    -- inside).
    perform public.stv_action_set_item_in_progress(v_item.id, 'RETURN');

    -- Consume exceptions: coverage exception first (financial_impact 0),
    -- then the fee waiver (impact = policy fee - charged fee).
    if v_applied_id is not null then
      perform public.stv_consume_trial_item_exception(
        v_applied_id, 'return', v_action.id, v_employee);
      update public.sleep_trial_exceptions
      set financial_impact_cents = 0
      where id = v_applied_id;
      v_exc_ids := array_append(v_exc_ids, v_applied_id);
    end if;
    if v_waiver_id is not null then
      perform public.stv_consume_trial_item_exception(
        v_waiver_id, 'return', v_action.id, v_employee);
      update public.sleep_trial_exceptions
      set financial_impact_cents = greatest(v_policy_fee - v_locked_fee, 0)
      where id = v_waiver_id;
      v_exc_ids := array_append(v_exc_ids, v_waiver_id);
    end if;

    update public.sleep_trial_actions
    set status = 'COMMITTED',
        locked_evaluation = v_eval,
        locked_fee_cents = v_locked_fee,
        exception_id = coalesce(v_applied_id, v_waiver_id, exception_id),
        original_credit_cents = v_credit,
        exchange_fee_cents = v_locked_fee,
        net_cents = v_locked_fee - v_credit,
        refund_owed_cents = greatest(v_credit - v_locked_fee, 0),
        commission_basis_cents = v_locked_fee - v_credit,
        committed_by = v_employee,
        committed_at = now()
    where id = v_action.id;

    perform public.log_audit_event(
      p_company_id := v_action.company_id,
      p_entity_type := 'sleep_trial_action',
      p_entity_id := v_action.id,
      p_event_type := 'RETURN_COMMITTED',
      p_after := jsonb_build_object(
        'locked_evaluation', v_eval,
        'locked_fee_cents', v_locked_fee,
        'exception_ids', to_jsonb(v_exc_ids),
        'refund_owed_cents', greatest(v_credit - v_locked_fee, 0)),
      p_journey_id := v_action.journey_id,
      p_actor_employee_id := v_employee);

    insert into public.journey_interactions (
      journey_id, customer_id, interaction_type, channel, direction,
      topic, summary, created_by_employee_id, source_domain,
      source_record_id, is_internal
    ) values (
      v_action.journey_id, v_journey.customer_id,
      'internal_note', 'internal', 'internal', 'return_exchange',
      'Return committed by ' || coalesce(v_employee_name, 'an employee')
        || ': ' || coalesce(v_item.product_name_snapshot, 'original item'),
      v_employee, 'sleep_trial_action', v_action.id, true
    );

    return null;
  end if;

  if not public.has_permission('sleep_trial.start_exchange') then
    raise exception 'Missing permission: sleep_trial.start_exchange';
  end if;

  select e.id, e.name into v_employee, v_employee_name
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;

  -- Idempotent retry: a re-commit returns the existing child.
  if v_action.status = 'COMMITTED' then
    return v_action.child_journey_id;
  end if;
  if v_action.status <> 'DRAFT' then
    raise exception 'Only a draft can be committed (status %)', v_action.status;
  end if;
  if coalesce(v_action.replacement_variant_id,
              v_action.replacement_product_id) is null then
    raise exception 'Choose a replacement mattress before committing this exchange';
  end if;

  select * into v_item
  from public.sleep_trial_items
  where id = v_action.trial_item_id
  for update;
  if not found then
    raise exception 'Trial item not found';
  end if;
  if v_item.status <> 'ACTIVE' then
    raise exception 'This mattress''s trial is not active (status %)',
      v_item.status;
  end if;

  select * into v_journey
  from public.sleep_journeys
  where id = v_action.journey_id;

  -- Delivery needs an address BEFORE the child is inserted (the generic
  -- trigger would also block, but with a less helpful message).
  v_fulfillment := coalesce(
    v_action.fulfillment_method, 'delivery')::public.fulfillment_type;
  if v_fulfillment = 'delivery'
     and not exists (
       select 1 from public.customers c
       where c.id = v_journey.customer_id
         and nullif(btrim(coalesce(c.street_address, '')), '') is not null) then
    raise exception 'The customer has no street address - add one or switch the replacement to pickup';
  end if;

  -- The credit is the item's recorded sale price and is required (a null
  -- basis must not read as a zero credit).
  if v_item.fee_basis_cents is null then
    raise exception 'This mattress has no recorded sale price (fee basis), so a credit amount cannot be computed';
  end if;
  -- 167: never credit more than the money actually received for this
  -- mattress.
  v_credit := least(v_item.fee_basis_cents,
    public.stv_money_received_for_item(v_item.id));

  -- Gate: evaluate before the item moves to in-progress.
  v_eval := public.stv_eval_one(v_action.trial_item_id, null);
  v_x := v_eval #> '{actions,EXCHANGE}';
  if coalesce(v_x ->> 'status', '') <> 'ELIGIBLE' then
    raise exception 'This exchange is not eligible right now: %',
      coalesce(v_x ->> 'explanation', v_x ->> 'reason_code', 'unknown reason');
  end if;

  -- The evaluator's applied exception must still be usable before it is
  -- consumed; a stale or expired approval gets a friendly refusal.
  v_applied_id := nullif(v_x ->> 'applied_exception_id', '')::uuid;
  if v_applied_id is not null then
    v_check := public.stv_validate_trial_item_exception(v_applied_id);
    if not coalesce((v_check ->> 'usable')::boolean, false) then
      raise exception 'The approval covering this exchange is no longer valid (%) - request a new approval',
        coalesce(v_check ->> 'detail', v_check ->> 'reason', 'not usable');
    end if;
  end if;

  -- Fee waiver, separate from the gate: the newest usable APPROVED
  -- FEE_WAIVER for this item + EXCHANGE sets the charged fee (0 by
  -- default, or an approved reduced amount in approved_terms.fee_cents).
  v_policy_fee := coalesce((v_x #>> '{fee,amount_cents}')::int, 0);
  v_locked_fee := v_policy_fee;
  v_waiver_id := null;
  v_waiver_fee := null;
  for v_exc in
    select e.id, e.approved_terms
    from public.sleep_trial_exceptions e
    where e.trial_item_id = v_action.trial_item_id
      and e.action = 'EXCHANGE'
      and e.exception_type::text = 'FEE_WAIVER'
      and e.status = 'APPROVED'
    order by e.decided_at desc
  loop
    v_check := public.stv_validate_trial_item_exception(v_exc.id);
    if coalesce((v_check ->> 'usable')::boolean, false) then
      v_waiver_id := v_exc.id;
      -- Approved fee terms mirror the policy fee-schedule keys: a flat
      -- amount, or percent_bp of the fee basis rounded half-up (070).
      v_waiver_fee := case
        when v_exc.approved_terms ? 'fee_amount_cents' then
          (v_exc.approved_terms ->> 'fee_amount_cents')::int
        when v_exc.approved_terms ? 'fee_flat_cents' then
          (v_exc.approved_terms ->> 'fee_flat_cents')::int
        when v_exc.approved_terms ? 'fee_percent_bp' then
          ((v_credit::bigint
            * coalesce((v_exc.approved_terms ->> 'fee_percent_bp')::int, 0)
            + 5000) / 10000)::int
        else 0 end;
      exit;
    end if;
  end loop;
  if v_waiver_id is not null then
    -- Fee never exceeds the credit, same invariant as the evaluator.
    v_locked_fee := least(greatest(v_waiver_fee, 0), v_credit);
  end if;

  -- Replacement trial: only rule NONE is supported in EB-2. Read the
  -- original item's SNAPSHOTTED resolved_terms (not live policy),
  -- indexed by exchange number; FULL_NEW / REMAINING / FIXED arrive in
  -- EB-2b.
  v_used := coalesce((v_eval #>> '{display,exchanges_used}')::int, 0);
  v_repl_entry := null;
  if v_item.resolved_terms #> '{exchange,replacement_trial}' is not null then
    select e.val into v_repl_entry
    from jsonb_array_elements(
      v_item.resolved_terms #> '{exchange,replacement_trial}') as e(val)
    where (e.val ->> 'n')::int = v_used + 1
    limit 1;
  end if;
  v_repl_rule := coalesce(v_repl_entry ->> 'rule', 'NONE');
  if v_repl_rule <> 'NONE' then
    raise exception 'This mattress''s trial policy gives the replacement a new sleep trial (rule %), which is not supported yet - this exchange cannot be committed',
      v_repl_rule;
  end if;

  -- Money (decision 2): the credit LINE is capped at the positive total
  -- so the child price never goes below zero; the remainder of the
  -- credit is refund_owed_cents.
  v_pos_total := coalesce(v_action.replacement_price_cents, 0)
                 + v_locked_fee
                 + coalesce(v_action.other_fees_cents, 0);
  v_credit_line := least(v_credit, v_pos_total);
  v_net := v_pos_total - v_credit;

  -- Child store (decision 7): the caller's active_store_id JWT claim,
  -- validated against the company; fall back to the employee's home store.
  v_active_store := null;
  begin
    v_active_store :=
      (auth.jwt() -> 'user_metadata' ->> 'active_store_id')::uuid;
  exception when others then
    v_active_store := null;
  end;
  select s.id into v_child_store
  from public.stores s
  where s.id = v_active_store
    and s.company_id = v_action.company_id;
  if v_child_store is null then
    select e.home_store_id into v_child_store
    from public.employees e
    where e.id = v_employee;
  end if;
  if v_child_store is null then
    raise exception 'Could not determine a store for the replacement journey';
  end if;

  select p.item_name into v_repl_name
  from public.products p
  where p.id = coalesce(v_action.replacement_variant_id,
                        v_action.replacement_product_id);
  if v_repl_name is null then
    raise exception 'Replacement product not found in this company';
  end if;

  -- Child: default Quoted state; same customer; committer assigned;
  -- exchange kind; parent + action links; fulfillment from the action.
  insert into public.sleep_journeys (
    customer_id,
    store_id,
    assigned_employee_id,
    product_id,
    fulfillment_type,
    parent_journey_id,
    exchange_action_id,
    sale_kind
  ) values (
    v_journey.customer_id,
    v_child_store,
    v_employee,
    coalesce(v_action.replacement_variant_id, v_action.replacement_product_id),
    v_fulfillment,
    v_action.journey_id,
    v_action.id,
    'EXCHANGE'
  ) returning id into v_child;

  -- Flagged lines in the required order. unit_price is cents / 100.0.
  -- EB-2c: exchange_line_role is the stable marker the recompute uses.
  insert into public.journey_line_items (
    journey_id, product_id, item_name, quantity, unit_price,
    trial_ineligible_reason, exchange_action_id, exchange_line_role
  ) values (
    v_child,
    coalesce(v_action.replacement_variant_id, v_action.replacement_product_id),
    v_repl_name,
    greatest(coalesce(v_action.replacement_quantity, 1), 1),
    coalesce(v_action.replacement_price_cents, 0) / 100.0,
    'EXCHANGE_NO_NEW_TRIAL',
    v_action.id,
    'replacement'
  );

  if v_locked_fee > 0 then
    insert into public.journey_line_items (
      journey_id, item_name, quantity, unit_price, exchange_action_id,
      exchange_line_role
    ) values (
      v_child, 'Exchange fee', 1, v_locked_fee / 100.0, v_action.id,
      'exchange_fee');
  end if;

  if coalesce(v_action.other_fees_cents, 0) > 0 then
    insert into public.journey_line_items (
      journey_id, item_name, quantity, unit_price, exchange_action_id,
      exchange_line_role
    ) values (
      v_child, 'Other fees', 1, v_action.other_fees_cents / 100.0,
      v_action.id, 'other_fees');
  end if;

  -- Credit LAST: the negative line lands after the positives so a
  -- zero-or-below net flips the child to Sold here.
  if v_credit_line > 0 then
    insert into public.journey_line_items (
      journey_id, item_name, quantity, unit_price, exchange_action_id,
      exchange_line_role
    ) values (
      v_child,
      'Exchange credit - ' || coalesce(v_item.product_name_snapshot, 'returned mattress'),
      1,
      -v_credit_line / 100.0,
      v_action.id,
      'credit');
  end if;

  -- Now the original item moves to in-progress (re-locks and re-validates
  -- ACTIVE inside).
  perform public.stv_action_set_item_in_progress(v_item.id, 'EXCHANGE');

  -- Consume exceptions: coverage exception first (financial_impact 0),
  -- then the fee waiver (impact = policy fee - charged fee).
  if v_applied_id is not null then
    perform public.stv_consume_trial_item_exception(
      v_applied_id, 'exchange', v_action.id, v_employee);
    update public.sleep_trial_exceptions
    set financial_impact_cents = 0
    where id = v_applied_id;
    v_exc_ids := array_append(v_exc_ids, v_applied_id);
  end if;
  if v_waiver_id is not null then
    perform public.stv_consume_trial_item_exception(
      v_waiver_id, 'exchange', v_action.id, v_employee);
    update public.sleep_trial_exceptions
    set financial_impact_cents = greatest(v_policy_fee - v_locked_fee, 0)
    where id = v_waiver_id;
    v_exc_ids := array_append(v_exc_ids, v_waiver_id);
  end if;

  update public.sleep_trial_actions
  set status = 'COMMITTED',
      locked_evaluation = v_eval,
      locked_fee_cents = v_locked_fee,
      exception_id = coalesce(v_applied_id, v_waiver_id, exception_id),
      original_credit_cents = v_credit,
      exchange_fee_cents = v_locked_fee,
      net_cents = v_net,
      refund_owed_cents = greatest(-v_net, 0),
      commission_basis_cents = v_net,
      child_journey_id = v_child,
      committed_by = v_employee,
      committed_at = now()
  where id = v_action.id;

  perform public.log_audit_event(
    p_company_id := v_action.company_id,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action.id,
    p_event_type := 'EXCHANGE_COMMITTED',
    p_after := jsonb_build_object(
      'locked_evaluation', v_eval,
      'locked_fee_cents', v_locked_fee,
      'exception_ids', to_jsonb(v_exc_ids),
      'child_journey_id', v_child,
      'net_cents', v_net,
      'refund_owed_cents', greatest(-v_net, 0)),
    p_journey_id := v_action.journey_id,
    p_actor_employee_id := v_employee);

  -- Journey Activity on both journeys (correct_trial_start pattern).
  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain,
    source_record_id, is_internal
  ) values (
    v_action.journey_id, v_journey.customer_id,
    'internal_note', 'internal', 'internal', 'return_exchange',
    'Exchange committed by ' || coalesce(v_employee_name, 'an employee')
      || ': ' || coalesce(v_item.product_name_snapshot, 'original item')
      || ' -> ' || v_repl_name,
    v_employee, 'sleep_trial_action', v_action.id, true
  );
  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain,
    source_record_id, is_internal
  ) values (
    v_child, v_journey.customer_id,
    'internal_note', 'internal', 'internal', 'return_exchange',
    'Replacement journey created by exchange (original: '
      || coalesce(v_item.product_name_snapshot, 'trial item') || ')',
    v_employee, 'sleep_trial_action', v_action.id, true
  );

  return v_child;
end;
$$;

revoke execute on function public.commit_sleep_trial_action(uuid)
  from public, anon;
grant execute on function public.commit_sleep_trial_action(uuid)
  to authenticated;
