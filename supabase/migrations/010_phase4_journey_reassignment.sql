-- Phase 4: Journey reassignment (store and owning employee)
--
-- Follows the existing append-only pattern: the application inserts a row into
-- the log table and a trigger applies the resulting change to sleep_journeys.
-- current_state is never touched by a reassignment.

-- 1. Reassignment log table

create table if not exists public.journey_reassignment_events (
  id uuid primary key default gen_random_uuid(),
  journey_id uuid not null references public.sleep_journeys (id) on delete cascade,
  from_store_id uuid references public.stores (id) on delete set null,
  to_store_id uuid references public.stores (id) on delete set null,
  from_employee_id uuid references public.employees (id) on delete set null,
  to_employee_id uuid references public.employees (id) on delete set null,
  reason text,
  actor_employee_id uuid references public.employees (id) on delete set null,
  created_at timestamptz not null default now()
);

comment on table public.journey_reassignment_events is
  'Append-only log of Sleep Journey store/employee reassignments';

create index if not exists idx_journey_reassignment_events_journey
  on public.journey_reassignment_events (journey_id, created_at desc);

alter table public.journey_reassignment_events enable row level security;

-- 2. Permission helper: who may reassign journeys

create or replace function public.can_reassign_journeys()
returns boolean
language plpgsql
security definer
stable
set search_path = public
as $$
begin
  return exists (
    select 1 from public.employees
    where auth_user_id = auth.uid()
      and role::text in ('owner', 'admin', 'manager')
  );
end;
$$;

-- 3. Policies

drop policy if exists "Journey reassignments viewable by authenticated users"
  on public.journey_reassignment_events;
create policy "Journey reassignments viewable by authenticated users"
  on public.journey_reassignment_events for select
  to authenticated
  using (public.is_journey_visible(journey_id));

drop policy if exists "Journey reassignments insertable by owner/admin/manager"
  on public.journey_reassignment_events;
create policy "Journey reassignments insertable by owner/admin/manager"
  on public.journey_reassignment_events for insert
  to authenticated
  with check (
    public.can_reassign_journeys()
    and public.is_journey_visible(journey_id)
  );

-- 4. Fill in the "from" side and the actor from the current journey / session

create or replace function public.prepare_journey_reassignment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  cur_store_id uuid;
  cur_employee_id uuid;
  journey_company_id uuid;
  target_company_id uuid;
begin
  select sj.store_id, sj.assigned_employee_id
  into cur_store_id, cur_employee_id
  from public.sleep_journeys sj
  where sj.id = new.journey_id;

  if not found then
    raise exception 'Journey % not found', new.journey_id;
  end if;

  new.from_store_id := cur_store_id;
  new.from_employee_id := cur_employee_id;

  if new.actor_employee_id is null then
    new.actor_employee_id := (
      select id from public.employees where auth_user_id = auth.uid() limit 1
    );
  end if;

  if new.to_store_id is null and new.to_employee_id is null then
    raise exception 'A reassignment must set a target store or a target employee';
  end if;

  select company_id into journey_company_id from public.stores where id = cur_store_id;

  if new.to_store_id is not null then
    select company_id into target_company_id
    from public.stores
    where id = new.to_store_id and is_active;

    if target_company_id is null or target_company_id is distinct from journey_company_id then
      raise exception 'Target store is not an active store in this company';
    end if;
  end if;

  if new.to_employee_id is not null then
    if not exists (
      select 1 from public.employees e
      where e.id = new.to_employee_id
        and e.home_store_id = coalesce(new.to_store_id, cur_store_id)
    ) then
      raise exception 'Target employee does not belong to the journey store';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists journey_reassignment_prepare on public.journey_reassignment_events;
create trigger journey_reassignment_prepare
  before insert on public.journey_reassignment_events
  for each row
  execute function public.prepare_journey_reassignment();

-- 5. Apply the reassignment to the journey (never touches current_state)

create or replace function public.apply_journey_reassignment()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.sleep_journeys
  set store_id = coalesce(new.to_store_id, store_id),
      assigned_employee_id = case
        when new.to_employee_id is not null then new.to_employee_id
        else assigned_employee_id
      end,
      updated_at = now()
  where id = new.journey_id;

  return new;
end;
$$;

drop trigger if exists journey_reassignment_apply on public.journey_reassignment_events;
create trigger journey_reassignment_apply
  after insert on public.journey_reassignment_events
  for each row
  execute function public.apply_journey_reassignment();

-- 6. Realtime

do $$
begin
  if not exists (
    select 1
    from pg_publication_rel pr
    join pg_publication p on pr.prpubid = p.oid
    where p.pubname = 'supabase_realtime'
      and pr.prrelid = 'public.journey_reassignment_events'::regclass
  ) then
    alter publication supabase_realtime add table public.journey_reassignment_events;
  end if;
end
$$;
