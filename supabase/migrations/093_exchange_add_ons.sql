-- 093_exchange_add_ons.sql
--
-- EB-2c: add-ons on an exchange child that absorb the remaining credit.
--
-- Plain English: a customer returns a mattress with $200 of credit and
-- takes a cheaper replacement; $200 would be refunded. If they also buy a
-- $50 protector at the counter, the $50 comes out of the credit and the
-- refund drops to $150. Today no line can be added to an exchange child at
-- all (the INSERT policy refuses every insert on it and the order card
-- hides its controls). This migration unlocks ordinary lines on an open
-- exchange child and keeps the credit line truthful by resizing it to
-- least(original_credit, positive lines) on every change, so the invariant
-- "journey price = sum of its lines" holds for exchange children too.
--
-- Sections:
--   A. journey_line_items.exchange_line_role + commit stamping + backfill
--   B. exchange_child_open_for_lines + rewritten line policies
--   C. exchange_line_guard BEFORE trigger (friendly refusals + value guard)
--   D. sync_journey_price prologue: resize credit, then recompute the
--      action's net/refund/commission from the child's lines
--   E. get_exchange_action: child_overpaid_cents + add_ons_total_cents
--
-- Design B (locked): the credit line itself resizes. No price floor, no
-- change to "price = sum of lines". All readers of refund_owed_cents keep
-- working because only the writer changes.

-- ============================================================================
-- A. exchange_line_role — a stable marker for the flagged lines
--
-- 'replacement' | 'exchange_fee' | 'other_fees' | 'credit'; null means an
-- ordinary line (including add-ons). The recompute identifies the credit
-- line by this role, never by name.
-- ============================================================================

alter table public.journey_line_items
  add column if not exists exchange_line_role text;

alter table public.journey_line_items
  drop constraint if exists journey_line_items_exchange_line_role_check;
alter table public.journey_line_items
  add constraint journey_line_items_exchange_line_role_check
  check (exchange_line_role in
    ('replacement','exchange_fee','other_fees','credit'));

-- commit_sleep_trial_action: 088 body verbatim, plus exchange_line_role on
-- each line it inserts (replacement / exchange_fee / other_fees / credit).
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

  if v_action.action = 'RETURN' then
    raise exception 'Returns are not enabled yet';
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
    raise exception 'The customer has no street address — add one or switch the replacement to pickup';
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
      raise exception 'The approval covering this exchange is no longer valid (%) — request a new approval',
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
    raise exception 'This mattress''s trial policy gives the replacement a new sleep trial (rule %), which is not supported yet — this exchange cannot be committed',
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
      'Exchange credit — ' || coalesce(v_item.product_name_snapshot, 'returned mattress'),
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
      || ' → ' || v_repl_name,
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

-- Backfill roles on exchange-flagged lines committed before this migration.
-- 088 inserts in a fixed order (replacement, fee, other fees, credit), so:
--   product-backed flagged line  -> 'replacement'
--   negative flagged line        -> 'credit'
--   positive no-product line     -> match cents to the action's fee columns;
--                                   anything left is fee-then-other by
--                                   created_at (the 088 insert order).
update public.journey_line_items
set exchange_line_role = 'credit'
where exchange_action_id is not null
  and exchange_line_role is null
  and unit_price < 0;

update public.journey_line_items
set exchange_line_role = 'replacement'
where exchange_action_id is not null
  and exchange_line_role is null
  and product_id is not null;

update public.journey_line_items jli
set exchange_line_role = 'exchange_fee'
from public.sleep_trial_actions a
where jli.exchange_action_id = a.id
  and jli.exchange_line_role is null
  and coalesce(a.exchange_fee_cents, 0) > 0
  and round(jli.unit_price * 100) = a.exchange_fee_cents;

update public.journey_line_items jli
set exchange_line_role = 'other_fees'
from public.sleep_trial_actions a
where jli.exchange_action_id = a.id
  and jli.exchange_line_role is null
  and coalesce(a.other_fees_cents, 0) > 0
  and round(jli.unit_price * 100) = a.other_fees_cents;

