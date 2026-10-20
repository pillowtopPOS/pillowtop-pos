-- ============================================================================
-- REFUNDS-B2: commission-side refund adjustments + refunds never release
-- reservations
--
-- Two product rules, one migration:
--
--   1. Every recorded refund writes a proportional NEGATIVE row in
--      written_sale_adjustments against the order's committed amount; voiding
--      a refund writes the matching positive 'refund_reversal'. History is
--      append-only — nothing is edited or deleted. The ledger is in order
--      dollars (no commission rate is stored on a sale; the commission engine
--      applies its rate downstream to the reduced committed amount).
--      A journey whose payments bypassed record_payment_event has no
--      written_sales row — the adjustment step is skipped silently.
--
--   2. Once stock is reserved, a refund never releases it — only cancelling
--      the order or an explicit supersede does. reevaluate_journey_balance
--      gains p_release_inventory boolean default true; the refund RPCs call
--      it with false. The state flip to Quoted and the balance-due event
--      still happen — only the supersede (and its paired stale-ready-flag
--      clear) are gated.
--
-- Also: reconcile_payment_event now refuses to flip a payment to FAILED
-- while SUCCEEDED refunds point at it — voided-first ordering keeps
-- net paid from going negative.
--
-- reevaluate_journey_balance changes arity, so the old 1-arg function is
-- dropped first (the default parameter keeps every existing 1-arg call
-- site working). No EXECUTE grants existed to preserve.
-- ============================================================================

-- 1. reevaluate_journey_balance — 080 body verbatim, supersede gated --------
drop function public.reevaluate_journey_balance(uuid);

create or replace function public.reevaluate_journey_balance(
  p_journey_id uuid,
  p_release_inventory boolean default true
)
returns void language plpgsql security definer set search_path = public
as $$
declare
  v_current public.journey_state;
  v_price numeric;
  v_paid numeric;
  v_new_state public.journey_state;
  v_emp_id text;
begin
  select current_state, price into v_current, v_price
  from public.sleep_journeys where id = p_journey_id;

  if v_price is null or v_current not in (
    'Quoted'::public.journey_state,
    'Sold'::public.journey_state,
    'Waiting for Inventory'::public.journey_state,
    'Ready to Schedule'::public.journey_state
  ) then return; end if;

  -- No line items: a $0 order is not a sale and has no balance to enforce.
  -- Prevents emptying an order from flipping Quoted -> Sold via
  -- journey_updated_to_sold with price 0.
  if not exists (
    select 1 from public.journey_line_items where journey_id = p_journey_id
  ) then
    return;
  end if;

  select id::text into v_emp_id from public.employees where auth_user_id = auth.uid();
  v_paid := public.total_paid(p_journey_id);

  if v_current in (
    'Waiting for Inventory'::public.journey_state,
    'Ready to Schedule'::public.journey_state
  ) and v_paid >= v_price then return; end if;

  if v_paid >= v_price then
    v_new_state := 'Sold'::public.journey_state;
  else
    v_new_state := 'Quoted'::public.journey_state;
  end if;

  if v_new_state = v_current then
    -- A Journey already in Quoted must not retain a stale ready indicator.
    -- Gated on p_release_inventory: a refund keeps the reservation, so the
    -- ready flag remains honest and nothing is released.
    if v_new_state = 'Quoted'::public.journey_state and p_release_inventory then
      update public.sleep_journeys
      set inventory_ready_notified_at = null
      where id = p_journey_id and inventory_ready_notified_at is not null;
      perform public.supersede_journey_inventory_reservations(p_journey_id);
    end if;
    return;
  end if;

  update public.sleep_journeys
  set current_state = v_new_state,
      inventory_ready_notified_at = case
        when v_new_state = 'Quoted'::public.journey_state then null
        else inventory_ready_notified_at
      end,
      updated_at = now()
  where id = p_journey_id;

  if v_new_state = 'Sold' then
    insert into public.journey_events (journey_id, event_type, event_data, triggered_by)
    values (
      p_journey_id, 'journey_updated_to_sold',
      jsonb_build_object('total_paid', v_paid, 'price', v_price, 'balance_due', v_price - v_paid),
      coalesce(v_emp_id, 'system')
    );
  else
    insert into public.journey_events (journey_id, event_type, event_data, triggered_by)
    values (
      p_journey_id, 'line_items_changed_balance_due',
      jsonb_build_object('total_paid', v_paid, 'price', v_price, 'balance_due', v_price - v_paid),
      coalesce(v_emp_id, 'system')
    );
    -- Gated on p_release_inventory: a refund keeps the reservation.
    if p_release_inventory then
      perform public.supersede_journey_inventory_reservations(p_journey_id);
    end if;
  end if;
