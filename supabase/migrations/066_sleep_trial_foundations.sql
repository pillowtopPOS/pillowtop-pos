-- 066_sleep_trial_foundations.sql
--
-- Sleep Trial Engine, phase ST-1 (docs/sleep-trial-engine.md Sections 26.1,
-- 27, 28, 33). Three foundations, no behavior changes yet:
--
--   1. Business timezones: companies.business_timezone (required) and
--      stores.timezone (optional override), plus business_today(store_id).
--      Nothing reads business_today until the evaluator lands in ST-4.
--   2. role_permission_grants: the Phase 7b manager toggles are fixed
--      boolean columns on companies and only cover the manager role, so
--      they can't hold arbitrary permission keys per role. This adds the
--      generic per-role-per-company registry the canonical spec describes,
--      seeded with the ten Sleep Trial keys from Section 27.
--   3. audit_events: append-only audit log; no generic audit table exists.
--
-- Write lockdown (062/065 pattern): no direct insert/update/delete for
-- authenticated on the new tables. Permission changes go through
-- set_role_permission; audit rows are written by log_audit_event, which is
-- only callable from inside security-definer functions.

-- ---------------------------------------------------------------------------
-- 1. Timezones
-- ---------------------------------------------------------------------------

alter table public.companies
  add column if not exists business_timezone text;

-- Backfill before enforcing NOT NULL. All existing tenants are single-timezone
-- Mountain (TBM) today; per-store overrides can be set afterwards.
update public.companies
  set business_timezone = 'America/Denver'
  where business_timezone is null;

alter table public.companies
  alter column business_timezone set not null;

alter table public.stores
  add column if not exists timezone text;

-- CHECK constraints can't query pg_timezone_names (no subqueries allowed), so
-- validation lives in a shared trigger. The column name arrives via TG_ARGV so
-- one function covers both tables.
create or replace function public.validate_timezone_column()
returns trigger
language plpgsql
as $$
declare
  v_tz text;
begin
  v_tz := to_jsonb(new) ->> TG_ARGV[0];
  if v_tz is not null and not exists (
    select 1 from pg_timezone_names tz where tz.name = v_tz
  ) then
    raise exception 'Invalid timezone "%" on %', v_tz, TG_TABLE_NAME;
  end if;
  return new;
end;
$$;

drop trigger if exists companies_business_timezone_valid on public.companies;
create trigger companies_business_timezone_valid
  before insert or update on public.companies
  for each row
  execute function public.validate_timezone_column('business_timezone');

drop trigger if exists stores_timezone_valid on public.stores;
create trigger stores_timezone_valid
  before insert or update on public.stores
  for each row
  execute function public.validate_timezone_column('timezone');

-- Business date for a store: today in the store's timezone, falling back to
-- the company timezone. Returns null for an unknown store.
create or replace function public.business_today(p_store_id uuid)
returns date
language sql
stable
security definer
set search_path = public
as $$
  select (now() at time zone coalesce(s.timezone, c.business_timezone))::date
  from public.stores s
  join public.companies c on c.id = s.company_id
  where s.id = p_store_id;
$$;

grant execute on function public.business_today(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------

-- The caller's company, derived through their home store. Used by the new RLS
-- policies below and by future Sleep Trial functions.
create or replace function public.current_employee_company_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select s.company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
  limit 1;
$$;

-- ---------------------------------------------------------------------------
-- 3. role_permission_grants
-- ---------------------------------------------------------------------------

create table if not exists public.role_permission_grants (
  id uuid primary key default gen_random_uuid(),
  -- Grants belong to the company; deleting a company removes them. (The seed
  -- trigger writes 35 rows per company, so without cascade a company delete
  -- would fail.)
  company_id uuid not null references public.companies (id) on delete cascade,
  role text not null, -- matches employees.role (employee_role enum values)
  permission_key text not null,
  created_at timestamptz not null default now(),
  created_by uuid references public.employees (id),
  unique (company_id, role, permission_key)
);

alter table public.role_permission_grants enable row level security;

drop policy if exists "Role permission grants viewable in own company" on public.role_permission_grants;
create policy "Role permission grants viewable in own company"
  on public.role_permission_grants for select
  to authenticated
  using (company_id = public.current_employee_company_id());

grant select on public.role_permission_grants to authenticated;
revoke insert, update, delete, truncate on public.role_permission_grants
  from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4. audit_events (append-only) + log_audit_event
-- ---------------------------------------------------------------------------

create table if not exists public.audit_events (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id),
  occurred_at timestamptz not null default now(),
  actor_employee_id uuid references public.employees (id),
  actor_type text not null check (actor_type in ('EMPLOYEE', 'SYSTEM')),
  entity_type text not null,
  entity_id uuid,
  journey_id uuid references public.sleep_journeys (id),
  event_type text not null,
  before jsonb,
  after jsonb,
  reason_code text,
  note text,
  request_id text
);

create index if not exists idx_audit_events_entity
  on public.audit_events (company_id, entity_type, entity_id);
create index if not exists idx_audit_events_event
  on public.audit_events (company_id, event_type, occurred_at);

