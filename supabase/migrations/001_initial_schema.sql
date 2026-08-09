-- Enable pgcrypto for UUID generation
create extension if not exists pgcrypto;

-- Enums
do $$
begin
  if not exists (select 1 from pg_type where typname = 'journey_state') then
    create type public.journey_state as enum (
      'Active Opportunity',
      'Quoted',
      'Deposit Made',
      'Sold',
      'Waiting for Inventory',
      'Ready to Schedule',
      'Scheduled',
      'Sleep Trial',
      'Completed'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'journey_event_type') then
    create type public.journey_event_type as enum (
      'quote_created',
      'deposit_received',
      'payment_completed',
      'inventory_required',
      'inventory_received',
      'delivery_scheduled',
      'delivery_completed',
      'trial_completed',
      'journey_cancelled'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'employee_role') then
    create type public.employee_role as enum ('owner', 'manager', 'sales');
  end if;
end
$$;

-- Stores
create table if not exists public.stores (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text,
  trial_length_nights integer not null default 120,
  created_at timestamptz not null default now()
);

-- Employees
create table if not exists public.employees (
  id uuid primary key default gen_random_uuid(),
  home_store_id uuid references public.stores (id) on delete set null,
  name text not null,
  role public.employee_role not null default 'sales',
  auth_user_id uuid references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (auth_user_id)
);

-- Customers
create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  first_name text not null,
  last_name text not null,
  phone text not null,
  email text not null,
  created_at timestamptz not null default now()
);

