-- PillowTop POS Phase 6b: Deposit approval requests and payment floor enforcement

create table if not exists public.deposit_approval_requests (
  id uuid primary key default gen_random_uuid(),
  request_type text not null default 'deposit_exception',
  entity_type text not null default 'journey',
  entity_id uuid not null references public.sleep_journeys (id) on delete cascade,
  requester_employee_id uuid not null references public.employees (id),
  approver_employee_id uuid references public.employees (id),
  required_deposit_amount numeric not null,
  amount_already_paid numeric not null,
  proposed_payment_amount numeric not null,
  resulting_qualifying_deposit_amount numeric not null,
  shortfall_amount numeric not null,
  journey_financial_fingerprint text not null,
  reason text not null,
  status text not null check (status in ('pending','approved','denied','expired','cancelled','consumed')),
  requested_at timestamptz not null default now(),
  decided_at timestamptz,
  expires_at timestamptz
);

create index if not exists idx_deposit_approval_requests_entity
  on public.deposit_approval_requests (entity_id);

alter table public.deposit_approval_requests enable row level security;

drop policy if exists "Deposit approval requests viewable by company employees"
  on public.deposit_approval_requests;
create policy "Deposit approval requests viewable by company employees"
  on public.deposit_approval_requests for select
  to authenticated
  using (
    public.is_journey_visible(entity_id)
  );

drop policy if exists "Deposit approval requests manageable by owner or admin"
  on public.deposit_approval_requests;
create policy "Deposit approval requests manageable by owner or admin"
  on public.deposit_approval_requests for all
  to authenticated
  using (
    exists (
      select 1
      from public.employees e
      join public.stores es on es.id = e.home_store_id
      join public.sleep_journeys sj on sj.id = deposit_approval_requests.entity_id
      join public.stores js on js.id = sj.store_id
      where e.auth_user_id = auth.uid()
        and es.company_id = js.company_id
        and e.role::text in ('owner', 'admin', 'manager')
    )
  )
  with check (
    exists (
      select 1
      from public.employees e
      join public.stores es on es.id = e.home_store_id
      join public.sleep_journeys sj on sj.id = deposit_approval_requests.entity_id
      join public.stores js on js.id = sj.store_id
      where e.auth_user_id = auth.uid()
        and es.company_id = js.company_id
        and e.role::text in ('owner', 'admin', 'manager')
    )
  );

create or replace function public.journey_financial_fingerprint(p_journey_id uuid)
returns text
language sql
stable
security invoker
set search_path = public
as $$
  select md5(sj.price::text || ':' || public.total_paid(p_journey_id)::text)
  from public.sleep_journeys sj
  where sj.id = p_journey_id;
$$;

