-- PillowTop POS Phase 2: Board simplification, partial-payment balance, follow-ups, and opportunities

-- 1. New event for quote send (legacy quote_created is untouched)
ALTER TYPE public.journey_event_type ADD VALUE IF NOT EXISTS 'quote_sent';

-- 2. Opportunities (pre-purchase leads)
create table if not exists public.opportunities (
  id uuid primary key default gen_random_uuid(),
  store_id uuid not null references public.stores (id) on delete restrict,
  assigned_employee_id uuid references public.employees (id) on delete set null,
  first_name text not null,
  last_name text not null,
  phone text not null,
  email text not null,
  product_summary text,
  source text,
  notes text,
  status text not null default 'new',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.opportunities is 'Pre-purchase leads, separate from sleep journeys';

alter table public.opportunities enable row level security;

drop policy if exists "Opportunities viewable by authenticated users" on public.opportunities;
create policy "Opportunities viewable by authenticated users"
  on public.opportunities for select
  to authenticated
  using (public.is_store_visible(store_id));

drop policy if exists "Opportunities insertable by authenticated users" on public.opportunities;
create policy "Opportunities insertable by authenticated users"
  on public.opportunities for insert
  to authenticated
  with check (public.is_store_visible(store_id));

drop policy if exists "Opportunities updatable by authenticated users" on public.opportunities;
create policy "Opportunities updatable by authenticated users"
  on public.opportunities for update
  to authenticated
  using (public.is_store_visible(store_id))
  with check (public.is_store_visible(store_id));

create index if not exists idx_opportunities_store on public.opportunities (store_id);
create index if not exists idx_opportunities_status on public.opportunities (status);
create index if not exists idx_opportunities_assigned on public.opportunities (assigned_employee_id);

-- 3. Follow-ups for quote and deposit workflows
create table if not exists public.follow_ups (
  id uuid primary key default gen_random_uuid(),
  journey_id uuid not null references public.sleep_journeys (id) on delete cascade,
  opportunity_id uuid references public.opportunities (id) on delete set null,
  employee_id uuid references public.employees (id) on delete set null,
  type text not null check (type in ('quote','deposit')),
  due_at timestamptz not null,
  completed_at timestamptz,
  notes text,
  created_at timestamptz not null default now()
);

comment on table public.follow_ups is 'Customer follow-up actions (quote/deposit)';

alter table public.follow_ups enable row level security;

drop policy if exists "Follow ups viewable by authenticated users" on public.follow_ups;
create policy "Follow ups viewable by authenticated users"
  on public.follow_ups for select
  to authenticated
  using (
    exists (
      select 1 from public.sleep_journeys sj
      where sj.id = follow_ups.journey_id
        and public.is_journey_visible(sj.id)
    )
    or exists (
      select 1 from public.opportunities o
      where o.id = follow_ups.opportunity_id
        and public.is_store_visible(o.store_id)
    )
  );

drop policy if exists "Follow ups insertable by authenticated users" on public.follow_ups;
create policy "Follow ups insertable by authenticated users"
  on public.follow_ups for insert
  to authenticated
  with check (
    exists (
      select 1 from public.sleep_journeys sj
      where sj.id = follow_ups.journey_id
        and public.is_journey_visible(sj.id)
    )
    or exists (
      select 1 from public.opportunities o
      where o.id = follow_ups.opportunity_id
        and public.is_store_visible(o.store_id)
    )
  );

drop policy if exists "Follow ups updatable by authenticated users" on public.follow_ups;
create policy "Follow ups updatable by authenticated users"
  on public.follow_ups for update
  to authenticated
  using (
    exists (
      select 1 from public.sleep_journeys sj
      where sj.id = follow_ups.journey_id
        and public.is_journey_visible(sj.id)
    )
    or exists (
      select 1 from public.opportunities o
      where o.id = follow_ups.opportunity_id
        and public.is_store_visible(o.store_id)
    )
  )
  with check (
    exists (
      select 1 from public.sleep_journeys sj
      where sj.id = follow_ups.journey_id
        and public.is_journey_visible(sj.id)
    )
    or exists (
      select 1 from public.opportunities o
      where o.id = follow_ups.opportunity_id
        and public.is_store_visible(o.store_id)
    )
  );

create index if not exists idx_follow_ups_journey on public.follow_ups (journey_id);
create index if not exists idx_follow_ups_due_at on public.follow_ups (due_at);
create index if not exists idx_follow_ups_completed on public.follow_ups (completed_at);

-- 4. Pricing and store-level follow-up policy columns
alter table public.sleep_journeys
  add column if not exists price numeric;

alter table public.sleep_journeys
  alter column current_state set default 'Quoted'::public.journey_state;

alter table public.stores
  add column if not exists quote_follow_up_cadence jsonb default '[1, 3, 7, 14]'::jsonb;

alter table public.stores
  add column if not exists deposit_follow_up_default_days integer not null default 7;

alter table public.stores
  add column if not exists deposit_follow_up_max_days integer not null default 14;

comment on column public.stores.quote_follow_up_cadence is 'Array of days after quote_sent to schedule follow-ups';
comment on column public.stores.deposit_follow_up_default_days is 'Days after deposit to schedule follow-up';
comment on column public.stores.deposit_follow_up_max_days is 'Maximum days an employee can push a deposit follow-up out';

-- 5. State/event helpers rewritten for partial payments and follow-ups

create or replace function public.event_to_state(evt public.journey_event_type)
returns public.journey_state
language plpgsql
stable
as $$
begin
  return case evt
    when 'quote_created' then 'Quoted'::public.journey_state
    when 'quote_sent' then 'Quoted'::public.journey_state
    when 'deposit_received' then 'Quoted'::public.journey_state
    when 'payment_completed' then 'Quoted'::public.journey_state
    when 'inventory_required' then 'Waiting for Inventory'::public.journey_state
    when 'inventory_received' then 'Ready to Schedule'::public.journey_state
    when 'delivery_scheduled' then 'Scheduled'::public.journey_state
    when 'delivery_completed' then 'Sleep Trial'::public.journey_state
    when 'trial_completed' then 'Completed'::public.journey_state
    else null
  end;
end;
$$;

-- Total paid by a journey across deposits and payments; runs with invoker privileges so public callers respect RLS

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
        and (event_data->>'amount') ~ '^[0-9]+(\.[0-9]+)?$'
    ),
    0
  );
