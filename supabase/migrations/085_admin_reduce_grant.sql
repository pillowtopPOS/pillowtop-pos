-- 085_admin_reduce_grant.sql
--
-- Admins must be able to do everything managers can for the stock-shortage
-- override (084): 'admin' gains inventory.reduce_below_committed in the
-- permission defaults, existing companies are backfilled, and
-- set_role_permission's key whitelist gains the key so the Settings grid can
-- toggle it per role. has_permission stays generic — no role is hardcoded.

-- ============================================================================
-- 1. Permission defaults: add ('admin', 'inventory.reduce_below_committed')
-- ============================================================================

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
      ('employee', 'sleep_trial.view_policy_details'),
      -- reduce_below_committed (084 owner/manager, 085 admin):
      -- owner, admin, manager
      ('owner',    'inventory.reduce_below_committed'),
      ('admin',    'inventory.reduce_below_committed'),
      ('manager',  'inventory.reduce_below_committed')
  ) as g(role, permission_key)
  on conflict (company_id, role, permission_key) do nothing;
end;
$$;

revoke execute on function public.seed_sleep_trial_permission_defaults(uuid)
  from public, anon, authenticated;

-- Backfill existing companies (the companies-insert trigger already calls
-- this function for new ones); on conflict do nothing makes it idempotent.
select public.seed_sleep_trial_permission_defaults(id) from public.companies;

-- ============================================================================
-- 2. set_role_permission: whitelist gains 'inventory.reduce_below_committed'
--    so the owner/admin toggle in Settings works for this key. Otherwise
--    identical to the 066 definition.
-- ============================================================================

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
    'sleep_trial.view_policy_details',
    'inventory.reduce_below_committed'
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
