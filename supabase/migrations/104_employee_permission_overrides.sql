-- ============================================================================
-- PERM-1 Stage 1: per-employee permission overrides
--
-- One role per employee stays. Overrides sit on top: a grant adds a
-- permission the role lacks, a deny removes one the role has, and an
-- explicit override beats the role grant. Owners always have every
-- permission (the hardcode stays first) and can never be given an override.
--
-- The permission-key whitelist moves into ONE function so
-- set_role_permission and set_employee_permission can never drift.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Single source of truth for valid permission keys. Every key currently
--    in set_role_permission (the 101 definition, including units.*) plus
--    inventory.receive_po.
-- ----------------------------------------------------------------------------

create or replace function public.is_valid_permission_key(p_key text)
returns boolean
language sql
immutable
as $$
  select p_key in (
    'sleep_trial.manage_concerns',
    'sleep_trial.start_exchange',
    'sleep_trial.start_return',
    'sleep_trial.request_exceptions',
    'sleep_trial.approve_exceptions',
    'sleep_trial.approve_own_exceptions',
    'sleep_trial.override_protector',
    'sleep_trial.correct_dates',
    'sleep_trial.manage_policy',
    'sleep_trial.view_policy_details',
    'inventory.reduce_below_committed',
    'sleep_trial.complete_exchange',
    'inventory.inspect_returns',
    'inventory.manage_inspection_checklist',
    'sleep_trial.void_refund',
    'units.assign',
    'units.unassign',
    'units.override_set',
    'units.swap',
    'units.void',
    'units.manage_settings',
    'inventory.receive_po'
  );
$$;

revoke execute on function public.is_valid_permission_key(text) from anon;

-- ----------------------------------------------------------------------------
-- 2. employee_permission_overrides
--    RLS: a signed-in employee reads their own rows; an owner/admin of the
--    same company reads all rows for that company. No write policies; the
--    security-definer RPC is the only writer.
-- ----------------------------------------------------------------------------

create table if not exists public.employee_permission_overrides (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  employee_id uuid not null references public.employees (id) on delete cascade,
  permission_key text not null,
  granted boolean not null,
  created_at timestamptz not null default now(),
  created_by uuid references public.employees (id) on delete set null,
  unique (employee_id, permission_key)
);

create index if not exists idx_emp_perm_overrides_employee
  on public.employee_permission_overrides (employee_id);

alter table public.employee_permission_overrides enable row level security;

drop policy if exists "Employee permission overrides readable" on public.employee_permission_overrides;
create policy "Employee permission overrides readable"
  on public.employee_permission_overrides for select
  to authenticated
  using (
    employee_id = (
      select e.id from public.employees e
      where e.auth_user_id = auth.uid() and e.is_active
    )
    or (
      public.is_own_company(company_id)
      and coalesce((
        select e.role::text from public.employees e
        where e.auth_user_id = auth.uid() and e.is_active
      ), '') in ('owner', 'admin')
    )
  );

-- ----------------------------------------------------------------------------
-- 3. set_employee_permission: the only write path.
--    p_granted true = grant on top of the role, false = deny on top of the
--    role, null = clear the override (back to the role default).
-- ----------------------------------------------------------------------------

