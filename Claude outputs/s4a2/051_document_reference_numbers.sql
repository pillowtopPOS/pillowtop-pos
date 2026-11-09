-- PillowTop POS: human-readable document reference numbers
--
--   Inventory counts:  {StoreCode}INV-000001    (per-store counter)
--   Transfers:         TRF-000001                 (per-company counter)
--   Purchase orders:   PO-000001                  (per-company counter)
--
-- Assignment happens in a BEFORE INSERT trigger on each table, so every
-- creation path (RPCs, client inserts, cron consolidation) is covered.
-- Numbers are allocated by a single INSERT ... ON CONFLICT ... DO UPDATE
-- against document_counters, which is atomic under concurrency and may leave
-- gaps if a transaction rolls back — acceptable, these are reference codes
-- not accounting sequences.

-- 1. Store codes

-- If an earlier revision of this migration already ran, it created the column
-- as call_sign — rename it rather than leaving a stale duplicate behind.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'stores' and column_name = 'call_sign'
  ) then
    execute 'alter table public.stores rename column call_sign to store_code';
  end if;
end $$;

alter table public.stores
  add column if not exists store_code text;

comment on column public.stores.store_code is
  'Short per-company-unique code used in document reference numbers (e.g. MS -> MSINV-000001)';

alter index if exists public.idx_stores_company_call_sign
  rename to idx_stores_company_store_code;

-- Unique per company, case-insensitive, nulls allowed (auto-derived on first use).
create unique index if not exists idx_stores_company_store_code
  on public.stores (company_id, upper(store_code))
  where store_code is not null;

-- 2. Counter table