-- Positional fallback for anything the amount match missed: the first
-- remaining positive no-product line is the fee when the action has one,
-- everything else is other_fees (the 088 insert order is fixed).
update public.journey_line_items jli
set exchange_line_role = rem.role
from (
  select l.id,
         case
           when row_number() over (
                  partition by l.exchange_action_id
                  order by l.created_at) = 1
                and coalesce(a.exchange_fee_cents, 0) > 0
             then 'exchange_fee'
           else 'other_fees'
         end as role
  from public.journey_line_items l
  join public.sleep_trial_actions a on a.id = l.exchange_action_id
  where l.exchange_action_id is not null
    and l.exchange_line_role is null
) rem
where jli.id = rem.id;

do $$
declare
  v_row record;
begin
  for v_row in
    select jli.id, jli.exchange_action_id, jli.item_name, jli.unit_price
    from public.journey_line_items jli
    where jli.exchange_action_id is not null
      and jli.exchange_line_role is null
  loop
    raise notice
      'Unclassified exchange line % on action % (% @ %)',
      v_row.id, v_row.exchange_action_id, v_row.item_name, v_row.unit_price;
  end loop;
end $$;

-- ============================================================================
-- B. Open-for-lines helper + rewritten line policies
--
-- exchange_child_open_for_lines answers "may ordinary lines change on this
-- journey?": true for every non-exchange journey, and for an exchange
-- child exactly while its action is COMMITTED and no refund has been
-- recorded. A recorded refund is a historical fact — changing the order
-- underneath it would silently rewrite what was owed, so that one case
-- stays a block (void the refund first).
-- ============================================================================

create or replace function public.exchange_child_open_for_lines(
  p_journey_id uuid
)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_open boolean;
begin
  select
    (sj.exchange_action_id is null)
    or (a.status = 'COMMITTED' and a.refund_recorded_at is null)
  into v_open
  from public.sleep_journeys sj
  left join public.sleep_trial_actions a on a.id = sj.exchange_action_id
  where sj.id = p_journey_id;
  return coalesce(v_open, false);
end;
$$;

revoke execute on function public.exchange_child_open_for_lines(uuid)
  from public, anon;
grant execute on function public.exchange_child_open_for_lines(uuid)
  to authenticated;

-- The exchange_action_id is null clauses are kept verbatim so a client can
-- never set or clear the exchange flag on a line. The only change vs 088:
-- "never insert on an exchange child" becomes "ordinary lines allowed while
-- the exchange is open". Non-exchange journeys are unaffected.
drop policy if exists "Journey line items insertable by authenticated users" on public.journey_line_items;
create policy "Journey line items insertable by authenticated users"
  on public.journey_line_items for insert
  to authenticated
  with check (
    public.is_journey_visible(journey_id)
    and exchange_action_id is null
    and public.exchange_child_open_for_lines(journey_id)
  );

drop policy if exists "Journey line items updatable by authenticated users" on public.journey_line_items;
create policy "Journey line items updatable by authenticated users"
  on public.journey_line_items for update
  to authenticated
  using (
    public.is_journey_visible(journey_id)
    and exchange_action_id is null
    and public.exchange_child_open_for_lines(journey_id)
  )
  with check (
    public.is_journey_visible(journey_id)
    and exchange_action_id is null
    and public.exchange_child_open_for_lines(journey_id)
  );

drop policy if exists "Journey line items deletable by authenticated users" on public.journey_line_items;
create policy "Journey line items deletable by authenticated users"
  on public.journey_line_items for delete
  to authenticated
  using (
    public.is_journey_visible(journey_id)
    and exchange_action_id is null
    and public.exchange_child_open_for_lines(journey_id)
  );

-- ============================================================================
-- C. exchange_line_guard — plain-English refusals + the value guard
--
-- RLS violations surface as a generic policy error; this BEFORE trigger
-- gives staff a readable reason instead. It only acts on non-flagged lines
-- that sit on an exchange child (flagged rows are written by the exchange
-- RPCs and pass straight through; the credit line's own update inside
-- sync_journey_price is flagged, so it is exempt).
--
-- Value guard: an add-on's unit_price must be >= 0 and quantity > 0. A
-- negative add-on would shrink the credit line and manufacture a refund.
-- ============================================================================

create or replace function public.exchange_line_guard()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_xid uuid;
  v_status text;
  v_refund_at timestamptz;