-- Sleep Journeys
create table if not exists public.sleep_journeys (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers (id) on delete restrict,
  store_id uuid not null references public.stores (id) on delete restrict,
  assigned_employee_id uuid references public.employees (id) on delete set null,
  current_state public.journey_state not null default 'Active Opportunity',
  product_summary text,
  cancelled_at timestamptz,
  cancelled_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Journey events (source of truth)
create table if not exists public.journey_events (
  id uuid primary key default gen_random_uuid(),
  journey_id uuid not null references public.sleep_journeys (id) on delete cascade,
  event_type public.journey_event_type not null,
  event_data jsonb not null default '{}'::jsonb,
  triggered_by text not null default 'system',
  created_at timestamptz not null default now()
);

-- Indexes for common lookups
create index if not exists idx_sleep_journeys_customer on public.sleep_journeys (customer_id);
create index if not exists idx_sleep_journeys_store on public.sleep_journeys (store_id);
create index if not exists idx_sleep_journeys_employee on public.sleep_journeys (assigned_employee_id);
create index if not exists idx_sleep_journeys_state on public.sleep_journeys (current_state);
create index if not exists idx_journey_events_journey on public.journey_events (journey_id);
create index if not exists idx_journey_events_type on public.journey_events (event_type);
create index if not exists idx_employees_auth_user on public.employees (auth_user_id);
create index if not exists idx_employees_store on public.employees (home_store_id);

-- Helper: current user's employee record (security definer to bypass RLS)
create or replace function public.current_employee()
returns public.employees
language sql
security definer
stable
as $$
  select * from public.employees where auth_user_id = auth.uid() limit 1;
$$;

-- Helper: is the user allowed to see a given store?
create or replace function public.is_store_visible(check_store_id uuid)
returns boolean
language plpgsql
security definer
stable
as $$
declare
  user_role public.employee_role;
  active_store_id uuid;
begin
  select role into user_role from public.employees where auth_user_id = auth.uid() limit 1;

  if user_role in ('owner', 'manager') then
    return true;
  end if;

  active_store_id := (auth.jwt() -> 'user_metadata' ->> 'active_store_id')::uuid;
  return active_store_id is not null and active_store_id = check_store_id;
end;
$$;

-- Helper: is a customer visible through at least one accessible journey?
create or replace function public.is_customer_visible(check_customer_id uuid)
returns boolean
language plpgsql
security definer
stable
as $$
  select exists (
    select 1 from public.sleep_journeys sj
    where sj.customer_id = check_customer_id
      and public.is_store_visible(sj.store_id)
  );
$$;

-- Helper: is a journey visible?
create or replace function public.is_journey_visible(check_journey_id uuid)
returns boolean
language plpgsql
security definer
stable
as $$
  select exists (
    select 1 from public.sleep_journeys sj
    where sj.id = check_journey_id
      and public.is_store_visible(sj.store_id)
  );
$$;

-- Row Level Security
alter table public.stores enable row level security;
alter table public.employees enable row level security;
alter table public.customers enable row level security;
alter table public.sleep_journeys enable row level security;
alter table public.journey_events enable row level security;

drop policy if exists "Stores are viewable by authenticated users" on public.stores;
create policy "Stores are viewable by authenticated users"
  on public.stores for select
  to authenticated
  using (true);

drop policy if exists "Employees viewable by authenticated users" on public.employees;
create policy "Employees viewable by authenticated users"
  on public.employees for select
  to authenticated
  using (
    (select role from public.employees where auth_user_id = auth.uid() limit 1) in ('owner','manager')
    or home_store_id = (auth.jwt() -> 'user_metadata' ->> 'active_store_id')::uuid
  );

drop policy if exists "Customers viewable by authenticated users" on public.customers;
create policy "Customers viewable by authenticated users"
  on public.customers for select
  to authenticated
  using (public.is_customer_visible(id));

drop policy if exists "Customers insertable by authenticated users" on public.customers;
create policy "Customers insertable by authenticated users"
  on public.customers for insert
  to authenticated
  with check (true);

drop policy if exists "Sleep journeys viewable by authenticated users" on public.sleep_journeys;
create policy "Sleep journeys viewable by authenticated users"
  on public.sleep_journeys for select
  to authenticated
  using (public.is_store_visible(store_id));

drop policy if exists "Sleep journeys insertable by authenticated users" on public.sleep_journeys;
create policy "Sleep journeys insertable by authenticated users"
  on public.sleep_journeys for insert
  to authenticated
  with check (
    public.is_store_visible(store_id)
  );

drop policy if exists "Sleep journeys updatable by authenticated users" on public.sleep_journeys;
create policy "Sleep journeys updatable by authenticated users"
  on public.sleep_journeys for update
  to authenticated
  using (public.is_store_visible(store_id))
  with check (public.is_store_visible(store_id));

drop policy if exists "Journey events viewable by authenticated users" on public.journey_events;
create policy "Journey events viewable by authenticated users"
  on public.journey_events for select
  to authenticated
  using (public.is_journey_visible(journey_id));

drop policy if exists "Journey events insertable by authenticated users" on public.journey_events;
create policy "Journey events insertable by authenticated users"
  on public.journey_events for insert
  to authenticated
  with check (public.is_journey_visible(journey_id));

-- State machine: event -> from -> to
create or replace function public.event_to_state(evt public.journey_event_type)
returns public.journey_state
language sql
immutable
as $$
  select case evt
    when 'quote_created' then 'Quoted'::public.journey_state
    when 'deposit_received' then 'Deposit Made'::public.journey_state
    when 'payment_completed' then 'Sold'::public.journey_state
    when 'inventory_required' then 'Waiting for Inventory'::public.journey_state
    when 'inventory_received' then 'Ready to Schedule'::public.journey_state
    when 'delivery_scheduled' then 'Scheduled'::public.journey_state
    when 'delivery_completed' then 'Sleep Trial'::public.journey_state
    when 'trial_completed' then 'Completed'::public.journey_state
    when 'journey_cancelled' then 'Active Opportunity'::public.journey_state
  end;
$$;

-- Keep current_state in sync with the latest event
create or replace function public.derive_journey_state()
returns trigger
language plpgsql
as $$
declare
  target public.journey_state;
begin
  if new.event_type = 'journey_cancelled' then
    update public.sleep_journeys
    set cancelled_at = now(),
        cancelled_reason = coalesce(new.event_data ->> 'reason', 'No reason provided'),
        current_state = 'Active Opportunity',
        updated_at = now()
    where id = new.journey_id;
    return new;
  end if;

  target := public.event_to_state(new.event_type);

  if target is not null then
    update public.sleep_journeys
    set current_state = target,
        updated_at = now()
    where id = new.journey_id;
  end if;

  return new;
end;
$$;

drop trigger if exists journey_event_derive_state on public.journey_events;
create trigger journey_event_derive_state
  after insert on public.journey_events
  for each row
  execute function public.derive_journey_state();

-- Realtime
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime with (publish = 'insert,update,delete,truncate');
  end if;
end
$$;

alter publication supabase_realtime add table public.sleep_journeys;
alter publication supabase_realtime add table public.journey_events;
