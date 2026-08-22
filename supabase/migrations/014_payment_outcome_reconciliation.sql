-- PillowTop POS Phase 6a: Payment Outcome & Reconciliation Foundation
-- Adds payment outcome tracking, idempotency, and manual reconciliation.

-- 1. Payment-outcome enum (additive)
do $$
begin
  if not exists (select 1 from pg_type where typname = 'payment_outcome') then
    create type public.payment_outcome as enum (
      'SUCCEEDED', 'FAILED', 'UNKNOWN', 'CANCELLED', 'VOIDED', 'REFUNDED'
    );
  end if;
end $$;

-- 2. Extend journey_events with outcome, idempotency key, and reconciliation timestamp
alter table public.journey_events
  add column if not exists outcome public.payment_outcome,
  add column if not exists idempotency_key text,
  add column if not exists reconciled_at timestamptz;

-- 3. Reconciliation log
 create table if not exists public.payment_reconciliation_events (
  id uuid primary key default gen_random_uuid(),
  payment_id uuid not null references public.journey_events (id) on delete cascade,
  previous_outcome public.payment_outcome,
  new_outcome public.payment_outcome not null,
  previous_event_type public.journey_event_type,
  new_event_type public.journey_event_type,
  reconciled_at timestamptz not null default now(),
  reconciliation_source text not null default 'manual',
  actor_id text,
  notes text
);

create index if not exists idx_payment_reconciliation_events_payment
  on public.payment_reconciliation_events (payment_id);
create unique index if not exists idx_journey_events_idempotency
  on public.journey_events (idempotency_key);

alter table public.payment_reconciliation_events enable row level security;

drop policy if exists "Payment reconciliation events viewable by owner/admin/manager"
  on public.payment_reconciliation_events;
create policy "Payment reconciliation events viewable by owner/admin/manager"
  on public.payment_reconciliation_events for select
  to authenticated
  using (
    exists (
      select 1
      from public.employees e
      join public.stores es on es.id = e.home_store_id
      join public.journey_events je on je.id = payment_reconciliation_events.payment_id
      join public.sleep_journeys sj on sj.id = je.journey_id
      join public.stores js on js.id = sj.store_id
      where e.auth_user_id = auth.uid()
        and es.company_id = js.company_id
        and e.role::text in ('owner', 'admin', 'manager')
    )
  );

-- 4. Backfill existing payment events: before this concept existed, all recorded payments succeeded
update public.journey_events
set outcome = 'SUCCEEDED'
where outcome is null
  and event_type in ('deposit_received', 'payment_completed');

-- 5. total_paid must only count payments that actually succeeded
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
  );
end;
$$;

