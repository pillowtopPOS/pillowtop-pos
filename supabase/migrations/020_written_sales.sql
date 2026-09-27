-- PillowTop POS Phase 6b: Written Sales ledger and adjustments

create table if not exists public.written_sales (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.companies (id) on delete cascade,
  order_id uuid not null unique references public.sleep_journeys (id) on delete cascade,
  written_sale_at timestamptz not null default now(),
  written_business_date date not null default current_date,
  selling_store_id uuid not null references public.stores (id),
  salesperson_attribution_reference text,
  qualifying_order_amount numeric not null,
  currency text not null default 'USD',
  triggering_payment_id uuid not null references public.journey_events (id),
  correlation_id uuid not null default gen_random_uuid(),
  created_at timestamptz not null default now()
);

create table if not exists public.written_sale_adjustments (
  id uuid primary key default gen_random_uuid(),
  written_sale_id uuid not null references public.written_sales (id) on delete cascade,
  tenant_id uuid not null references public.companies (id) on delete cascade,
  order_id uuid not null references public.sleep_journeys (id) on delete cascade,
  occurred_at timestamptz not null default now(),
  adjustment_amount numeric not null,
  previous_qualifying_committed_amount numeric not null,
  new_qualifying_committed_amount numeric not null,
  adjustment_type text not null,
  adjustment_reason text,
  actor_id text,
  correlation_id uuid not null default gen_random_uuid()
);

create index if not exists idx_written_sales_order
  on public.written_sales (order_id);
create index if not exists idx_written_sales_tenant
  on public.written_sales (tenant_id);
create index if not exists idx_written_sale_adjustments_written_sale
  on public.written_sale_adjustments (written_sale_id);
create index if not exists idx_written_sale_adjustments_order
  on public.written_sale_adjustments (order_id);

alter table public.written_sales enable row level security;
alter table public.written_sale_adjustments enable row level security;

drop policy if exists "Written sales viewable by authenticated users"
  on public.written_sales;
create policy "Written sales viewable by authenticated users"
  on public.written_sales for select
  to authenticated
  using (
    public.is_store_visible(selling_store_id)
  );

drop policy if exists "Written sale adjustments viewable by authenticated users"
  on public.written_sale_adjustments;
create policy "Written sale adjustments viewable by authenticated users"
  on public.written_sale_adjustments for select
  to authenticated
  using (
    exists (
      select 1
      from public.written_sales ws
      where ws.id = written_sale_adjustments.written_sale_id
        and public.is_store_visible(ws.selling_store_id)
    )
  );