begin
  if coalesce(new.exchange_action_id, old.exchange_action_id) is not null then
    return coalesce(new, old);
  end if;

  select sj.exchange_action_id into v_xid
  from public.sleep_journeys sj
  where sj.id = coalesce(new.journey_id, old.journey_id);
  if v_xid is null then
    return coalesce(new, old);
  end if;

  -- System metadata writes pass even on a closed/refunded exchange: the
  -- delivery provisioning path (069/076) stamps trial_ineligible_reason on
  -- lines at delivery time, which must not be refused. Same carve-out as
  -- journey_line_items_delivered_lock: every business field unchanged.
  if tg_op = 'UPDATE'
     and new.journey_id = old.journey_id
     and new.product_id is not distinct from old.product_id
     and new.item_name is not distinct from old.item_name
     and new.quantity is not distinct from old.quantity
     and new.unit_price is not distinct from old.unit_price
     and new.fulfillment_type_override is not distinct from old.fulfillment_type_override
     and new.pickup_location_id is not distinct from old.pickup_location_id
     and new.pair_group_id is not distinct from old.pair_group_id
     and new.sold_condition is not distinct from old.sold_condition
     and new.exchange_action_id is not distinct from old.exchange_action_id
     and new.exchange_line_role is not distinct from old.exchange_line_role
  then
    return new;
  end if;

  select a.status, a.refund_recorded_at into v_status, v_refund_at
  from public.sleep_trial_actions a
  where a.id = v_xid;

  if v_status is distinct from 'COMMITTED' then
    raise exception 'This exchange is no longer open — its lines cannot be changed';
  end if;
  if v_refund_at is not null then
    raise exception 'A refund was already recorded. Void it first if the order needs to change.';
  end if;

  if tg_op in ('INSERT', 'UPDATE')
     and (new.unit_price < 0 or new.quantity <= 0) then
    raise exception 'Add-on items must have a non-negative price and a quantity of at least 1';
  end if;

  return coalesce(new, old);
end;
$$;

revoke execute on function public.exchange_line_guard()
  from public, anon, authenticated;

drop trigger if exists exchange_line_guard on public.journey_line_items;
create trigger exchange_line_guard
  before insert or update or delete on public.journey_line_items
  for each row
  execute function public.exchange_line_guard();

-- ============================================================================
-- D. sync_journey_price — resize the credit line BEFORE the price is summed
--
-- Design B. The prologue runs inside the existing trigger because that is
-- the only point guaranteed to precede the price math: a separate AFTER
-- trigger would fire alphabetically AFTER sync_journey_price, letting the
-- price go positive first — a Sold->Quoted flip that emits
-- line_items_changed_balance_due and releases the mattress reservation
-- even when the add-on is fully absorbed. A BEFORE trigger is wrong for
-- the symmetric reason: on a delete the credit would shrink while the
-- add-on was still counted.
--
-- Guard chain, in order:
--   1. the changed row must be non-flagged (its exchange_action_id null) —
--      the credit line's own UPDATE carries the flag, so the resize never
--      re-enters itself;
--   2. the journey must be an exchange child;
--   3. the action must be COMMITTED with no recorded refund — a cancelled,
--      completed or refunded exchange's figures are historical fact.
--
-- Locks: the journey advisory lock first, then FOR UPDATE on the action
-- row — the canonical order — so two simultaneous line edits serialize.
-- ============================================================================

create or replace function public.sync_journey_price()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  v_journey_id uuid;
  v_total numeric;
  v_first_item_name text;
  v_item_count integer;
  v_summary text;
  v_event_type public.journey_event_type;
  v_event_data jsonb;
  v_emp_id text;
  v_current_state public.journey_state;
  v_override_changed boolean := false;
  -- EB-2c prologue locals
  v_ex_action_id uuid;
  v_ex_action public.sleep_trial_actions%rowtype;
  v_pos_cents integer;
  v_credit_cents integer;
  v_net_cents integer;
  v_new_refund integer;
  v_owed_before integer;
  v_owed_after integer;
  v_actor uuid;
  v_customer uuid;
  v_cause text;
  v_verb text;
  v_money_detail text;