end;
$$;

-- Trigger: drive current_state, create follow-ups, handle cancellations

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
  store_rec public.stores%rowtype;
  emp_id uuid;
  follow_up_due timestamptz;
  max_due timestamptz;
  cadence int;
begin
  -- Employee who triggered this event, if any
  select id into emp_id
  from public.employees
  where auth_user_id = auth.uid();

  if new.event_type = 'journey_cancelled' then
    update public.sleep_journeys
    set cancelled_at = now(),
        cancelled_reason = coalesce(new.event_data->>'reason', 'No reason provided'),
        updated_at = now()
    where id = new.journey_id;
    return new;
  end if;

  target := public.event_to_state(new.event_type);

  if target is null then
    return new;
  end if;

  -- Payment/deposit events drive Sold only when running balance >= price
  if new.event_type in ('deposit_received', 'payment_completed') then
    select price into journey_price
    from public.sleep_journeys
    where id = new.journey_id;

    paid := public.total_paid(new.journey_id);

    if journey_price is not null and paid >= journey_price then
      target := 'Sold'::public.journey_state;
    else
      target := 'Quoted'::public.journey_state;
    end if;
  end if;

  update public.sleep_journeys
  set current_state = target,
      updated_at = now()
  where id = new.journey_id;

  -- Quote follow-ups: create one for each cadence entry
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

  -- Deposit follow-up: one, with optional employee override within store policy
  if new.event_type = 'deposit_received' then
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

drop trigger if exists journey_event_derive_state on public.journey_events;
create trigger journey_event_derive_state
  after insert on public.journey_events
  for each row
  execute function public.derive_journey_state();

-- 6. Data migration (non-destructive: soft-cancel journeys; Deposit Made -> Quoted)

insert into public.opportunities (
  store_id,
  assigned_employee_id,
  first_name,
  last_name,
  phone,
  email,
  product_summary,
  source,
  notes,
  status
)
select
  sj.store_id,
  sj.assigned_employee_id,
  c.first_name,
  c.last_name,
  c.phone,
  c.email,
  sj.product_summary,
  'migrated_active_opportunity',
  'Migrated from sleep journey ' || sj.id,
  'new'
from public.sleep_journeys sj
join public.customers c on c.id = sj.customer_id
where sj.current_state = 'Active Opportunity'
  and sj.cancelled_at is null;

update public.sleep_journeys
set cancelled_at = now(),
    cancelled_reason = 'Migrated to Opportunities during Phase 2'
where current_state = 'Active Opportunity'
  and cancelled_at is null;

update public.sleep_journeys
set current_state = 'Quoted'
where current_state = 'Deposit Made'
  and cancelled_at is null;

-- Backfill price for fully-paid journeys so their balance is zero; leave other old journeys as null
update public.sleep_journeys
set price = public.total_paid(id)
where current_state = 'Sold'
  and price is null;
