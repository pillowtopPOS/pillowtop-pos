-- ============================================================================
-- Migration 161 - slice 2b, part 1: enable trial mattress returns.
--
-- The sleep trial module has carried full RETURN support in the evaluator,
-- the item-status helpers and the receive/quarantine path since 087-100;
-- what was missing was the commit and complete path plus the permission.
-- This migration:
--
--   1. Grants sleep_trial.start_return to sales and employee so anyone
--      logged in may start a return (066/084 seed mechanism, backfilled).
--   2. commit_sleep_trial_action: removes the 'Returns are not enabled
--      yet' raise and adds a self-contained RETURN branch. The item moves
--      to RETURN_IN_PROGRESS, refund_owed_cents = fee_basis_cents minus
--      locked_fee_cents, action becomes COMMITTED, no child journey.
--      The EXCHANGE path below the branch is byte-for-byte unchanged.
--   3. list_open_exchange_work: lists committed RETURN actions too, with
--      action-aware milestone text and an 'action' field per row.
--   4. complete_sleep_trial_action: RETURN actions complete through the
--      same milestone order minus the replacement milestones, close the
--      item as RETURNED, and note 'Return completed'.
--   5. record_payment_refund: gains optional p_action_id. When given, the
--      action must be a COMMITTED RETURN on the same journey with no
--      refund recorded; the same transaction writes the payment_refunded
--      event as today and stamps the action's refund fields, so one call
--      satisfies the refund-first rule in complete_sleep_trial_action.
--
-- Rollback: re-run migrations 084, 093, 091, 092 and 098 function bodies.
-- ============================================================================

-- ============================================================================
-- 1. start_return for every role (084 body plus the two new grants)
-- ============================================================================

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
      -- reduce_below_committed (084): owner, manager
      ('owner',    'inventory.reduce_below_committed'),
      ('manager',  'inventory.reduce_below_committed')
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
-- 2. commit_sleep_trial_action (093 body; the RETURN raise becomes the
--    RETURN branch; everything after the branch is unchanged)
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
    v_credit := v_item.fee_basis_cents;

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
  v_credit := v_item.fee_basis_cents;

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

-- ============================================================================
-- 3. list_open_exchange_work (091 body; committed RETURN actions appear
--    with action-aware milestone text and an 'action' field)
-- ============================================================================

create or replace function public.list_open_exchange_work()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_employee public.employees%rowtype;
  v_can_complete boolean;
begin
  select * into v_employee
  from public.employees
  where auth_user_id = auth.uid()
    and is_active;
  if v_employee.id is null then
    return '[]'::jsonb;
  end if;
  v_can_complete := public.has_permission('sleep_trial.complete_exchange');

  return coalesce((
    select jsonb_agg(r.payload order by r.committed_at)
    from (
      select
        a.committed_at,
        jsonb_build_object(
          'action_id', a.id,
          'action', a.action,
          'journey_id', a.journey_id,
          'child_journey_id', a.child_journey_id,
          'customer_name',
            btrim(coalesce(c.first_name, '') || ' ' ||
                  coalesce(c.last_name, '')),
          'replacement_product_name', p.item_name,
          'committed_at', a.committed_at,
          'days_committed',
            floor(extract(epoch from (now() - a.committed_at)) / 86400)::int,
          'open_milestones', open_ms.items,
          'is_stalled',
            (a.committed_at
               < now() - make_interval(days => co.exchange_stalled_days))
            and jsonb_array_length(open_ms.items) > 0
        ) as payload
      from public.sleep_trial_actions a
      join public.sleep_journeys sj on sj.id = a.journey_id
      join public.customers c on c.id = sj.customer_id
      join public.stores s on s.id = sj.store_id
      join public.companies co on co.id = s.company_id
      left join public.products p on p.id = a.replacement_product_id
      left join public.sleep_journeys cj on cj.id = a.child_journey_id
      cross join lateral (
        select coalesce(jsonb_agg(t.m order by t.ord), '[]'::jsonb) as items
        from (
          values
            (1, 'The replacement has not been delivered yet',
                a.action = 'EXCHANGE' and a.replacement_delivered_on is null),
            (2, case when a.action = 'RETURN'
                     then 'The returned mattress has not been marked received yet'
                     else 'The original mattress has not been marked received yet'
                end,
                a.original_received_on is null),
            (3, 'The replacement still has an unpaid balance',
                a.action = 'EXCHANGE'
                  and coalesce(cj.price, 0) > 0
                  and public.total_paid(cj.id) < cj.price),
            (4, 'The owed refund has not been recorded yet',
                coalesce(a.refund_owed_cents, 0) > 0
                  and a.refund_recorded_at is null)
        ) as t(ord, m, is_open)
        where t.is_open
      ) open_ms
      where a.status = 'COMMITTED'
        and a.action in ('EXCHANGE', 'RETURN')
        and public.is_journey_visible(a.journey_id)
        and (a.created_by = v_employee.id
             or v_employee.home_store_id = sj.store_id
             or v_can_complete)
    ) r
  ), '[]'::jsonb);
