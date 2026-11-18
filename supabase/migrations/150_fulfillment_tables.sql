-- 150_fulfillment_tables.sql
-- Slice 2 (per-item fulfillment) schema foundations.
-- Purely additive: creates the fulfillment record tables and a fulfilled-quantity
-- counter on journey_inventory_requirements. No behavior changes; the feature is
-- activated by a later migration (record_journey_fulfillment RPC).
-- Writes to these tables are performed only by security-definer RPCs; authenticated
-- users get read-only access for journeys they can already see.

create table if not exists public.journey_fulfillments (
  id uuid primary key default gen_random_uuid(),
  journey_id uuid not null references public.sleep_journeys(id) on delete cascade,
  company_id uuid not null references public.companies(id),
  method text not null check (method in ('pickup','delivery')),
  location_id uuid references public.stores(id),
  completed_on date not null,
  recorded_by uuid references public.employees(id),
  recorded_by_name text,
  recorded_at timestamptz not null default now(),
  backdated boolean not null default false,
  backdate_reason text,
  is_closing boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.journey_fulfillment_units (
  id uuid primary key default gen_random_uuid(),
  fulfillment_id uuid not null references public.journey_fulfillments(id) on delete cascade,
  journey_id uuid not null references public.sleep_journeys(id) on delete cascade,
  line_item_id uuid not null references public.journey_line_items(id),
  unit_index integer not null,
  requirement_id uuid references public.journey_inventory_requirements(id),
  sleep_trial_item_id uuid references public.sleep_trial_items(id),
  unique (line_item_id, unit_index)
);

alter table public.journey_inventory_requirements
  add column if not exists quantity_fulfilled integer not null default 0;

create index if not exists journey_fulfillments_journey_id_idx
  on public.journey_fulfillments (journey_id);

create index if not exists journey_fulfillment_units_journey_id_idx
  on public.journey_fulfillment_units (journey_id);

create index if not exists journey_fulfillment_units_fulfillment_id_idx
  on public.journey_fulfillment_units (fulfillment_id);

create index if not exists journey_fulfillment_units_line_item_id_idx
  on public.journey_fulfillment_units (line_item_id);

alter table public.journey_fulfillments enable row level security;
alter table public.journey_fulfillment_units enable row level security;

drop policy if exists journey_fulfillments_select on public.journey_fulfillments;
create policy journey_fulfillments_select on public.journey_fulfillments
  for select to authenticated
  using (public.is_journey_visible(journey_id));

drop policy if exists journey_fulfillment_units_select on public.journey_fulfillment_units;
create policy journey_fulfillment_units_select on public.journey_fulfillment_units
  for select to authenticated
  using (public.is_journey_visible(journey_id));