end;
$$;

-- 2. record_payment_refund — 097 body plus the written_sale_adjustments -----
-- insert; re-evaluates with p_release_inventory => false.

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
  v_sale_id uuid;
  v_sale_tenant uuid;
  v_prev_committed numeric;
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

  -- Written-sale ledger: the refund reduces the committed order amount by
  -- the refunded dollars, against the same written sale (so it lands on the
  -- same salesperson attribution). correlation_id links the adjustment back
  -- to the refund event; void_payment_refund writes the matching reversal.
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

  if v_sale_id is not null then
    insert into public.written_sale_adjustments (
      written_sale_id, tenant_id, order_id, adjustment_amount,
      previous_qualifying_committed_amount,
      new_qualifying_committed_amount,
      adjustment_type, adjustment_reason, actor_id, correlation_id
    ) values (
      v_sale_id, v_sale_tenant, v_payment.journey_id, -p_amount,
      v_prev_committed, v_prev_committed - p_amount,
      'refund', btrim(p_reason), auth.uid()::text, v_new_id
    );
  end if;

  -- Net paid dropped: re-run the balance and inventory evaluations. The
  -- balance re-evaluation still flips a now-underpaid journey to Quoted and
  -- logs the balance-due event, but does NOT release reservations — refunds
  -- never release stock (cancel or an explicit supersede does).
  perform public.reevaluate_journey_balance(v_payment.journey_id, false);
  perform public.evaluate_journey_inventory(v_payment.journey_id);

  return v_new_id;
end;
$$;

revoke execute on function public.record_payment_refund(uuid, numeric, text, text, text) from public, anon;
grant execute on function public.record_payment_refund(uuid, numeric, text, text, text) to authenticated;