begin
  v_journey_id := coalesce(new.journey_id, old.journey_id);

  select id::text into v_emp_id
  from public.employees
  where auth_user_id = auth.uid();

  -- EB-2c prologue (Design B): resize the exchange credit line BEFORE the
  -- price is summed, so an add-on fully absorbed by credit never produces
  -- a positive price — no Sold->Quoted flip, no reservation release. Runs
  -- only for a non-flagged line on an exchange child whose action is still
  -- COMMITTED with no recorded refund. The credit UPDATE re-enters this
  -- trigger with a flagged row; the first guard skips the prologue, so
  -- there is no recursion and no event storm.
  if coalesce(new.exchange_action_id, old.exchange_action_id) is null then
    select sj.exchange_action_id into v_ex_action_id
    from public.sleep_journeys sj
    where sj.id = v_journey_id;

    if v_ex_action_id is not null then
      perform pg_advisory_xact_lock(
        hashtextextended(v_journey_id::text, 7137));

      select a.* into v_ex_action
      from public.sleep_trial_actions a
      where a.id = v_ex_action_id
      for update;

      if v_ex_action.status = 'COMMITTED'
         and v_ex_action.refund_recorded_at is null then

        -- Positive total in cents: every non-credit line — replacement,
        -- fees and all ordinary add-ons.
        select coalesce(
                 round(sum(jli.quantity * jli.unit_price) * 100)::int, 0)
        into v_pos_cents
        from public.journey_line_items jli
        where jli.journey_id = v_journey_id
          and jli.exchange_line_role is distinct from 'credit';

        v_credit_cents := least(
          coalesce(v_ex_action.original_credit_cents, 0), v_pos_cents);

        -- Resize the credit line only when it differs. This UPDATE fires
        -- this trigger again for the flagged credit row; the guard above
        -- returns before the prologue, so the inner pass is a normal
        -- price/balance/inventory evaluation on the post-resize lines.
        update public.journey_line_items
        set unit_price = -v_credit_cents / 100.0,
            updated_at = now()
        where journey_id = v_journey_id
          and exchange_line_role = 'credit'
          and unit_price is distinct from (-v_credit_cents / 100.0);

        v_net_cents := v_pos_cents
                       - coalesce(v_ex_action.original_credit_cents, 0);
        v_new_refund := greatest(-v_net_cents, 0);

        if v_net_cents is distinct from v_ex_action.net_cents
           or v_new_refund is distinct from v_ex_action.refund_owed_cents then
          v_owed_before := greatest(coalesce(v_ex_action.net_cents, 0), 0);
          v_owed_after := greatest(v_net_cents, 0);
          v_cause := coalesce(new.item_name, old.item_name, 'An item');
          if tg_op = 'INSERT' then
            v_verb := ' added. ';
          elsif tg_op = 'DELETE' then
            v_verb := ' removed. ';
          else
            v_verb := ' changed. ';
          end if;

          select e.id into v_actor
          from public.employees e
          where e.auth_user_id = auth.uid();
          select sj.customer_id into v_customer
          from public.sleep_journeys sj
          where sj.id = v_journey_id;

          update public.sleep_trial_actions
          set net_cents = v_net_cents,
              refund_owed_cents = v_new_refund,
              commission_basis_cents = v_net_cents
          where id = v_ex_action.id;

          perform public.log_audit_event(
            p_company_id := v_ex_action.company_id,
            p_entity_type := 'sleep_trial_action',
            p_entity_id := v_ex_action.id,
            p_event_type := 'EXCHANGE_MONEY_RECALCULATED',
            p_before := jsonb_build_object(
              'net_cents', v_ex_action.net_cents,
              'refund_owed_cents', v_ex_action.refund_owed_cents),
            p_after := jsonb_build_object(
              'net_cents', v_net_cents,
              'refund_owed_cents', v_new_refund,
              'cause', v_cause),
            p_journey_id := v_ex_action.journey_id,
            p_actor_employee_id := v_actor);

          v_money_detail := '';
          if v_new_refund is distinct from v_ex_action.refund_owed_cents then
            v_money_detail := v_money_detail
              || 'Refund owed to customer changed from $'
              || to_char(coalesce(v_ex_action.refund_owed_cents, 0) / 100.0,
                         'FM999999990.00')
              || ' to $'
              || to_char(v_new_refund / 100.0, 'FM999999990.00')
              || '.';
          end if;
          if v_owed_after is distinct from v_owed_before then
            v_money_detail := v_money_detail
              || ' Customer now owes $'
              || to_char(v_owed_after / 100.0, 'FM999999990.00')
              || ' (was $'
              || to_char(v_owed_before / 100.0, 'FM999999990.00')
              || ').';
          end if;

          insert into public.journey_interactions (
            journey_id, customer_id, interaction_type, channel, direction,
            topic, summary, created_by_employee_id, source_domain,
            source_record_id, is_internal
          ) values (
            v_journey_id, v_customer,
            'internal_note', 'internal', 'internal', 'return_exchange',
            v_cause || v_verb || btrim(v_money_detail),
            v_actor, 'sleep_trial_action', v_ex_action.id, true
          );

          insert into public.journey_interactions (
            journey_id, customer_id, interaction_type, channel, direction,
            topic, summary, created_by_employee_id, source_domain,
            source_record_id, is_internal
          ) values (
            v_ex_action.journey_id, v_customer,
            'internal_note', 'internal', 'internal', 'return_exchange',
            'Exchange order changed — ' || btrim(v_money_detail),
            v_actor, 'sleep_trial_action', v_ex_action.id, true
          );
        end if;
      end if;
    end if;
  end if;
  -- /EB-2c prologue --------------------------------------------------------

  select coalesce(sum(quantity * unit_price), 0)
  into v_total
  from public.journey_line_items
  where journey_id = v_journey_id;

  select count(*) into v_item_count
  from public.journey_line_items
  where journey_id = v_journey_id;

  select item_name into v_first_item_name
  from public.journey_line_items
  where journey_id = v_journey_id
  order by created_at
  limit 1;

  if v_item_count > 0 then
    v_summary := v_first_item_name;
    if v_item_count > 1 then
      v_summary := v_summary || ' + ' || (v_item_count - 1) || ' more';
    end if;
  end if;

  update public.sleep_journeys
  set price = v_total,
      product_summary = coalesce(v_summary, product_summary),
      updated_at = now()
  where id = v_journey_id;

  v_event_type := case tg_op
    when 'INSERT' then 'line_item_added'
    when 'UPDATE' then 'line_item_updated'
    when 'DELETE' then 'line_item_removed'
  end;

  if tg_op = 'DELETE' then
    v_event_data := jsonb_build_object(
      'product_id', old.product_id,
      'item_name', old.item_name,
      'quantity', old.quantity,
      'unit_price', old.unit_price
    );
  else
    v_event_data := jsonb_build_object(
      'product_id', new.product_id,
      'item_name', new.item_name,
      'quantity', new.quantity,
      'unit_price', new.unit_price
    );
  end if;

  insert into public.journey_events (journey_id, event_type, event_data, triggered_by)
  values (v_journey_id, v_event_type, v_event_data, coalesce(v_emp_id, 'system'));

  -- This handles every price-affecting change, including a downstream
  -- Ready-to-Schedule/Sold Journey becoming underpaid.
  perform public.reevaluate_journey_balance(v_journey_id);

  -- Fulfillment-field changes require a fresh sourcing snapshot. This also
  -- deliberately rebuilds requirements whose effective location is unchanged;
  -- release-then-re-reserve is safe in this transaction and simplifies code.
  if tg_op = 'UPDATE' then
    v_override_changed :=
      new.fulfillment_type_override is distinct from old.fulfillment_type_override
      or new.pickup_location_id is distinct from old.pickup_location_id;
  end if;

  if v_override_changed then
    select current_state into v_current_state
    from public.sleep_journeys
    where id = v_journey_id;

    if v_current_state in (
      'Sold'::public.journey_state,
      'Waiting for Inventory'::public.journey_state,
      'Ready to Schedule'::public.journey_state
    ) then
      perform public.supersede_journey_inventory_reservations(v_journey_id);
    end if;
  end if;

  -- Unconditional: evaluate_journey_inventory() owns the reservation-policy
  -- decision, including order_creation reservations before full payment.
  perform public.evaluate_journey_inventory(v_journey_id);

  return coalesce(new, old);
end;
$$;

-- ============================================================================
-- E. get_exchange_action — 091 body verbatim plus two additions:
--    child_overpaid_cents (max(0, paid - price), for the overpaid banner)
--    and add_ons_total_cents (sum of non-flagged lines on the child).
--    No existing key changes.
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
    'committed_by_name', v_committed_by_name,
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
        'by', v_money_by_name)),
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

-- ============================================================================
-- Verification: every exchange-flagged line must carry a role. Expected
-- result after the backfill above: zero rows. Anything listed here is a
-- flagged line the classifier could not place — review it by hand.
-- ============================================================================

select jli.id as line_item_id,
       jli.exchange_action_id,
       jli.journey_id,
       jli.item_name,
       jli.unit_price,
       jli.created_at
from public.journey_line_items jli
where jli.exchange_action_id is not null
  and jli.exchange_line_role is null
order by jli.created_at;