-- 6. Idempotent, guarded payment recording
-- Given the amount, the server decides whether this is a deposit or a completed payment.
drop function if exists public.record_payment_event(uuid, text, jsonb, text, text, text);
 create or replace function public.record_payment_event(
  p_journey_id uuid,
  p_event_data jsonb,
  p_idempotency_key text,
  p_outcome text,
  p_actor_id text default 'system'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  existing_id uuid;
  unresolved_unknown uuid;
  new_id uuid;
  v_outcome public.payment_outcome;
  v_event_type public.journey_event_type;
  v_amount numeric;
  v_price numeric;
  v_running numeric;
  v_total numeric;
begin
  v_outcome := p_outcome::public.payment_outcome;
  v_amount := coalesce((p_event_data->>'amount')::numeric, 0);

  if v_amount <= 0 then
    raise exception 'Payment amount must be greater than zero';
  end if;

  if not public.is_journey_visible(p_journey_id) then
    raise exception 'Not authorized to record a payment for this journey';
  end if;

  -- idempotency: return the existing payment event for this attempt
  select id into existing_id
  from public.journey_events
  where idempotency_key = p_idempotency_key;

  if existing_id is not null then
    return existing_id;
  end if;

  -- do not allow a new payment while this journey has an unresolved UNKNOWN payment
  select id into unresolved_unknown
  from public.journey_events
  where journey_id = p_journey_id
    and event_type in ('deposit_received', 'payment_completed')
    and outcome = 'UNKNOWN'
  limit 1;

  if unresolved_unknown is not null then
    raise exception 'This order has an unresolved payment. Reconcile it before recording a new payment.';
  end if;

  v_running := public.total_paid(p_journey_id);
  select price into v_price
  from public.sleep_journeys
  where id = p_journey_id;
  v_total := v_running + v_amount;

  if v_total >= v_price then
    v_event_type := 'payment_completed';
  else
    v_event_type := 'deposit_received';
  end if;

  insert into public.journey_events (
    journey_id,
    event_type,
    event_data,
    triggered_by,
    outcome,
    idempotency_key
  ) values (
    p_journey_id,
    v_event_type,
    p_event_data,
    p_actor_id,
    v_outcome,
    p_idempotency_key
  )
  returning id into new_id;

  return new_id;
end;
$$;

-- 7. Manual reconciliation to SUCCEEDED/FAILED with idempotency and logging
-- When reconciling to SUCCEEDED, the event_type is recomputed from the live balance
-- so a payment that was provisional when first recorded is classified correctly.
 create or replace function public.reconcile_payment_event(
  p_event_id uuid,
  p_new_outcome text,
  p_source text default 'manual',
  p_actor_id text default 'system',
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_current public.payment_outcome;
  v_current_event_type public.journey_event_type;
  v_journey_id uuid;
  v_event_data jsonb;
  v_created_at timestamptz;
  v_log_id uuid;
  v_new public.payment_outcome;
  v_new_event_type public.journey_event_type;
  v_price numeric;
  v_amount numeric;
  v_running numeric;
  v_total numeric;
  v_emp_id uuid;
  v_store_rec public.stores%rowtype;
  v_follow_up_due timestamptz;
  v_max_due timestamptz;
begin
  select je.outcome, je.event_type, je.journey_id, je.event_data, je.created_at
  into v_current, v_current_event_type, v_journey_id, v_event_data, v_created_at
  from public.journey_events je
  where je.id = p_event_id;

  if v_current is null then
    raise exception 'Payment event not found';
  end if;

  if not exists (
    select 1
    from public.employees e
    join public.stores es on es.id = e.home_store_id
    join public.sleep_journeys sj on sj.id = v_journey_id
    join public.stores js on js.id = sj.store_id
    where e.auth_user_id = auth.uid()
      and es.company_id = js.company_id
      and e.role::text in ('owner', 'admin', 'manager')
  ) then
    raise exception 'Only owner, admin, or manager may reconcile this payment';
  end if;

  select id into v_emp_id
  from public.employees
  where auth_user_id = auth.uid();

  v_new := p_new_outcome::public.payment_outcome;
  v_new_event_type := v_current_event_type;

  if v_current = v_new then
    -- already reconciled; log the repeated request but do not re-apply
    insert into public.payment_reconciliation_events (
      payment_id, previous_outcome, new_outcome,
      previous_event_type, new_event_type,
      reconciliation_source, actor_id, notes
    ) values (
      p_event_id, v_current, v_new,
      v_current_event_type, v_new_event_type,
      p_source, p_actor_id, p_notes
    )
    returning id into v_log_id;
    return p_event_id;
  end if;

  if v_new = 'SUCCEEDED' then
    v_amount := coalesce((v_event_data->>'amount')::numeric, 0);
    v_running := public.total_paid(v_journey_id);
    select price into v_price
    from public.sleep_journeys
    where id = v_journey_id;
    v_total := v_running + v_amount;

    if v_total >= v_price then
      v_new_event_type := 'payment_completed';
    else
      v_new_event_type := 'deposit_received';
    end if;
  end if;

  update public.journey_events
  set outcome = v_new,
      event_type = v_new_event_type,
      reconciled_at = now()
  where id = p_event_id;

  insert into public.payment_reconciliation_events (
    payment_id, previous_outcome, new_outcome,
    previous_event_type, new_event_type,
    reconciliation_source, actor_id, notes
  ) values (
    p_event_id, v_current, v_new,
    v_current_event_type, v_new_event_type,
    p_source, p_actor_id, p_notes
  )
  returning id into v_log_id;

  if v_new = 'SUCCEEDED' then
    perform public.reevaluate_journey_balance(v_journey_id);

    if v_new_event_type = 'payment_completed' then
      update public.follow_ups
      set completed_at = now()
      where journey_id = v_journey_id
        and completed_at is null;
    elsif v_new_event_type = 'deposit_received' then
      select * into v_store_rec
      from public.stores
      where id = (select store_id from public.sleep_journeys where id = v_journey_id);

      v_follow_up_due := v_created_at + (v_store_rec.deposit_follow_up_default_days || ' days')::interval;
      v_max_due := v_created_at + (v_store_rec.deposit_follow_up_max_days || ' days')::interval;

      if v_event_data->>'follow_up_due_at' is not null then
        begin
          v_follow_up_due := (v_event_data->>'follow_up_due_at')::timestamptz;
        exception when others then
          v_follow_up_due := v_created_at + (v_store_rec.deposit_follow_up_default_days || ' days')::interval;
        end;

        if v_follow_up_due > v_max_due then
          v_follow_up_due := v_max_due;
        end if;
        if v_follow_up_due < v_created_at then
          v_follow_up_due := v_created_at;
        end if;
      end if;

      insert into public.follow_ups (journey_id, employee_id, type, due_at, notes)
      values (
        v_journey_id,
        v_emp_id,
        'deposit',
        v_follow_up_due,
        'Deposit follow-up: balance due'
      );
    end if;
  end if;

  return p_event_id;
end;
$$;