create or replace function public.set_employee_permission(
  p_employee_id uuid,
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
  v_target_company uuid;
  v_target_role text;
  v_override_id uuid;
  v_old_granted boolean;
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

  select s.company_id, e.role::text
    into v_target_company, v_target_role
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.id = p_employee_id;

  if v_target_company is null or v_target_company <> v_company_id then
    raise exception 'That employee is not in your company.';
  end if;

  if v_target_role = 'owner' then
    raise exception 'Owners always have every permission.';
  end if;

  if not public.is_valid_permission_key(p_key) then
    raise exception 'Unknown permission key: %', p_key;
  end if;

  select id, granted into v_override_id, v_old_granted
  from public.employee_permission_overrides
  where employee_id = p_employee_id and permission_key = p_key;

  if p_granted is null then
    -- Clear: only a real row is removed and audited.
    if v_override_id is not null then
      delete from public.employee_permission_overrides
      where id = v_override_id;
      perform public.log_audit_event(
        p_company_id   := v_company_id,
        p_entity_type  := 'employee_permission_override',
        p_entity_id    := v_override_id,
        p_event_type   := 'EMPLOYEE_PERMISSION_CLEARED',
        p_before       := jsonb_build_object('employee_id', p_employee_id, 'permission_key', p_key, 'granted', v_old_granted),
        p_after        := jsonb_build_object('employee_id', p_employee_id, 'permission_key', p_key, 'granted', null),
        p_actor_employee_id := v_actor_id
      );
    end if;
    return;
  end if;

  if v_override_id is not null and v_old_granted = p_granted then
    -- Same value again: nothing changed, nothing audited.
    return;
  end if;

  insert into public.employee_permission_overrides
    (company_id, employee_id, permission_key, granted, created_by)
  values (v_company_id, p_employee_id, p_key, p_granted, v_actor_id)
  on conflict (employee_id, permission_key)
  do update set granted = excluded.granted
  returning id into v_override_id;

  perform public.log_audit_event(
    p_company_id   := v_company_id,
    p_entity_type  := 'employee_permission_override',
    p_entity_id    := v_override_id,
    p_event_type   := case when p_granted
        then 'EMPLOYEE_PERMISSION_GRANTED'
        else 'EMPLOYEE_PERMISSION_DENIED' end,
    p_before       := jsonb_build_object('employee_id', p_employee_id, 'permission_key', p_key, 'granted', v_old_granted),
    p_after        := jsonb_build_object('employee_id', p_employee_id, 'permission_key', p_key, 'granted', p_granted),
    p_actor_employee_id := v_actor_id
  );
end;
$$;

grant execute on function public.set_employee_permission(uuid, text, boolean) to authenticated;

-- ----------------------------------------------------------------------------
-- 4. has_permission: owner hardcode first, then the caller's override row,
--    then the role grant. Everything else copied from 066:349-379.
-- ----------------------------------------------------------------------------

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
  v_override boolean;
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

  -- An explicit per-employee override beats the role grant.
  select o.granted into v_override
  from public.employee_permission_overrides o
  join public.employees e on e.id = o.employee_id
  where o.employee_id = (select e2.id from public.employees e2
                          where e2.auth_user_id = auth.uid() and e2.is_active)
    and o.company_id = v_company_id
    and o.permission_key = p_key;

  if v_override is not null then
    return v_override;
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

-- ----------------------------------------------------------------------------
-- 5. set_role_permission: the 101 definition with the inline whitelist
--    replaced by the shared helper. Only that one condition changed.
-- ----------------------------------------------------------------------------

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

  if not public.is_valid_permission_key(p_key) then
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

-- ----------------------------------------------------------------------------
-- 6. Seed inventory.receive_po for owner/admin/manager, matching the
--    role check receive_purchase_order_line used before migration 105.
--    Same pattern as the units seed in 101.
-- ----------------------------------------------------------------------------

create or replace function public.seed_inventory_receive_permission(p_company_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.role_permission_grants (company_id, role, permission_key)
  select p_company_id, g.role, 'inventory.receive_po'
  from (values ('owner'), ('admin'), ('manager')) as g (role)
  on conflict do nothing;
end;
$$;

revoke execute on function public.seed_inventory_receive_permission(uuid)
  from authenticated, anon, public;

-- Seed existing companies once at migration time.
do $$
declare
  v_company uuid;
begin
  for v_company in select id from public.companies loop
    perform public.seed_inventory_receive_permission(v_company);
  end loop;
end $$;

-- Seed future companies on insert (name sorts safely alongside the
-- trg_companies_seed_permissions and trg_companies_seed_unit_permissions
-- triggers; all three are independent inserts, so order does not matter).
create or replace function public.trg_seed_inventory_receive_permission()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.seed_inventory_receive_permission(new.id);
  return new;
end;
$$;

revoke execute on function public.trg_seed_inventory_receive_permission()
  from authenticated, anon, public;

drop trigger if exists trg_companies_seed_inventory_receive_permission on public.companies;
create trigger trg_companies_seed_inventory_receive_permission
after insert on public.companies
for each row execute function public.trg_seed_inventory_receive_permission();

-- ----------------------------------------------------------------------------
-- 7. Install confirmation
-- ----------------------------------------------------------------------------
select
  (select count(*) from public.employee_permission_overrides) as override_rows,
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'has_permission'
  ) as has_permission_exists,
  exists (
    select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'set_employee_permission'
  ) as set_employee_permission_exists,
  (select count(*) from public.role_permission_grants
    where permission_key = 'inventory.receive_po') as receive_po_grants;