end;
$$;

revoke execute on function public.list_open_exchange_work() from public, anon;
grant execute on function public.list_open_exchange_work() to authenticated;

-- ============================================================================
-- 4. complete_sleep_trial_action (092 body; RETURN actions skip the
--    replacement milestones, close the item as RETURNED and note
--    'Return completed')
-- ============================================================================

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
    raise exception 'Exchange action not found';
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
    raise exception 'Only a committed exchange can be completed (status %)',
      v_action.status;
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
-- 5. record_payment_refund (098 body plus optional p_action_id; the old
--    signature is dropped first so PostgREST sees exactly one function)
-- ============================================================================

drop function if exists public.record_payment_refund(uuid, numeric, text, text, text);

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

  -- Slice 2b: when the refund settles a committed return, the action is
  -- locked and validated here so the event and the action stamp land in
  -- one transaction. The amount itself is not checked against
  -- refund_owed_cents: the payment's refundable remainder stays the only
  -- cap, and an under- or over-refund remains a manager decision.
  if p_action_id is not null then
    select * into v_action
    from public.sleep_trial_actions
    where id = p_action_id
    for update;
    if not found then
      raise exception 'Sleep trial action not found';
    end if;
    if v_action.journey_id <> v_payment.journey_id then
      raise exception 'That return does not belong to this order';
    end if;
    if v_action.action <> 'RETURN' then
      raise exception 'Refunds can only be linked to a return action';
    end if;
    if v_action.status <> 'COMMITTED' then
      raise exception 'Only a committed return can take a refund (status %)',
        v_action.status;
    end if;
    if v_action.refund_recorded_at is not null then
      raise exception 'A refund was already recorded on this return';
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

  -- Stamp the action so the refund-first rule in
  -- complete_sleep_trial_action is satisfied by this same call.
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
      p_event_type := 'RETURN_REFUND_RECORDED',
      p_after := jsonb_build_object(
        'refund_method', p_method,
        'refund_amount_cents', round(p_amount * 100)::int,
        'refund_owed_cents', v_action.refund_owed_cents,
        'payment_refund_event_id', v_new_id,
        'refund_reference', nullif(btrim(coalesce(p_reference, '')), '')),
      p_journey_id := v_action.journey_id,
      p_actor_employee_id := v_emp_id);
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
-- 6. void_payment_refund (098 body; voiding a refund that stamped a return
--    un-stamps the action in the same transaction, and a refund that
--    already completed its return refuses to void)
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
  select id into v_emp_id from public.employees where auth_user_id = auth.uid();

  -- Slice 2b: a refund recorded through record_payment_refund with
  -- p_action_id carries 'action_id' in its event_data and stamped the
  -- action's refund fields. Voiding it must un-stamp the action so the
  -- refund milestone in complete_sleep_trial_action is unmet again. A
  -- completed return is refused: its refund is part of the close-out.
  if v_refund.event_data ? 'action_id' then
    select * into v_action
    from public.sleep_trial_actions
    where id = (v_refund.event_data ->> 'action_id')::uuid
    for update;
    if found then
      if v_action.status = 'COMPLETED' then
        raise exception 'This refund closed a completed return and cannot be voided here';
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
          p_event_type := 'RETURN_REFUND_VOIDED',
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