create table if not exists public.document_counters (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  store_id uuid references public.stores(id) on delete cascade,
  doc_type text not null check (doc_type in ('inventory_count', 'transfer', 'purchase_order')),
  next_number integer not null default 1 check (next_number > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- nulls not distinct: store_id null scopes the counter company-wide.
  constraint document_counters_scope_key unique nulls not distinct (company_id, store_id, doc_type)
);

comment on table public.document_counters is 'Per-scope allocation counters for human-readable document reference codes';

alter table public.document_counters enable row level security;
-- No client access: numbers are allocated only inside security-definer
-- functions and the insert trigger.

-- 3. reference_code columns

alter table public.inventory_counts
  add column if not exists reference_code text;
alter table public.transfers
  add column if not exists reference_code text;
alter table public.purchase_orders
  add column if not exists reference_code text;

-- 4. Atomic counter allocation. Single upsert statement — concurrent callers
--    serialize on the counter row, so no duplicates.

create or replace function public.next_document_number(
  p_company_id uuid,
  p_store_id uuid,
  p_doc_type text
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_assigned integer;
begin
  insert into public.document_counters (company_id, store_id, doc_type, next_number)
  values (p_company_id, p_store_id, p_doc_type, 2)
  on conflict on constraint document_counters_scope_key do update
    set next_number = public.document_counters.next_number + 1,
        updated_at = now()
  returning next_number - 1 into v_assigned;

  return v_assigned;
end;
$$;

-- Internal-only: reached by the assign_document_reference trigger, which runs
-- as function owner regardless of grants. No role should call these directly.
revoke execute on function public.next_document_number(uuid, uuid, text) from public, anon, authenticated;

-- 5. Resolve (or auto-derive and persist) a store's code. Derivation is
--    the uppercase initials of the store name; collisions inside the company
--    get a numeric suffix (MS, MS2, MS3, …). Locks the store row so two
--    concurrent first-uses can't race the assignment.

-- If an earlier revision ran, the function exists under the old name — rename
-- it (preserves grants) before create-or-replace writes the new body.
do $$
begin
  if exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'ensure_store_call_sign'
  ) then
    execute 'alter function public.ensure_store_call_sign(uuid) rename to ensure_store_code';
  end if;
end $$;

create or replace function public.ensure_store_code(p_store_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_store public.stores%rowtype;
  v_base text;
  v_candidate text;
  v_suffix integer := 1;
begin
  select * into v_store
  from public.stores
  where id = p_store_id
  for update;

  if not found then
    raise exception 'Store not found';
  end if;

  if v_store.store_code is not null and v_store.store_code <> '' then
    return upper(v_store.store_code);
  end if;

  select upper(string_agg(left(word, 1), ''))
    into v_base
  from regexp_split_to_table(coalesce(v_store.name, ''), '[^A-Za-z0-9]+') as word
  where word <> '';

  if v_base is null or v_base = '' then
    v_base := 'ST';
  end if;

  v_candidate := v_base;
  loop
    begin
      update public.stores
        set store_code = v_candidate
      where id = p_store_id;
      exit;
    exception
      when unique_violation then
        v_suffix := v_suffix + 1;
        v_candidate := v_base || v_suffix::text;
    end;
  end loop;

  return v_candidate;
end;
$$;

-- Internal plumbing (called by the trigger and backfill below). Revoke from
-- all client roles so nobody can force-derive a code on an arbitrary
-- store; the trigger reaches it as function owner regardless of grants.
revoke execute on function public.ensure_store_code(uuid) from public, anon, authenticated;

-- 6. Insert trigger: fills reference_code when the caller didn't provide one.

create or replace function public.assign_document_reference()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_store_id uuid;
  v_doc_type text;
  v_prefix text;
  v_number integer;
begin
  if new.reference_code is not null then
    return new;
  end if;

  if tg_table_name = 'inventory_counts' then
    v_company_id := new.company_id;
    v_store_id := new.store_id;
    v_doc_type := 'inventory_count';
    v_prefix := public.ensure_store_code(new.store_id) || 'INV';
  elsif tg_table_name = 'transfers' then
    select s.company_id into v_company_id
    from public.stores s
    where s.id = new.origin_location_id;
    v_store_id := null;
    v_doc_type := 'transfer';
    v_prefix := 'TRF';
  elsif tg_table_name = 'purchase_orders' then
    select s.company_id into v_company_id
    from public.stores s
    where s.id = new.destination_location_id;
    v_store_id := null;
    v_doc_type := 'purchase_order';
    v_prefix := 'PO';
  else
    return new;
  end if;

  if v_company_id is null then
    raise exception 'Cannot assign document reference: company could not be resolved';
  end if;

  v_number := public.next_document_number(v_company_id, v_store_id, v_doc_type);
  new.reference_code := v_prefix || '-' || lpad(v_number::text, 6, '0');
  return new;
end;
$$;

-- Trigger functions don't need caller EXECUTE to fire, but revoke public/anon
-- anyway so it can't be invoked directly outside the trigger.
revoke execute on function public.assign_document_reference() from public, anon;

drop trigger if exists trg_inventory_counts_reference on public.inventory_counts;
create trigger trg_inventory_counts_reference
  before insert on public.inventory_counts
  for each row execute function public.assign_document_reference();

drop trigger if exists trg_transfers_reference on public.transfers;
create trigger trg_transfers_reference
  before insert on public.transfers
  for each row execute function public.assign_document_reference();

drop trigger if exists trg_purchase_orders_reference on public.purchase_orders;
create trigger trg_purchase_orders_reference
  before insert on public.purchase_orders
  for each row execute function public.assign_document_reference();

-- 7. Backfill

-- 7a. Every store gets a code first.
do $$
declare
  v_store_id uuid;
begin
  for v_store_id in
    select id from public.stores where store_code is null or store_code = ''
  loop
    perform public.ensure_store_code(v_store_id);
  end loop;
end $$;

-- 7b. Inventory counts — numbered per store, oldest first.
with ordered as (
  select
    c.id,
    s.store_code,
    row_number() over (partition by c.store_id order by c.created_at, c.id) as rn
  from public.inventory_counts c
  join public.stores s on s.id = c.store_id
  where c.reference_code is null
)
update public.inventory_counts c
  set reference_code = upper(o.store_code) || 'INV-' || lpad(o.rn::text, 6, '0')
from ordered o
where c.id = o.id;

insert into public.document_counters (company_id, store_id, doc_type, next_number)
select c.company_id, c.store_id, 'inventory_count', count(*) + 1
from public.inventory_counts c
where c.reference_code is not null
group by c.company_id, c.store_id
on conflict on constraint document_counters_scope_key do update
  set next_number = greatest(public.document_counters.next_number, excluded.next_number);

-- 7c. Transfers — numbered per company (via origin store), oldest first.
with ordered as (
  select
    t.id,
    s.company_id,
    row_number() over (partition by s.company_id order by t.created_at, t.id) as rn
  from public.transfers t
  join public.stores s on s.id = t.origin_location_id
  where t.reference_code is null
)
update public.transfers t
  set reference_code = 'TRF-' || lpad(o.rn::text, 6, '0')
from ordered o
where t.id = o.id;

insert into public.document_counters (company_id, store_id, doc_type, next_number)
select s.company_id, null, 'transfer', count(*) + 1
from public.transfers t
join public.stores s on s.id = t.origin_location_id
where t.reference_code is not null
group by s.company_id
on conflict on constraint document_counters_scope_key do update
  set next_number = greatest(public.document_counters.next_number, excluded.next_number);

-- 7d. Purchase orders — numbered per company (via destination store), oldest first.
with ordered as (
  select
    p.id,
    s.company_id,
    row_number() over (partition by s.company_id order by p.created_at, p.id) as rn
  from public.purchase_orders p
  join public.stores s on s.id = p.destination_location_id
  where p.reference_code is null
)
update public.purchase_orders p
  set reference_code = 'PO-' || lpad(o.rn::text, 6, '0')
from ordered o
where p.id = o.id;

insert into public.document_counters (company_id, store_id, doc_type, next_number)
select s.company_id, null, 'purchase_order', count(*) + 1
from public.purchase_orders p
join public.stores s on s.id = p.destination_location_id
where p.reference_code is not null
group by s.company_id
on conflict on constraint document_counters_scope_key do update
  set next_number = greatest(public.document_counters.next_number, excluded.next_number);