create or replace function public.ensure_written_sale_established(
  p_journey_id uuid,
  p_payment_event_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exists uuid;
  v_tenant_id uuid;
  v_store_id uuid;
  v_price numeric;
  v_actor text;
  v_created timestamptz;
  v_sale_id uuid;
begin
  select id into v_exists
  from public.written_sales
  where order_id = p_journey_id;

  if v_exists is not null then
    return v_exists;
  end if;

  select
    s.company_id,
    sj.store_id,
    sj.price,
    je.triggered_by,
    je.created_at
  into v_tenant_id, v_store_id, v_price, v_actor, v_created
  from public.sleep_journeys sj
  join public.stores s on s.id = sj.store_id
  join public.journey_events je on je.id = p_payment_event_id
  where sj.id = p_journey_id;

  if v_tenant_id is null then
    raise exception 'Journey not found';
  end if;

  if v_price is null then
    raise exception 'Journey has no price';
  end if;

  insert into public.written_sales (
    tenant_id,
    order_id,
    written_sale_at,
    written_business_date,
    selling_store_id,
    salesperson_attribution_reference,
    qualifying_order_amount,
    triggering_payment_id
  ) values (
    v_tenant_id,
    p_journey_id,
    v_created,
    v_created::date,
    v_store_id,
    v_actor,
    v_price,
    p_payment_event_id
  )
  returning id into v_sale_id;

  return v_sale_id;
end;
$$;

create or replace function public.derive_journey_state()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  target public.journey_state;
  journey_price numeric;
  paid numeric;
  new_price numeric;
  store_rec public.stores%rowtype;
  emp_id uuid;
  follow_up_due timestamptz;
  max_due timestamptz;
  cadence int;
  v_written_sale_id uuid;
  v_previous_committed numeric;
  v_new_committed numeric;
  v_adjustment numeric;
begin
  select id into emp_id
  from public.employees
  where auth_user_id = auth.uid();

  if new.event_type = 'journey_cancelled' then
    update public.sleep_journeys
    set cancelled_at = now(),
        cancelled_reason = coalesce(new.event_data->>'reason', 'No reason provided'),
        updated_at = now()
    where id = new.journey_id;

    update public.follow_ups
    set completed_at = now()
    where journey_id = new.journey_id
      and completed_at is null;

    select id into v_written_sale_id
    from public.written_sales
    where order_id = new.journey_id;

    if v_written_sale_id is not null then
      v_previous_committed := (
        select ws.qualifying_order_amount + coalesce(sum(wsa.adjustment_amount), 0)
        from public.written_sales ws
        left join public.written_sale_adjustments wsa on wsa.written_sale_id = ws.id
        where ws.id = v_written_sale_id
        group by ws.qualifying_order_amount
      );

      v_new_committed := 0;
      v_adjustment := v_new_committed - v_previous_committed;

      insert into public.written_sale_adjustments (
        written_sale_id,
        tenant_id,
        order_id,
        adjustment_amount,
        previous_qualifying_committed_amount,
        new_qualifying_committed_amount,
        adjustment_type,
        adjustment_reason,
        actor_id
      )
      select
        v_written_sale_id,
        ws.tenant_id,
        new.journey_id,
        v_adjustment,
        v_previous_committed,
        v_new_committed,
        'cancellation',
        coalesce(new.event_data->>'reason', 'No reason provided'),
        new.triggered_by
      from public.written_sales ws
      where ws.id = v_written_sale_id;
    end if;

    return new;
  end if;

  target := public.event_to_state(new.event_type);

  if target is null then
    return new;
  end if;

  if new.event_type in ('deposit_received', 'payment_completed') then
    if new.outcome = 'SUCCEEDED' then
      select price into journey_price
      from public.sleep_journeys
      where id = new.journey_id;

      paid := public.total_paid(new.journey_id);

      if journey_price is not null and paid >= journey_price then
        target := 'Sold'::public.journey_state;
      else
        target := 'Quoted'::public.journey_state;
      end if;
    else
      target := 'Quoted'::public.journey_state;
    end if;
  end if;

  if new.event_type in ('quote_created', 'quote_sent')
    and new.event_data->>'amount' ~ '^[0-9]+(\.[0-9]+)?$'
  then
    new_price := (new.event_data->>'amount')::numeric;
  end if;

  update public.sleep_journeys
  set current_state = target,
      price = coalesce(price, new_price),
      updated_at = now()
  where id = new.journey_id;

  if target = 'Sold'::public.journey_state then
    update public.follow_ups
    set completed_at = now()
    where journey_id = new.journey_id
      and completed_at is null;
  end if;

  if new.event_type = 'quote_sent' then
    select * into store_rec
    from public.stores
    where id = (select store_id from public.sleep_journeys where id = new.journey_id);

    for cadence in
      select jsonb_array_elements_text(coalesce(store_rec.quote_follow_up_cadence, '[1]'::jsonb))::int
    loop
      insert into public.follow_ups (journey_id, employee_id, type, due_at, notes)
      values (
        new.journey_id,
        emp_id,
        'quote',
        new.created_at + (cadence || ' days')::interval,
        'Quote follow-up (day ' || cadence || ')'
      );
    end loop;
  end if;

  if new.event_type = 'deposit_received' and new.outcome = 'SUCCEEDED' then
    select * into store_rec
    from public.stores
    where id = (select store_id from public.sleep_journeys where id = new.journey_id);

    follow_up_due := new.created_at + (store_rec.deposit_follow_up_default_days || ' days')::interval;
    max_due := new.created_at + (store_rec.deposit_follow_up_max_days || ' days')::interval;

    if new.event_data->>'follow_up_due_at' is not null then
      begin
        follow_up_due := (new.event_data->>'follow_up_due_at')::timestamptz;
      exception when others then
        follow_up_due := new.created_at + (store_rec.deposit_follow_up_default_days || ' days')::interval;
      end;

      if follow_up_due > max_due then
        follow_up_due := max_due;
      end if;
      if follow_up_due < new.created_at then
        follow_up_due := new.created_at;
      end if;
    end if;

    insert into public.follow_ups (journey_id, employee_id, type, due_at, notes)
    values (
      new.journey_id,
      emp_id,
      'deposit',
      follow_up_due,
      'Deposit follow-up: balance due'
    );
  end if;

  return new;
end;
$$;
