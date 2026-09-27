-- PillowTop POS Phase 7d-iii: blind physical inventory counts
--
-- Blindness is enforced structurally: clients never SELECT the base
-- inventory_count_items table. They read inventory_count_items_public, a
-- postgres-owned view that nulls expected_quantity while the parent count is
-- pending_start_approval or in_progress. The finalize screen gets expected
-- quantities through get_inventory_count_review(), a security-definer RPC
-- gated to manager-of-store/owner/admin.

-- 1. Enums

do $$
begin
  if not exists (select 1 from pg_type where typname = 'inventory_count_type') then
    create type public.inventory_count_type as enum ('full', 'cycle');
  end if;
  if not exists (select 1 from pg_type where typname = 'inventory_count_status') then
    create type public.inventory_count_status as enum (
      'pending_start_approval',
      'in_progress',
      'submitted',
      'approved',
      'rejected',
      'cancelled'
    );
  end if;
end $$;

grant usage on type public.inventory_count_type to authenticated;
grant usage on type public.inventory_count_status to authenticated;

-- 2. Tables

create table if not exists public.inventory_counts (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  store_id uuid not null references public.stores(id) on delete cascade,
  count_type public.inventory_count_type not null,
  status public.inventory_count_status not null default 'pending_start_approval',
  requested_by uuid references public.employees(id) on delete set null,
  started_by uuid references public.employees(id) on delete set null,
  started_at timestamptz,
  approved_by uuid references public.employees(id) on delete set null,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.inventory_counts is 'One physical count session at a store (full or cycle)';

create index if not exists idx_inventory_counts_store
  on public.inventory_counts (store_id);
create index if not exists idx_inventory_counts_status
  on public.inventory_counts (status);

-- Only one non-terminal count per store at a time.
create unique index if not exists idx_inventory_counts_one_active_per_store
  on public.inventory_counts (store_id)
  where status in ('pending_start_approval', 'in_progress', 'submitted');

create table if not exists public.inventory_count_items (
  id uuid primary key default gen_random_uuid(),
  count_id uuid not null references public.inventory_counts(id) on delete cascade,
  variant_id uuid not null references public.products(id) on delete restrict,
  -- Snapshot of Prime on_hand at scope-set time; the count's fixed baseline.
  expected_quantity integer not null default 0 check (expected_quantity >= 0),
  submitted_quantity integer check (submitted_quantity is null or submitted_quantity >= 0),
  submitted_by uuid references public.employees(id) on delete set null,
  submitted_at timestamptz,
  counted_quantity integer check (counted_quantity is null or counted_quantity >= 0),
  entered_by uuid references public.employees(id) on delete set null,
  entered_at timestamptz,
  created_at timestamptz not null default now(),
  unique (count_id, variant_id)
);

comment on table public.inventory_count_items is 'Products included in a count; expected_quantity is the fixed comparison baseline';

create index if not exists idx_inventory_count_items_count
  on public.inventory_count_items (count_id);
create index if not exists idx_inventory_count_items_variant
  on public.inventory_count_items (variant_id);

-- 3. RLS + grants
--    inventory_counts is client-readable per store visibility; all writes go
--    through security-definer functions. inventory_count_items is never read
--    by clients directly — only via the masked public view.

alter table public.inventory_counts enable row level security;
alter table public.inventory_count_items enable row level security;

drop policy if exists "Inventory counts viewable by visible location" on public.inventory_counts;
create policy "Inventory counts viewable by visible location"
  on public.inventory_counts for select
  to authenticated
  using (public.is_store_visible(store_id));

grant select on public.inventory_counts to authenticated;
-- No grants on public.inventory_count_items: expected_quantity stays blind.

create or replace view public.inventory_count_items_public as
select
  i.id,
  i.count_id,
  i.variant_id,
  case
    when c.status in ('pending_start_approval', 'in_progress') then null
    else i.expected_quantity
  end as expected_quantity,
  i.submitted_quantity,
  i.submitted_by,
  i.submitted_at,
  i.counted_quantity,
  i.entered_by,
  i.entered_at,
  i.created_at
from public.inventory_count_items i
join public.inventory_counts c on c.id = i.count_id
where public.is_store_visible(c.store_id);

alter view public.inventory_count_items_public owner to postgres;
grant select on public.inventory_count_items_public to authenticated;

-- 4. Helpers

-- Validate the acting employee and return their row.
create or replace function public.verify_count_employee(p_employee_id uuid)
returns public.employees
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp public.employees%rowtype;
begin
  if p_employee_id is null then
    raise exception 'Employee id is required';
  end if;

  select * into v_emp from public.employees where id = p_employee_id;
  if not found then
    raise exception 'Employee not found';
  end if;

  if v_emp.auth_user_id is distinct from auth.uid() then
    raise exception 'Employee does not match the authenticated user';
  end if;

  return v_emp;
end;
$$;

grant execute on function public.verify_count_employee(uuid) to authenticated;

-- Shared daily check-in check: is the caller checked in at this store today?
-- (same JWT user_metadata mechanism as transfer receipt confirmation).
create or replace function public.is_checked_in_at(p_store_id uuid)
returns boolean
language plpgsql
security definer
stable
set search_path = public
as $$
declare
  v_active_store uuid;
  v_confirmed_at timestamptz;
begin
  v_active_store := (auth.jwt() -> 'user_metadata' ->> 'active_store_id')::uuid;
  v_confirmed_at := nullif(auth.jwt() -> 'user_metadata' ->> 'active_store_confirmed_at', '')::timestamptz;

  return v_active_store is not null
    and v_active_store = p_store_id
    and v_confirmed_at is not null
    and v_confirmed_at::date = current_date;
end;
$$;

grant execute on function public.is_checked_in_at(uuid) to authenticated;

-- Who may type submitted_quantity during in_progress: the requester,
-- owner/admin, a manager at their home store, or anyone checked in at the
-- counted store today.
create or replace function public.can_enter_count(
  p_emp public.employees,
  p_count public.inventory_counts
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Company scoping first: nobody touches another tenant's count.
  if not public.is_store_visible(p_count.store_id) then
    return false;
  end if;

  if p_emp.role::text in ('owner', 'admin') then
    return true;
  end if;
  if p_emp.role::text = 'manager' and p_emp.home_store_id = p_count.store_id then
    return true;
  end if;
  if p_count.requested_by = p_emp.id then
    return true;
  end if;

  return public.is_checked_in_at(p_count.store_id);
end;
$$;

-- Who may finalize: owner/admin anywhere, manager only at their home store.
create or replace function public.can_finalize_count(
  p_emp public.employees,
  p_count public.inventory_counts
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Company scoping first: nobody touches another tenant's count.
  if not public.is_store_visible(p_count.store_id) then
    return false;
  end if;

  if p_emp.role::text in ('owner', 'admin') then
    return true;
  end if;
  return p_emp.role::text = 'manager' and p_emp.home_store_id = p_count.store_id;
end;
$$;

-- 5. Create a count (and its items). Managers get in_progress immediately for
--    their home store; owner/admin for any store; everyone else creates a
--    pending_start_approval request.

create or replace function public.create_inventory_count(
  p_employee_id uuid,
  p_store_id uuid,
  p_count_type public.inventory_count_type,
  p_variant_ids uuid[] default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp public.employees%rowtype;
  v_store public.stores%rowtype;
  v_count_id uuid;
  v_start_now boolean;
begin
  v_emp := public.verify_count_employee(p_employee_id);

  select * into v_store from public.stores where id = p_store_id;
  if not found then
    raise exception 'Store not found';
  end if;
  if not public.is_store_visible(p_store_id) then
    raise exception 'Store is not visible to this employee';
  end if;

  if v_emp.role::text in ('owner', 'admin') then
    v_start_now := true;
  elsif v_emp.role::text = 'manager' then
    -- Direct start at their home store, or wherever they're checked in today.
    -- Any other store falls through to the pending_start_approval path like
    -- a non-manager request.
    v_start_now := v_emp.home_store_id = p_store_id
      or public.is_checked_in_at(p_store_id);
  else
    v_start_now := false;
  end if;

  if p_count_type = 'cycle' and (p_variant_ids is null or cardinality(p_variant_ids) = 0) then
    raise exception 'A cycle count requires at least one product';
  end if;

  begin
    insert into public.inventory_counts (
      company_id, store_id, count_type, status,
      requested_by, started_by, started_at
    ) values (
      v_store.company_id, p_store_id, p_count_type,
      case when v_start_now then 'in_progress'::public.inventory_count_status
           else 'pending_start_approval'::public.inventory_count_status end,
      v_emp.id,
      case when v_start_now then v_emp.id else null end,
      case when v_start_now then now() else null end
    )
    returning id into v_count_id;
  exception
    when unique_violation then
      raise exception 'An active count already exists for this store';
  end;

  if p_count_type = 'full' then
    -- Everything with a footprint at the store: a par level, or any
    -- inventory_positions row (even a zero one).
    insert into public.inventory_count_items (count_id, variant_id, expected_quantity)
    select
      v_count_id,
      f.variant_id,
      coalesce((
        select ip.on_hand_quantity
        from public.inventory_positions ip
        where ip.variant_id = f.variant_id
          and ip.location_id = p_store_id
          and ip.disposition = 'Prime'
          and ip.sublocation_id is null
      ), 0)
    from (
      select variant_id from public.par_levels where store_id = p_store_id
      union
      select variant_id from public.inventory_positions where location_id = p_store_id
    ) f;
  else
    if exists (
      select 1
      from unnest(p_variant_ids) v
      join public.products p on p.id = v
      where p.company_id is distinct from v_store.company_id
    ) then
      raise exception 'Cycle count products must belong to the same company as the store';
    end if;

    insert into public.inventory_count_items (count_id, variant_id, expected_quantity)
    select
      v_count_id,
      v.variant_id,
      coalesce((
        select ip.on_hand_quantity
        from public.inventory_positions ip
        where ip.variant_id = v.variant_id
          and ip.location_id = p_store_id
          and ip.disposition = 'Prime'
          and ip.sublocation_id is null
      ), 0)
    from (select distinct unnest(p_variant_ids) as variant_id) v;
  end if;

  if not exists (select 1 from public.inventory_count_items where count_id = v_count_id) then
    raise exception 'Count scope is empty — nothing to count at this store';
  end if;

  return v_count_id;
end;
$$;

grant execute on function public.create_inventory_count(uuid, uuid, public.inventory_count_type, uuid[]) to authenticated;

-- 6. Approve / reject a pending start request (owner/admin only — managers do
--    not gate count requests).

create or replace function public.approve_inventory_count_start(
  p_count_id uuid,
  p_employee_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp public.employees%rowtype;
  v_count public.inventory_counts%rowtype;
begin
  v_emp := public.verify_count_employee(p_employee_id);

  if v_emp.role::text not in ('owner', 'admin') then
    raise exception 'Only an owner or admin can approve a count request';
  end if;

  select * into v_count
  from public.inventory_counts
  where id = p_count_id
  for update;

  if not found then raise exception 'Count not found'; end if;
  if not public.is_store_visible(v_count.store_id) then
    raise exception 'Count is not visible to this employee';
  end if;
  if v_count.status <> 'pending_start_approval' then
    raise exception 'Only pending count requests can be approved';
  end if;

  update public.inventory_counts
    set status = 'in_progress',
        started_by = v_count.requested_by,
        started_at = now(),
        updated_at = now()
  where id = p_count_id;
end;
$$;

grant execute on function public.approve_inventory_count_start(uuid, uuid) to authenticated;

create or replace function public.reject_inventory_count_start(
  p_count_id uuid,
  p_employee_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp public.employees%rowtype;
  v_count public.inventory_counts%rowtype;
begin
  v_emp := public.verify_count_employee(p_employee_id);

  if v_emp.role::text not in ('owner', 'admin') then
    raise exception 'Only an owner or admin can reject a count request';
  end if;

  select * into v_count
  from public.inventory_counts
  where id = p_count_id
  for update;

  if not found then raise exception 'Count not found'; end if;
  if not public.is_store_visible(v_count.store_id) then
    raise exception 'Count is not visible to this employee';
  end if;
  if v_count.status <> 'pending_start_approval' then
    raise exception 'Only pending count requests can be rejected';
  end if;

  update public.inventory_counts
    set status = 'rejected',
        updated_at = now()
  where id = p_count_id;
end;
$$;

grant execute on function public.reject_inventory_count_start(uuid, uuid) to authenticated;

-- 7. Digital first-pass entry while in_progress. p_entries is a jsonb array of
--    {"item_id": uuid, "quantity": int}; re-saving overwrites the previous
--    submission.

create or replace function public.submit_count_quantities(
  p_count_id uuid,
  p_employee_id uuid,
  p_entries jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp public.employees%rowtype;
  v_count public.inventory_counts%rowtype;
  v_entry jsonb;
  v_item_id uuid;
  v_qty integer;
begin
  v_emp := public.verify_count_employee(p_employee_id);

  select * into v_count
  from public.inventory_counts
  where id = p_count_id
  for update;

  if not found then raise exception 'Count not found'; end if;
  if v_count.status <> 'in_progress' then
    raise exception 'Quantities can only be entered while the count is in progress';
  end if;
  if not public.can_enter_count(v_emp, v_count) then
    raise exception 'Only the requester, someone checked in at this store today, or this store''s manager, or an owner/admin can enter counts';
  end if;

  for v_entry in select * from jsonb_array_elements(coalesce(p_entries, '[]'::jsonb)) loop
    v_item_id := (v_entry ->> 'item_id')::uuid;
    v_qty := (v_entry ->> 'quantity')::integer;

    if v_qty is null or v_qty < 0 then
      raise exception 'Invalid counted quantity';
    end if;

    update public.inventory_count_items
      set submitted_quantity = v_qty,
          submitted_by = v_emp.id,
          submitted_at = now()
    where id = v_item_id
      and count_id = p_count_id;

    if not found then
      raise exception 'Count item % does not belong to this count', v_item_id;
    end if;
  end loop;

  update public.inventory_counts set updated_at = now() where id = p_count_id;
end;
$$;

grant execute on function public.submit_count_quantities(uuid, uuid, jsonb) to authenticated;

-- 8. Mark the count submitted — a convenience signal that entry is done and
--    the count is ready for finalize. Same permissions as entry.

create or replace function public.submit_inventory_count(
  p_count_id uuid,
  p_employee_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp public.employees%rowtype;
  v_count public.inventory_counts%rowtype;
begin
  v_emp := public.verify_count_employee(p_employee_id);

  select * into v_count
  from public.inventory_counts
  where id = p_count_id
  for update;

  if not found then raise exception 'Count not found'; end if;
  if v_count.status <> 'in_progress' then
    raise exception 'Only in-progress counts can be submitted';
  end if;
  if not public.can_enter_count(v_emp, v_count) then
    raise exception 'Only the requester, someone checked in at this store today, or this store''s manager, or an owner/admin can submit a count';
  end if;

  update public.inventory_counts
    set status = 'submitted',
        updated_at = now()
  where id = p_count_id;
end;
$$;

grant execute on function public.submit_inventory_count(uuid, uuid) to authenticated;

-- 9. Finalize-screen data: the only path that reveals expected_quantity for a
--    live count, restricted to the roles allowed to finalize and only once the
--    count is submitted — blindness holds for the entire in_progress phase,
--    for every role, no exceptions. Also usable on approved counts for
--    history.

create or replace function public.get_inventory_count_review(
  p_count_id uuid,
  p_employee_id uuid
)
returns table (
  item_id uuid,
  variant_id uuid,
  item_name text,
  sku text,
  expected_quantity integer,
  submitted_quantity integer,
  submitted_by uuid,
  submitted_by_name text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp public.employees%rowtype;
  v_count public.inventory_counts%rowtype;
begin
  v_emp := public.verify_count_employee(p_employee_id);

  select * into v_count from public.inventory_counts where id = p_count_id;
  if not found then raise exception 'Count not found'; end if;
  if v_count.status not in ('submitted', 'approved') then
    raise exception 'This count is not ready for review';
  end if;
  if not public.can_finalize_count(v_emp, v_count) then
    raise exception 'Only a manager of this store or an owner/admin can review a count';
  end if;

  return query
  select
    i.id,
    i.variant_id,
    p.item_name,
    p.sku,
    i.expected_quantity,
    i.submitted_quantity,
    i.submitted_by,
    e.name
  from public.inventory_count_items i
  join public.products p on p.id = i.variant_id
  left join public.employees e on e.id = i.submitted_by
  where i.count_id = p_count_id
  order by p.item_name;
end;
$$;

grant execute on function public.get_inventory_count_review(uuid, uuid) to authenticated;

-- 10. Finalize & approve: the finalizer transcribes/authoritative-entered
--     counted_quantity for every item; each Prime position is SET to the
--     counted value (ATS may go negative — physical count is ground truth),
--     with a ledger entry per changed position.

create or replace function public.finalize_inventory_count(
  p_count_id uuid,
  p_employee_id uuid,
  p_counts jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp public.employees%rowtype;
  v_count public.inventory_counts%rowtype;
  v_item public.inventory_count_items%rowtype;
  v_qty integer;
  v_pos public.inventory_positions%rowtype;
  v_old_on_hand integer;
  v_item_total integer;
begin
  v_emp := public.verify_count_employee(p_employee_id);

  select * into v_count
  from public.inventory_counts
  where id = p_count_id
  for update;

  if not found then raise exception 'Count not found'; end if;
  if v_count.status <> 'submitted' then
    raise exception 'Only submitted counts can be finalized';
  end if;
  if not public.can_finalize_count(v_emp, v_count) then
    raise exception 'Only a manager of this store or an owner/admin can finalize a count';
  end if;

  select count(*) into v_item_total
  from public.inventory_count_items
  where count_id = p_count_id;

  for v_item in
    select * from public.inventory_count_items
    where count_id = p_count_id
    order by id
    for update
  loop
    if p_counts is null or not (p_counts ? v_item.id::text) then
      raise exception 'A counted quantity is required for every item';
    end if;

    v_qty := (p_counts ->> v_item.id::text)::integer;
    if v_qty is null or v_qty < 0 then
      raise exception 'Invalid counted quantity';
    end if;

    perform pg_advisory_xact_lock(
      hashtextextended(v_item.variant_id::text || ':' || v_count.store_id::text || ':Prime', 7137)
    );

    select * into v_pos
    from public.inventory_positions
    where variant_id = v_item.variant_id
      and location_id = v_count.store_id
      and disposition = 'Prime'
      and sublocation_id is null
    for update;

    if not found then
      insert into public.inventory_positions (
        variant_id, location_id, sublocation_id, disposition,
        on_hand_quantity, committed_quantity
      ) values (
        v_item.variant_id, v_count.store_id, null, 'Prime', v_qty, 0
      );
      v_old_on_hand := 0;
    else
      v_old_on_hand := v_pos.on_hand_quantity;
      update public.inventory_positions
        set on_hand_quantity = v_qty,
            updated_at = now()
      where id = v_pos.id;
    end if;

    if v_qty <> v_old_on_hand then
      insert into public.stock_ledger_entries (
        variant_id, location_id, disposition, quantity_delta,
        reason, reference_type, actor_id
      ) values (
        v_item.variant_id, v_count.store_id, 'Prime',
        v_qty - v_old_on_hand,
        'inventory_count', 'inventory_count_item', v_emp.id::text
      );
    end if;

    update public.inventory_count_items
      set counted_quantity = v_qty,
          entered_by = v_emp.id,
          entered_at = now()
    where id = v_item.id;
  end loop;

  update public.inventory_counts
    set status = 'approved',
        approved_by = v_emp.id,
        approved_at = now(),
        updated_at = now()
  where id = p_count_id;
end;
$$;

grant execute on function public.finalize_inventory_count(uuid, uuid, jsonb) to authenticated;

-- 11. Cancel: the requester/starter, the store's manager, or owner/admin —
--     while the count is still non-terminal.

create or replace function public.cancel_inventory_count(
  p_count_id uuid,
  p_employee_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp public.employees%rowtype;
  v_count public.inventory_counts%rowtype;
begin
  v_emp := public.verify_count_employee(p_employee_id);

  select * into v_count
  from public.inventory_counts
  where id = p_count_id
  for update;

  if not found then raise exception 'Count not found'; end if;
  if not public.is_store_visible(v_count.store_id) then
    raise exception 'Count is not visible to this employee';
  end if;
  if v_count.status in ('approved', 'rejected', 'cancelled') then
    raise exception 'Count cannot be cancelled in status %', v_count.status;
  end if;

  if not (
    v_count.requested_by = v_emp.id
    or v_count.started_by = v_emp.id
    or v_emp.role::text in ('owner', 'admin')
    or (v_emp.role::text = 'manager' and v_emp.home_store_id = v_count.store_id)
  ) then
    raise exception 'Only the requester, this store''s manager, or an owner/admin can cancel a count';
  end if;

  update public.inventory_counts
    set status = 'cancelled',
        updated_at = now()
  where id = p_count_id;
end;
$$;

grant execute on function public.cancel_inventory_count(uuid, uuid) to authenticated;

-- 12. Cycle-count suggestion helper: footprint products at the store ordered
--     by staleness — never counted in an approved count first, then oldest
--     approved count first.

create or replace function public.suggest_inventory_count_items(
  p_store_id uuid,
  p_limit integer default 50
)
returns table (
  variant_id uuid,
  last_counted_at timestamptz
)
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  if not public.is_store_visible(p_store_id) then
    raise exception 'Store is not visible to this employee';
  end if;

  return query
  with footprint as (
    select pl.variant_id from public.par_levels pl where pl.store_id = p_store_id
    union
    select ip.variant_id from public.inventory_positions ip where ip.location_id = p_store_id
  ),
  last_counts as (
    select i.variant_id, max(c.approved_at) as counted_at
    from public.inventory_count_items i
    join public.inventory_counts c on c.id = i.count_id
    where c.store_id = p_store_id
      and c.status = 'approved'
    group by i.variant_id
  )
  select f.variant_id, lc.counted_at
  from footprint f
  left join last_counts lc on lc.variant_id = f.variant_id
  order by lc.counted_at asc nulls first, f.variant_id
  limit greatest(coalesce(p_limit, 50), 1);
end;
$$;

grant execute on function public.suggest_inventory_count_items(uuid, integer) to authenticated;

-- 13. Add a product to an in-progress count — for something found on the shelf
--     that wasn't in the original scope. Same authorization as entry. If the
--     variant is already in the count this is a clean no-op returning the
--     existing item's id, so the frontend can route the counter to its field.
--     Returns the inventory_count_items id either way.

create or replace function public.add_inventory_count_item(
  p_count_id uuid,
  p_employee_id uuid,
  p_variant_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_emp public.employees%rowtype;
  v_count public.inventory_counts%rowtype;
  v_item_id uuid;
begin
  v_emp := public.verify_count_employee(p_employee_id);

  select * into v_count
  from public.inventory_counts
  where id = p_count_id
  for update;

  if not found then raise exception 'Count not found'; end if;
  if not public.is_store_visible(v_count.store_id) then
    raise exception 'Count is not visible to this employee';
  end if;
  if v_count.status <> 'in_progress' then
    raise exception 'Items can only be added while the count is in progress';
  end if;
  if not public.can_enter_count(v_emp, v_count) then
    raise exception 'Only the requester, someone checked in at this store today, or this store''s manager, or an owner/admin can add items';
  end if;

  select i.id into v_item_id
  from public.inventory_count_items i
  where i.count_id = p_count_id
    and i.variant_id = p_variant_id;
  if found then
    return v_item_id;
  end if;

  if not exists (
    select 1 from public.products p
    where p.id = p_variant_id
      and p.company_id = v_count.company_id
  ) then
    raise exception 'Product does not belong to this company';
  end if;

  insert into public.inventory_count_items (
    count_id, variant_id, expected_quantity
  ) values (
    p_count_id, p_variant_id,
    coalesce((
      select ip.on_hand_quantity
      from public.inventory_positions ip
      where ip.variant_id = p_variant_id
        and ip.location_id = v_count.store_id
        and ip.disposition = 'Prime'
        and ip.sublocation_id is null
    ), 0)
  )
  returning id into v_item_id;

  return v_item_id;
end;
$$;

grant execute on function public.add_inventory_count_item(uuid, uuid, uuid) to authenticated;