create or replace function public.request_deposit_exception(
  p_journey_id uuid,
  p_proposed_payment_amount numeric,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_requester uuid;
  v_company_id uuid;
  v_price numeric;
  v_required numeric;
  v_paid numeric;
  v_fingerprint text;
  v_request_id uuid;
begin
  if not public.is_journey_visible(p_journey_id) then
    raise exception 'Not authorized to request an exception for this journey';
  end if;

  if p_proposed_payment_amount <= 0 then
    raise exception 'Proposed payment amount must be greater than zero';
  end if;

  select e.id, s.company_id, sj.price
  into v_requester, v_company_id, v_price
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  join public.sleep_journeys sj on sj.id = p_journey_id
  where e.auth_user_id = auth.uid();

  if v_requester is null then
    raise exception 'Employee record not found';
  end if;

  if v_price is null then
    raise exception 'Journey has no price';
  end if;

  v_required := public.calculate_required_deposit(p_journey_id);
  v_paid := public.total_paid(p_journey_id);

  if (v_paid + p_proposed_payment_amount) >= v_required then
    raise exception 'No exception needed — payment meets the required deposit';
  end if;

  v_fingerprint := public.journey_financial_fingerprint(p_journey_id);

  insert into public.deposit_approval_requests (
    entity_id,
    requester_employee_id,
    required_deposit_amount,
    amount_already_paid,
    proposed_payment_amount,
    resulting_qualifying_deposit_amount,
    shortfall_amount,
    journey_financial_fingerprint,
    reason,
    status
  ) values (
    p_journey_id,
    v_requester,
    v_required,
    v_paid,
    p_proposed_payment_amount,
    v_paid + p_proposed_payment_amount,
    v_required - (v_paid + p_proposed_payment_amount),
    v_fingerprint,
    p_reason,
    'pending'
  )
  returning id into v_request_id;

  return v_request_id;
end;
$$;

create or replace function public.approve_deposit_exception(p_request_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.deposit_approval_requests%rowtype;
  v_approver uuid;
  v_company_id uuid;
begin
  select *
  into v_request
  from public.deposit_approval_requests
  where id = p_request_id;

  if v_request.id is null then
    raise exception 'Approval request not found';
  end if;

  if v_request.status <> 'pending' then
    raise exception 'Only pending requests may be approved';
  end if;

  select e.id, s.company_id
  into v_approver, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid();

  if v_approver is null or v_approver = v_request.requester_employee_id then
    raise exception 'Requester cannot approve their own request';
  end if;

  if not exists (
    select 1
    from public.sleep_journeys sj
    join public.stores js on js.id = sj.store_id
    where sj.id = v_request.entity_id
      and js.company_id = v_company_id
  ) then
    raise exception 'Not authorized to approve this request';
  end if;

  if not exists (
    select 1
    from public.employees
    where id = v_approver
      and role::text in ('owner', 'admin', 'manager')
  ) then
    raise exception 'Only owner, admin, or manager may approve';
  end if;

  update public.deposit_approval_requests
  set status = 'approved',
      approver_employee_id = v_approver,
      decided_at = now()
  where id = p_request_id;

  return p_request_id;
end;
$$;

create or replace function public.deny_deposit_exception(p_request_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.deposit_approval_requests%rowtype;
  v_denier uuid;
  v_company_id uuid;
begin
  select *
  into v_request
  from public.deposit_approval_requests
  where id = p_request_id;

  if v_request.id is null then
    raise exception 'Approval request not found';
  end if;

  if v_request.status <> 'pending' then
    raise exception 'Only pending requests may be denied';
  end if;

  select e.id, s.company_id
  into v_denier, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid();

  if v_denier is null or v_denier = v_request.requester_employee_id then
    raise exception 'Requester cannot deny their own request';
  end if;

  if not exists (
    select 1
    from public.sleep_journeys sj
    join public.stores js on js.id = sj.store_id
    where sj.id = v_request.entity_id
      and js.company_id = v_company_id
  ) then
    raise exception 'Not authorized to deny this request';
  end if;

  if not exists (
    select 1
    from public.employees
    where id = v_denier
      and role::text in ('owner', 'admin', 'manager')
  ) then
    raise exception 'Only owner, admin, or manager may deny';
  end if;

  update public.deposit_approval_requests
  set status = 'denied',
      approver_employee_id = v_denier,
      decided_at = now()
  where id = p_request_id;

  return p_request_id;
end;
$$;

drop function if exists public.record_payment_event(uuid, jsonb, text, text, text);
create or replace function public.record_payment_event(
  p_journey_id uuid,
  p_event_data jsonb,
  p_idempotency_key text,
  p_outcome text,
  p_actor_id text default 'system',
  p_deposit_approval_id uuid default null
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
  v_required numeric;
  v_fingerprint text;
  v_approval_status text;
  v_approval_min numeric;
  v_approval_fingerprint text;
  v_approval_journey uuid;
  v_consumed_exists boolean;
begin
  v_outcome := p_outcome::public.payment_outcome;
  v_amount := coalesce((p_event_data->>'amount')::numeric, 0);

  if v_amount <= 0 then
    raise exception 'Payment amount must be greater than zero';
  end if;

  if not public.is_journey_visible(p_journey_id) then
    raise exception 'Not authorized to record a payment for this journey';
  end if;

  select id into existing_id
  from public.journey_events
  where idempotency_key = p_idempotency_key;

  if existing_id is not null then
    return existing_id;
  end if;

  select id into unresolved_unknown
  from public.journey_events
  where journey_id = p_journey_id
    and event_type in ('deposit_received', 'payment_completed')
    and outcome = 'UNKNOWN'
  limit 1;

  if unresolved_unknown is not null then
    raise exception 'This order has an unresolved payment. Reconcile it before recording a new payment.';
  end if;

  v_required := public.calculate_required_deposit(p_journey_id);
  v_running := public.total_paid(p_journey_id);

  if p_deposit_approval_id is not null then
    v_fingerprint := public.journey_financial_fingerprint(p_journey_id);

    with consumed as (
      update public.deposit_approval_requests
      set status = 'consumed'
      where id = p_deposit_approval_id
        and entity_id = p_journey_id
        and status = 'approved'
        and journey_financial_fingerprint = v_fingerprint
      returning proposed_payment_amount, journey_financial_fingerprint, entity_id
    )
    select proposed_payment_amount, journey_financial_fingerprint, entity_id
    into v_approval_min, v_approval_fingerprint, v_approval_journey
    from consumed;

    if v_approval_journey is null then
      raise exception 'Deposit approval is not approved, was already consumed, the journey changed, or does not belong to this journey';
    end if;

    if v_amount < v_approval_min then
      raise exception 'Payment is below the approved minimum exception amount';
    end if;
  else
    select exists (
      select 1
      from public.deposit_approval_requests
      where entity_id = p_journey_id
        and status = 'consumed'
    ) into v_consumed_exists;

    if not v_consumed_exists and (v_running + v_amount) < v_required then
      raise exception 'Payment is below the required deposit. Request an exception first.';
    end if;
  end if;

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

  if v_outcome = 'SUCCEEDED' and v_amount > 0 then
    perform public.ensure_written_sale_established(p_journey_id, new_id);
  end if;

  return new_id;
end;
$$;

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
    perform public.ensure_written_sale_established(v_journey_id, p_event_id);
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