alter table public.audit_events enable row level security;

drop policy if exists "Audit events viewable in own company" on public.audit_events;
create policy "Audit events viewable in own company"
  on public.audit_events for select
  to authenticated
  using (company_id = public.current_employee_company_id());

grant select on public.audit_events to authenticated;
-- Append-only: nobody mutates or removes audit rows. Inserts happen inside
-- security-definer functions (which run as the function owner), so
-- authenticated doesn't need any write grant at all. service_role bypasses
-- RLS and keeps full privileges for admin/tooling use.
revoke insert, update, delete, truncate on public.audit_events
  from anon, authenticated;

-- Internal audit writer. Company and actor default to the calling employee;
-- callers may pass p_company_id explicitly when the actor is a SYSTEM job.
create or replace function public.log_audit_event(
  p_company_id uuid,
  p_entity_type text,
  p_entity_id uuid,
  p_event_type text,
  p_before jsonb default null,
  p_after jsonb default null,
  p_reason_code text default null,
  p_note text default null,
  p_journey_id uuid default null,
  p_actor_type text default 'EMPLOYEE',
  p_actor_employee_id uuid default null,
  p_request_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := p_actor_employee_id;
  v_company uuid := p_company_id;
  v_id uuid;
begin
  if v_actor is null and p_actor_type = 'EMPLOYEE' then
    select e.id into v_actor
    from public.employees e
    where e.auth_user_id = auth.uid();
  end if;

  if v_company is null then
    if v_actor is not null then
      select s.company_id into v_company
      from public.employees e
      join public.stores s on s.id = e.home_store_id
      where e.id = v_actor;
    else
      v_company := public.current_employee_company_id();
    end if;
  end if;

  if v_company is null then
    raise exception 'log_audit_event: could not determine company';
  end if;

  insert into public.audit_events (
    company_id, actor_employee_id, actor_type, entity_type, entity_id,
    journey_id, event_type, before, after, reason_code, note, request_id
  ) values (
    v_company, v_actor, p_actor_type, p_entity_type, p_entity_id,
    p_journey_id, p_event_type, p_before, p_after, p_reason_code, p_note,
    p_request_id
  )
  returning id into v_id;

  return v_id;
end;
$$;

-- Internal-only: invoked by security-definer functions, never by clients.
revoke execute on function public.log_audit_event(uuid, text, uuid, text, jsonb, jsonb, text, text, uuid, text, uuid, text)
  from public, anon, authenticated;
revoke execute on function public.validate_timezone_column()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Sleep Trial permission seeds (Section 27 default grants)
-- ---------------------------------------------------------------------------

-- 'employee' remains a legal enum value (unassignable since 019 but still held
-- by existing employees), so it is seeded and shown like every other role.
create or replace function public.seed_sleep_trial_permission_defaults(p_company_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.role_permission_grants (company_id, role, permission_key)
  select p_company_id, g.role, g.permission_key
  from (
    values
      -- manage_concerns: all roles
      ('owner',    'sleep_trial.manage_concerns'),
      ('admin',    'sleep_trial.manage_concerns'),
      ('manager',  'sleep_trial.manage_concerns'),
      ('sales',    'sleep_trial.manage_concerns'),
      ('employee', 'sleep_trial.manage_concerns'),
      -- start_exchange: all roles
      ('owner',    'sleep_trial.start_exchange'),
      ('admin',    'sleep_trial.start_exchange'),
      ('manager',  'sleep_trial.start_exchange'),
      ('sales',    'sleep_trial.start_exchange'),
      ('employee', 'sleep_trial.start_exchange'),
      -- start_return: owner, admin, manager
      ('owner',    'sleep_trial.start_return'),
      ('admin',    'sleep_trial.start_return'),
      ('manager',  'sleep_trial.start_return'),
      -- request_exceptions: all roles
      ('owner',    'sleep_trial.request_exceptions'),
      ('admin',    'sleep_trial.request_exceptions'),
      ('manager',  'sleep_trial.request_exceptions'),
      ('sales',    'sleep_trial.request_exceptions'),
      ('employee', 'sleep_trial.request_exceptions'),
      -- approve_exceptions: owner, admin, manager
      ('owner',    'sleep_trial.approve_exceptions'),
      ('admin',    'sleep_trial.approve_exceptions'),
      ('manager',  'sleep_trial.approve_exceptions'),
      -- approve_own_exceptions: owner, admin
      ('owner',    'sleep_trial.approve_own_exceptions'),
      ('admin',    'sleep_trial.approve_own_exceptions'),
      -- override_protector: owner, admin
      ('owner',    'sleep_trial.override_protector'),
      ('admin',    'sleep_trial.override_protector'),
      -- correct_dates: owner, admin, manager
      ('owner',    'sleep_trial.correct_dates'),
      ('admin',    'sleep_trial.correct_dates'),
      ('manager',  'sleep_trial.correct_dates'),
      -- manage_policy: owner, admin
      ('owner',    'sleep_trial.manage_policy'),
      ('admin',    'sleep_trial.manage_policy'),
      -- view_policy_details: all roles
      ('owner',    'sleep_trial.view_policy_details'),
      ('admin',    'sleep_trial.view_policy_details'),
      ('manager',  'sleep_trial.view_policy_details'),
      ('sales',    'sleep_trial.view_policy_details'),
      ('employee', 'sleep_trial.view_policy_details')
  ) as g(role, permission_key)
  on conflict (company_id, role, permission_key) do nothing;
end;
$$;

-- New companies get the default grants automatically regardless of how the
-- company row is created (app, script, or SQL).
create or replace function public.seed_sleep_trial_permissions_on_company_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.seed_sleep_trial_permission_defaults(new.id);
  return new;
end;
$$;

drop trigger if exists companies_seed_sleep_trial_permissions on public.companies;
create trigger companies_seed_sleep_trial_permissions
  after insert on public.companies
  for each row
  execute function public.seed_sleep_trial_permissions_on_company_insert();

-- Backfill every existing company.
select public.seed_sleep_trial_permission_defaults(id)
from public.companies;

revoke execute on function public.seed_sleep_trial_permission_defaults(uuid)
  from public, anon, authenticated;
revoke execute on function public.seed_sleep_trial_permissions_on_company_insert()
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. has_permission + set_role_permission
-- ---------------------------------------------------------------------------

-- Does the current employee's role hold this grant in their company?
-- Owner always returns true so the company can never lock itself out.
create or replace function public.has_permission(p_key text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_role text;
  v_company_id uuid;
begin
  select e.role::text, s.company_id
    into v_role, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_role is null then
    return false;
  end if;

  if v_role = 'owner' then
    return true;
  end if;

  return exists (
    select 1
    from public.role_permission_grants g
    where g.company_id = v_company_id
      and g.role = v_role
      and g.permission_key = p_key
  );
end;
$$;

grant execute on function public.has_permission(text) to authenticated;

-- The only write path for role_permission_grants. Requires owner/admin,
-- refuses to strip owner (has_permission hardcodes owner = true anyway, so
-- removing a row would produce a grant grid that lies), and audits every
-- actual change.
create or replace function public.set_role_permission(
  p_role text,
  p_key text,
  p_granted boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor_id uuid;
  v_caller_role text;
  v_company_id uuid;
  v_grant_id uuid;
begin
  select e.id, e.role::text, s.company_id
    into v_actor_id, v_caller_role, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_actor_id is null then
    raise exception 'Not authenticated as an employee';
  end if;

  if v_caller_role not in ('owner', 'admin') then
    raise exception 'Only owners and admins can change permissions';
  end if;

  if not exists (
    select 1
    from unnest(enum_range(null::public.employee_role)) as v
    where v::text = p_role
  ) then
    raise exception 'Unknown role: %', p_role;
  end if;

  if p_key not in (
    'sleep_trial.manage_concerns',
    'sleep_trial.start_exchange',
    'sleep_trial.start_return',
    'sleep_trial.request_exceptions',
    'sleep_trial.approve_exceptions',
    'sleep_trial.approve_own_exceptions',
    'sleep_trial.override_protector',
    'sleep_trial.correct_dates',
    'sleep_trial.manage_policy',
    'sleep_trial.view_policy_details'
  ) then
    raise exception 'Unknown permission key: %', p_key;
  end if;

  if p_role = 'owner' and not p_granted then
    raise exception 'Owner permissions cannot be removed';
  end if;

  select id into v_grant_id
  from public.role_permission_grants
  where company_id = v_company_id
    and role = p_role
    and permission_key = p_key;

  if p_granted and v_grant_id is null then
    insert into public.role_permission_grants (company_id, role, permission_key, created_by)
    values (v_company_id, p_role, p_key, v_actor_id)
    returning id into v_grant_id;

    perform public.log_audit_event(
      p_company_id   := v_company_id,
      p_entity_type  := 'role_permission_grant',
      p_entity_id    := v_grant_id,
      p_event_type   := 'SLEEP_TRIAL_PERMISSION_GRANTED',
      p_after        := jsonb_build_object('role', p_role, 'permission_key', p_key, 'granted', true),
      p_actor_employee_id := v_actor_id
    );
  elsif not p_granted and v_grant_id is not null then
    delete from public.role_permission_grants where id = v_grant_id;

    perform public.log_audit_event(
      p_company_id   := v_company_id,
      p_entity_type  := 'role_permission_grant',
      p_entity_id    := v_grant_id,
      p_event_type   := 'SLEEP_TRIAL_PERMISSION_REVOKED',
      p_before       := jsonb_build_object('role', p_role, 'permission_key', p_key, 'granted', true),
      p_after        := jsonb_build_object('role', p_role, 'permission_key', p_key, 'granted', false),
      p_actor_employee_id := v_actor_id
    );
  end if;
  -- Granting an existing grant or revoking a missing one is a no-op; nothing
  -- changed, so nothing is audited.
end;
$$;

grant execute on function public.set_role_permission(text, text, boolean) to authenticated;