-- 3. void_payment_refund — 097 body plus the positive reversal adjustment ---
-- (never edits the original rows) and p_release_inventory => false.

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
  v_refund_amount numeric;
  v_sale_id uuid;
  v_sale_tenant uuid;
  v_prev_committed numeric;
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

  -- Reversal adjustment: committed amount goes back up by the refunded
  -- dollars. correlation_id points at the refund event being reversed.
  v_refund_amount := coalesce((v_refund.event_data->>'amount')::numeric, 0);

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

  if v_sale_id is not null and v_refund_amount > 0 then
    insert into public.written_sale_adjustments (
      written_sale_id, tenant_id, order_id, adjustment_amount,
      previous_qualifying_committed_amount,
      new_qualifying_committed_amount,
      adjustment_type, adjustment_reason, actor_id, correlation_id
    ) values (
      v_sale_id, v_sale_tenant, v_refund.journey_id, v_refund_amount,
      v_prev_committed, v_prev_committed + v_refund_amount,
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

-- 4. reconcile_payment_event — 028 body verbatim plus one guard: a payment --
-- with SUCCEEDED refunds pointing at it cannot be flipped to FAILED (the
-- refunds would keep subtracting in total_paid and drive net paid
-- negative). Void the refunds first.

create or replace function public.reconcile_payment_event(
  p_event_id uuid, p_new_outcome text, p_source text default 'manual',
  p_actor_id text default 'system', p_notes text default null
)
returns uuid language plpgsql security definer set search_path = public
as $$
declare
  v_current public.payment_outcome; v_current_event_type public.journey_event_type;
  v_journey_id uuid; v_event_data jsonb; v_created_at timestamptz;
  v_log_id uuid; v_new public.payment_outcome; v_new_event_type public.journey_event_type;
  v_price numeric; v_amount numeric; v_running numeric; v_total numeric;
  v_emp_id uuid; v_store_rec public.stores%rowtype;
  v_follow_up_due timestamptz; v_max_due timestamptz;
begin
  select je.outcome, je.event_type, je.journey_id, je.event_data, je.created_at
  into v_current, v_current_event_type, v_journey_id, v_event_data, v_created_at
  from public.journey_events je where je.id = p_event_id;
  if v_current is null then raise exception 'Payment event not found'; end if;
  if not exists (
    select 1 from public.employees e
    join public.stores es on es.id = e.home_store_id
    join public.sleep_journeys sj on sj.id = v_journey_id
    join public.stores js on js.id = sj.store_id
    where e.auth_user_id = auth.uid() and es.company_id = js.company_id
      and e.role::text in ('owner', 'admin', 'manager')
  ) then raise exception 'Only owner, admin, or manager may reconcile this payment'; end if;
  select id into v_emp_id from public.employees where auth_user_id = auth.uid();
  v_new := p_new_outcome::public.payment_outcome;
  v_new_event_type := v_current_event_type;

  if v_current = v_new then
    insert into public.payment_reconciliation_events (
      payment_id, previous_outcome, new_outcome, previous_event_type,
      new_event_type, reconciliation_source, actor_id, notes
    ) values (p_event_id, v_current, v_new, v_current_event_type,
      v_new_event_type, p_source, p_actor_id, p_notes) returning id into v_log_id;
    return p_event_id;
  end if;

  -- Refunds recorded against this payment must be voided before it can be
  -- marked FAILED — otherwise they keep subtracting in total_paid and net
  -- paid goes negative.
  if v_new = 'FAILED' and exists (
    select 1 from public.journey_events je
    where je.journey_id = v_journey_id
      and je.event_type = 'payment_refunded'
      and je.outcome = 'SUCCEEDED'
      and je.event_data->>'refunds_payment_id' = p_event_id::text
  ) then
    raise exception 'Void the refunds on this payment first.';
  end if;

  if v_new = 'SUCCEEDED' then
    v_amount := coalesce((v_event_data->>'amount')::numeric, 0);
    v_running := public.total_paid(v_journey_id);
    select price into v_price from public.sleep_journeys where id = v_journey_id;
    v_total := v_running + v_amount;
    if v_total >= v_price then v_new_event_type := 'payment_completed';
    else v_new_event_type := 'deposit_received'; end if;
  end if;

  update public.journey_events set outcome = v_new,
    event_type = v_new_event_type, reconciled_at = now() where id = p_event_id;

  insert into public.payment_reconciliation_events (
    payment_id, previous_outcome, new_outcome, previous_event_type,
    new_event_type, reconciliation_source, actor_id, notes
  ) values (p_event_id, v_current, v_new, v_current_event_type,
    v_new_event_type, p_source, p_actor_id, p_notes) returning id into v_log_id;

  if v_new = 'SUCCEEDED' then
    perform public.ensure_written_sale_established(v_journey_id, p_event_id);
    perform public.reevaluate_journey_balance(v_journey_id);
    perform public.evaluate_journey_inventory(v_journey_id);

    if v_new_event_type = 'payment_completed' then
      update public.follow_ups set completed_at = now()
      where journey_id = v_journey_id and completed_at is null;
    elsif v_new_event_type = 'deposit_received' then
      select * into v_store_rec from public.stores
      where id = (select store_id from public.sleep_journeys where id = v_journey_id);
      v_follow_up_due := v_created_at + (v_store_rec.deposit_follow_up_default_days || ' days')::interval;
      v_max_due := v_created_at + (v_store_rec.deposit_follow_up_max_days || ' days')::interval;
      if v_event_data->>'follow_up_due_at' is not null then
        begin v_follow_up_due := (v_event_data->>'follow_up_due_at')::timestamptz;
        exception when others then
          v_follow_up_due := v_created_at + (v_store_rec.deposit_follow_up_default_days || ' days')::interval;
        end;
        if v_follow_up_due > v_max_due then v_follow_up_due := v_max_due; end if;
        if v_follow_up_due < v_created_at then v_follow_up_due := v_created_at; end if;
      end if;
      insert into public.follow_ups (journey_id, employee_id, type, due_at, notes)
      values (v_journey_id, v_emp_id, 'deposit', v_follow_up_due, 'Deposit follow-up: balance due');
    end if;
  end if;
  return p_event_id;
end;
$$;
