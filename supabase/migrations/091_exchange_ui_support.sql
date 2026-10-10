-- ============================================================================
-- Migration 091 — EB-3b: exchange milestone card, cancel, refund void,
-- complete, My Work support
--
--   A. sleep_trial.void_refund permission (seed + whitelist + backfill)
--   B. companies.exchange_stalled_days
--   C. sleep_trial_actions.refund_history + void_exchange_refund
--   D. cancel_sleep_trial_action: any start_exchange holder, required reason
--   E. record_exchange_refund: journey_interactions notes on both journeys
--   F. cancel guard for the ORIGINAL journey (parent of a COMMITTED action)
--   G. get_exchange_action: milestones, flags, blockers, refund history
--   H. list_open_exchange_work: derived My Work feed
--
-- All create-or-replace or additive. Check guards precede every column add.
-- ============================================================================

-- ============================================================================
-- A. Permissions — sleep_trial.void_refund (owner, admin defaults)
--    Bodies are the 087 functions verbatim except the one added key each.
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
      ('manager',  'inventory.reduce_below_committed'),
      -- complete_exchange (spec 12): owner, admin
      ('owner',    'sleep_trial.complete_exchange'),
      ('admin',    'sleep_trial.complete_exchange'),
      -- inspect_returns (spec 12): owner, admin, manager
      ('owner',    'inventory.inspect_returns'),
      ('admin',    'inventory.inspect_returns'),
      ('manager',  'inventory.inspect_returns'),
      -- manage_inspection_checklist (spec 12): owner, admin
      ('owner',    'inventory.manage_inspection_checklist'),
      ('admin',    'inventory.manage_inspection_checklist'),
      -- void_refund (EB-3b): owner, admin
      ('owner',    'sleep_trial.void_refund'),
      ('admin',    'sleep_trial.void_refund')
  ) as g(role, permission_key)
  on conflict (company_id, role, permission_key) do nothing;
end;
$$;

revoke execute on function public.seed_sleep_trial_permission_defaults(uuid)
  from public, anon, authenticated;

-- Backfill existing companies; on conflict do nothing makes it idempotent.
select public.seed_sleep_trial_permission_defaults(id) from public.companies;

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
    'inventory.reduce_below_committed',
    'sleep_trial.complete_exchange',
    'inventory.inspect_returns',
    'inventory.manage_inspection_checklist',
    'sleep_trial.void_refund'
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

-- ============================================================================
-- B. Company setting — exchange stalled threshold (days)
-- ============================================================================

alter table public.companies
  add column if not exists exchange_stalled_days integer not null default 14;

alter table public.companies
  drop constraint if exists companies_exchange_stalled_days_check;
alter table public.companies
  add constraint companies_exchange_stalled_days_check
  check (exchange_stalled_days > 0);

-- ============================================================================
-- C. Refund history + void_exchange_refund
--
-- The recorded refund is never erased: a full snapshot is appended to
-- refund_history first, THEN the active refund_* columns are cleared. Every
-- consumer keyed on refund_recorded_at (banner, duplicate-record check,
-- complete milestone, cancel check) therefore works unchanged.
-- ============================================================================

alter table public.sleep_trial_actions
  add column if not exists refund_history jsonb not null default '[]';

create or replace function public.void_exchange_refund(
  p_action_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_journey public.sleep_journeys%rowtype;
  v_employee uuid;
  v_employee_name text;
  v_recorded_by_name text;
  v_snapshot jsonb;
begin
  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id
  for update;
  if not found then
    raise exception 'Exchange action not found';
  end if;
  if not public.is_journey_visible(v_action.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  if not public.has_permission('sleep_trial.void_refund') then
    raise exception 'Missing permission: sleep_trial.void_refund';
  end if;
  select e.id, e.name into v_employee, v_employee_name
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'A reason is required to void a refund';
  end if;
  if v_action.status <> 'COMMITTED' then
    raise exception 'Only a committed exchange can void a refund (status %)',
      v_action.status;
  end if;
  if v_action.refund_recorded_at is null then
    raise exception 'No recorded refund to void on this exchange';
  end if;

  select e.name into v_recorded_by_name
  from public.employees e
  where e.id = v_action.refund_recorded_by;

  -- Snapshot FIRST: the voided record stays readable in refund_history
  -- forever; the active columns are cleared afterwards.
  v_snapshot := jsonb_build_object(
    'refund_method', v_action.refund_method,
    'refund_amount_cents', v_action.refund_amount_cents,
    'refund_reference', v_action.refund_reference,
    'recorded_by', v_action.refund_recorded_by,
    'recorded_by_name', v_recorded_by_name,
    'recorded_at', v_action.refund_recorded_at,
    'voided_by', v_employee,
    'voided_by_name', v_employee_name,
    'voided_at', now(),
    'void_reason', btrim(p_reason));

  update public.sleep_trial_actions
  set refund_history = refund_history || jsonb_build_array(v_snapshot),
      refund_method = null,
      refund_amount_cents = null,
      refund_reference = null,
      refund_recorded_by = null,
      refund_recorded_at = null
  where id = v_action.id;

  perform public.log_audit_event(
    p_company_id := v_action.company_id,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action.id,
    p_event_type := 'EXCHANGE_REFUND_VOIDED',
    p_before := v_snapshot,
    p_after := jsonb_build_object(
      'refund_recorded_at', null,
      'refund_history_count',
        jsonb_array_length(v_action.refund_history) + 1),
    p_journey_id := v_action.journey_id,
    p_actor_employee_id := v_employee);

  select * into v_journey
  from public.sleep_journeys
  where id = v_action.journey_id;

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain,
    source_record_id, is_internal
  ) values (
    v_action.journey_id, v_journey.customer_id,
    'internal_note', 'internal', 'internal', 'return_exchange',
    'Exchange refund voided by ' || coalesce(v_employee_name, 'an employee')
      || ' — ' || btrim(p_reason)
      || ' (was ' || coalesce(v_action.refund_method, '?')
      || ' $' || to_char(coalesce(v_action.refund_amount_cents, 0) / 100.0,
                          'FM999999990.00') || ')',
    v_employee, 'sleep_trial_action', v_action.id, true
  );
  if v_action.child_journey_id is not null then
    insert into public.journey_interactions (
      journey_id, customer_id, interaction_type, channel, direction,
      topic, summary, created_by_employee_id, source_domain,
      source_record_id, is_internal
    ) values (
      v_action.child_journey_id, v_journey.customer_id,
      'internal_note', 'internal', 'internal', 'return_exchange',
      'Exchange refund voided — the refund is owed again',
      v_employee, 'sleep_trial_action', v_action.id, true
    );
  end if;
end;
$$;

revoke execute on function public.void_exchange_refund(uuid, text)
  from public, anon;
grant execute on function public.void_exchange_refund(uuid, text)
  to authenticated;

-- ============================================================================
-- D. cancel_sleep_trial_action — 088 body, two changes:
--    * permission: has_permission('sleep_trial.start_exchange') replaces the
--      starter-or-complete_exchange rule (any exchange starter may cancel);
--    * a non-empty reason is required.
--    Every other refusal and its text is unchanged.
-- ============================================================================

create or replace function public.cancel_sleep_trial_action(
  p_action_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_journey public.sleep_journeys%rowtype;
  v_employee uuid;
  v_employee_name text;
begin
  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id
  for update;
  if not found then
    raise exception 'Exchange action not found';
  end if;
  if not public.is_journey_visible(v_action.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select e.id, e.name into v_employee, v_employee_name
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;
  if not public.has_permission('sleep_trial.start_exchange') then
    raise exception 'Missing permission: sleep_trial.start_exchange';
  end if;

  if v_action.status <> 'COMMITTED' then
    raise exception 'Only a committed exchange can be cancelled (status %)',
      v_action.status;
  end if;

  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'A reason is required to cancel an exchange';
  end if;
  if v_action.original_received_on is not null then
    raise exception 'The original mattress was already received — this exchange cannot be cancelled';
  end if;
  if v_action.refund_recorded_at is not null then
    raise exception 'A refund was already recorded on this exchange — it cannot be cancelled';
  end if;
  if exists (
    select 1 from public.sleep_journeys sj
    where sj.id = v_action.child_journey_id
      and sj.delivered_at is not null) then
    raise exception 'The replacement was already delivered — this exchange cannot be cancelled';
  end if;
  if exists (
    select 1 from public.journey_events je
    where je.journey_id = v_action.child_journey_id
      and je.event_type in ('deposit_received','payment_completed')
      and je.outcome = 'SUCCEEDED') then
    raise exception 'The replacement has a payment on record — resolve it before cancelling the exchange';
  end if;

  select * into v_journey
  from public.sleep_journeys
  where id = v_action.journey_id;

  -- Let the BEFORE INSERT guard pass for this action only, then cancel
  -- the child through the standard event (state, follow-ups, written
  -- sale and inventory hooks all hang off journey_cancelled).
  perform set_config('pillowtop.exchange_cancel', v_action.id::text, true);
  if v_action.child_journey_id is not null then
    insert into public.journey_events (
      journey_id, event_type, event_data, triggered_by
    ) values (
      v_action.child_journey_id,
      'journey_cancelled',
      jsonb_build_object(
        'reason', coalesce(nullif(btrim(p_reason), ''), 'Exchange cancelled')),
      auth.uid()::text
    );
  end if;

  perform public.stv_action_reopen_item(v_action.trial_item_id);

  update public.sleep_trial_actions
  set status = 'CANCELLED',
      cancelled_by = v_employee,
      cancelled_at = now(),
      cancel_reason = nullif(btrim(p_reason), '')
  where id = v_action.id;

  perform public.log_audit_event(
    p_company_id := v_action.company_id,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action.id,
    p_event_type := 'EXCHANGE_CANCELLED',
    p_after := jsonb_build_object(
      'status', 'CANCELLED',
      'reason', nullif(btrim(p_reason), ''),
      'child_journey_id', v_action.child_journey_id),
    p_journey_id := v_action.journey_id,
    p_actor_employee_id := v_employee);

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain,
    source_record_id, is_internal
  ) values (
    v_action.journey_id, v_journey.customer_id,
    'internal_note', 'internal', 'internal', 'return_exchange',
    'Exchange cancelled by ' || coalesce(v_employee_name, 'an employee')
      || coalesce(' — ' || nullif(btrim(p_reason), ''), ''),
    v_employee, 'sleep_trial_action', v_action.id, true
  );
  if v_action.child_journey_id is not null then
    insert into public.journey_interactions (
      journey_id, customer_id, interaction_type, channel, direction,
      topic, summary, created_by_employee_id, source_domain,
      source_record_id, is_internal
    ) values (
      v_action.child_journey_id, v_journey.customer_id,
      'internal_note', 'internal', 'internal', 'return_exchange',
      'Replacement journey cancelled with the exchange',
      v_employee, 'sleep_trial_action', v_action.id, true
    );
  end if;
end;
$$;

revoke execute on function public.cancel_sleep_trial_action(uuid, text)
  from public, anon;
grant execute on function public.cancel_sleep_trial_action(uuid, text)
  to authenticated;

-- ============================================================================
-- E. record_exchange_refund — 088 body plus journey_interactions notes on
--    both journeys (cancel and complete already write them).
-- ============================================================================

create or replace function public.record_exchange_refund(
  p_action_id uuid,
  p_method text,
  p_amount_cents integer,
  p_reference text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_journey public.sleep_journeys%rowtype;
  v_employee uuid;
  v_employee_name text;
begin
  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id
  for update;
  if not found then
    raise exception 'Exchange action not found';
  end if;
  if not public.is_journey_visible(v_action.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  if not public.has_permission('sleep_trial.complete_exchange') then
    raise exception 'Missing permission: sleep_trial.complete_exchange';
  end if;
  select e.id, e.name into v_employee, v_employee_name
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;

  if v_action.status <> 'COMMITTED' then
    raise exception 'Only a committed exchange can record a refund (status %)',
      v_action.status;
  end if;
  if coalesce(v_action.refund_owed_cents, 0) <= 0 then
    raise exception 'No refund is owed on this exchange';
  end if;
  if v_action.refund_recorded_at is not null then
    raise exception 'A refund was already recorded on this exchange';
  end if;

  if p_method not in ('card','cash','check','store_credit','none') then
    raise exception 'refund method must be card, cash, check, store_credit or none';
  end if;
  if p_amount_cents is null or p_amount_cents < 0 then
    raise exception 'refund amount must be a non-negative integer cents value';
  end if;
  if p_amount_cents is distinct from v_action.refund_owed_cents
     and nullif(btrim(coalesce(p_reference, '')), '') is null then
    raise exception 'The amount differs from the owed refund — a reference is required to document a different settled amount';
  end if;

  update public.sleep_trial_actions
  set refund_method = p_method,
      refund_amount_cents = p_amount_cents,
      refund_reference = nullif(btrim(p_reference), ''),
      refund_recorded_by = v_employee,
      refund_recorded_at = now()
  where id = v_action.id;

  perform public.log_audit_event(
    p_company_id := v_action.company_id,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action.id,
    p_event_type := 'EXCHANGE_REFUND_RECORDED',
    p_after := jsonb_build_object(
      'refund_method', p_method,
      'refund_amount_cents', p_amount_cents,
      'refund_owed_cents', v_action.refund_owed_cents,
      'refund_reference', nullif(btrim(p_reference), '')),
    p_journey_id := v_action.journey_id,
    p_actor_employee_id := v_employee);

  select * into v_journey
  from public.sleep_journeys
  where id = v_action.journey_id;

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain,
    source_record_id, is_internal
  ) values (
    v_action.journey_id, v_journey.customer_id,
    'internal_note', 'internal', 'internal', 'return_exchange',
    'Exchange refund recorded by ' || coalesce(v_employee_name, 'an employee')
      || ' — ' || p_method
      || ' $' || to_char(p_amount_cents / 100.0, 'FM999999990.00')
      || coalesce(' (ref ' || nullif(btrim(p_reference), '') || ')', ''),
    v_employee, 'sleep_trial_action', v_action.id, true
  );
  if v_action.child_journey_id is not null then
    insert into public.journey_interactions (
      journey_id, customer_id, interaction_type, channel, direction,
      topic, summary, created_by_employee_id, source_domain,
      source_record_id, is_internal
    ) values (
      v_action.child_journey_id, v_journey.customer_id,
      'internal_note', 'internal', 'internal', 'return_exchange',
      'Exchange refund recorded — see the original journey for details',
      v_employee, 'sleep_trial_action', v_action.id, true
    );
  end if;
end;
$$;

revoke execute on function public.record_exchange_refund(uuid, text, integer, text)
  from public, anon;
grant execute on function public.record_exchange_refund(uuid, text, integer, text)
  to authenticated;

-- ============================================================================
-- F. Guard the ORIGINAL journey, next to the child guard. A journey that is
--    the parent of a COMMITTED action cannot be cancelled — the trigger is
--    BEFORE INSERT on journey_events, so it fires before the state write
--    that would reach stv_on_journey_cancel (069) and void the item.
--    The exchange's own cancel path inserts journey_cancelled on the CHILD,
--    so the parent check never conflicts with pillowtop.exchange_cancel.
-- ============================================================================

create or replace function public.stv_guard_exchange_journey_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action_id uuid;
begin
  if new.event_type <> 'journey_cancelled' then
    return new;
  end if;

  -- Parent of a COMMITTED action: refuse outright.
  if exists (
    select 1
    from public.sleep_trial_actions a
    where a.journey_id = new.journey_id
      and a.status = 'COMMITTED'
  ) then
    raise exception 'This journey has an exchange in progress. Cancel the exchange first.';
  end if;

  select sj.exchange_action_id into v_action_id
  from public.sleep_journeys sj
  join public.sleep_trial_actions a on a.id = sj.exchange_action_id
  where sj.id = new.journey_id
    and a.status = 'COMMITTED';

  if v_action_id is not null
     and current_setting('pillowtop.exchange_cancel', true)
         is distinct from v_action_id::text then
    raise exception 'Cancel this replacement from the exchange, not from the journey.';
  end if;

  return new;
end;
$$;

revoke execute on function public.stv_guard_exchange_journey_cancel()
  from public, anon, authenticated;

-- ============================================================================
-- G. get_exchange_action — extended for the milestone card and action
--    buttons. Adds: milestone objects, refund history + actor names,
--    child money facts, permission/blocker flags computed server-side,
--    and complete_blockers in the exact check order of
--    complete_sleep_trial_action.
-- ============================================================================

create or replace function public.get_exchange_action(
  p_action_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_repl_name text;
  v_creator_name text;
  v_committed_by_name text;
  v_completed_by_name text;
  v_cancelled_by_name text;
  v_refund_recorded_by_name text;
  v_child public.sleep_journeys%rowtype;
  v_child_paid numeric := 0;
  v_child_paid_at timestamptz;
  v_child_has_payment boolean := false;
  v_can_start boolean;
  v_can_complete boolean;
  v_can_void boolean;
  v_money_done boolean;
  v_money_at timestamptz;
  v_money_by uuid;
  v_money_by_name text;
  v_block_code text;
  v_block_msg text;
  v_blockers jsonb;
begin
  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id;
  if not found then
    raise exception 'Exchange action not found';
  end if;
  if not public.is_journey_visible(v_action.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select p.item_name into v_repl_name
  from public.products p
  where p.id = v_action.replacement_product_id;

  select e.name into v_creator_name
  from public.employees e
  where e.id = v_action.created_by;
  select e.name into v_committed_by_name
  from public.employees e
  where e.id = v_action.committed_by;
  select e.name into v_completed_by_name
  from public.employees e
  where e.id = v_action.completed_by;
  select e.name into v_cancelled_by_name
  from public.employees e
  where e.id = v_action.cancelled_by;
  select e.name into v_refund_recorded_by_name
  from public.employees e
  where e.id = v_action.refund_recorded_by;

  if v_action.child_journey_id is not null then
    select * into v_child
    from public.sleep_journeys
    where id = v_action.child_journey_id;

    v_child_paid := coalesce(public.total_paid(v_action.child_journey_id), 0);
    select exists (
      select 1 from public.journey_events je
      where je.journey_id = v_action.child_journey_id
        and je.event_type in ('deposit_received','payment_completed')
        and je.outcome = 'SUCCEEDED')
    into v_child_has_payment;
    select max(je.created_at) into v_child_paid_at
    from public.journey_events je
    where je.journey_id = v_action.child_journey_id
      and je.event_type in ('deposit_received','payment_completed')
      and je.outcome = 'SUCCEEDED';
  end if;

  v_can_start := public.has_permission('sleep_trial.start_exchange');
  v_can_complete := public.has_permission('sleep_trial.complete_exchange');
  v_can_void := public.has_permission('sleep_trial.void_refund');

  -- Money settled: a recorded refund when one is owed, else the child's
  -- price fully paid (a $0 replacement is settled by definition).
  v_money_done :=
    (coalesce(v_action.refund_owed_cents, 0) > 0
       and v_action.refund_recorded_at is not null)
    or (coalesce(v_action.refund_owed_cents, 0) <= 0
        and v_child.id is not null
        and v_child_paid >= coalesce(v_child.price, 0));
  if coalesce(v_action.refund_owed_cents, 0) > 0
     and v_action.refund_recorded_at is not null then
    v_money_at := v_action.refund_recorded_at;
    v_money_by := v_action.refund_recorded_by;
    v_money_by_name := v_refund_recorded_by_name;
  else
    v_money_at := v_child_paid_at;
    v_money_by := null;
    v_money_by_name := null;
  end if;

  -- Cancel blockers, same order and wording as cancel_sleep_trial_action.
  v_block_code := null;
  v_block_msg := null;
  if v_action.status <> 'COMMITTED' then
    v_block_code := 'not_committed';
    v_block_msg := 'Only a committed exchange can be cancelled';
  elsif v_action.original_received_on is not null then
    v_block_code := 'original_received';
    v_block_msg := 'The original mattress was already received — this exchange cannot be cancelled';
  elsif v_action.refund_recorded_at is not null then
    v_block_code := 'refund_recorded';
    v_block_msg := 'A refund was already recorded on this exchange — it cannot be cancelled';
  elsif v_child.id is not null and v_child.delivered_at is not null then
    v_block_code := 'replacement_delivered';
    v_block_msg := 'The replacement was already delivered — this exchange cannot be cancelled';
  elsif v_child_has_payment then
    v_block_code := 'payment_on_record';
    v_block_msg := 'The replacement has a payment on record — resolve it before cancelling the exchange';
  end if;

  -- Complete blockers in the exact check order of
  -- complete_sleep_trial_action (all unmet, not just the first).
  select coalesce(jsonb_agg(t.m order by t.ord), '[]'::jsonb)
  into v_blockers
  from (
    values
      (1, 'The replacement has not been delivered yet',
          v_action.replacement_delivered_on is null),
      (2, 'The original mattress has not been marked received yet',
          v_action.original_received_on is null),
      (3, 'The replacement still has an unpaid balance',
          v_child.id is not null
            and coalesce(v_child.price, 0) > 0
            and v_child_paid < v_child.price),
      (4, 'The owed refund has not been recorded yet',
          coalesce(v_action.refund_owed_cents, 0) > 0
            and v_action.refund_recorded_at is null)
  ) as t(ord, m, is_open)
  where t.is_open;

  return jsonb_build_object(
    'action_id', v_action.id,
    'status', v_action.status,
    'action', v_action.action,
    'trial_item_id', v_action.trial_item_id,
    'journey_id', v_action.journey_id,
    'child_journey_id', v_action.child_journey_id,
    'replacement_product_id', v_action.replacement_product_id,
    'replacement_product_name', v_repl_name,
    'replacement_price_cents', v_action.replacement_price_cents,
    'original_credit_cents', v_action.original_credit_cents,
    'exchange_fee_cents', v_action.exchange_fee_cents,
    'other_fees_cents', v_action.other_fees_cents,
    'tax_cents', v_action.tax_cents,
    'net_cents', v_action.net_cents,
    'refund_owed_cents', v_action.refund_owed_cents,
    'refund_method', v_action.refund_method,
    'refund_amount_cents', v_action.refund_amount_cents,
    'refund_reference', v_action.refund_reference,
    'refund_recorded_at', v_action.refund_recorded_at,
    'refund_recorded_by', v_action.refund_recorded_by,
    'refund_recorded_by_name', v_refund_recorded_by_name,
    'refund_history', v_action.refund_history,
    'original_received_on', v_action.original_received_on,
    'replacement_delivered_on', v_action.replacement_delivered_on,
    'completed_at', v_action.completed_at,
    'completed_by', v_action.completed_by,
    'completed_by_name', v_completed_by_name,
    'cancelled_at', v_action.cancelled_at,
    'cancelled_by', v_action.cancelled_by,
    'cancelled_by_name', v_cancelled_by_name,
    'cancel_reason', v_action.cancel_reason,
    'fulfillment_method', v_action.fulfillment_method,
    'created_by', v_action.created_by,
    'created_by_name', v_creator_name,
    'created_at', v_action.created_at,
    'committed_at', v_action.committed_at,
    'committed_by', v_action.committed_by,
    'committed_by_name', v_committed_by_name,
    'child_price', v_child.price,
    'child_total_paid', v_child_paid,
    'child_has_succeeded_payment', v_child_has_payment,
    'milestones', jsonb_build_object(
      'replacement_reserved', jsonb_build_object(
        'done', v_action.committed_at is not null,
        'at', v_action.committed_at,
        'by', v_committed_by_name),
      'replacement_delivered', jsonb_build_object(
        'done', v_action.replacement_delivered_on is not null,
        'at', v_action.replacement_delivered_on,
        'by', null),
      'original_received', jsonb_build_object(
        'done', v_action.original_received_on is not null,
        'at', v_action.original_received_on,
        'by', null),
      'money_settled', jsonb_build_object(
        'done', v_money_done,
        'at', v_money_at,
        'by', v_money_by_name),
      'completed', jsonb_build_object(
        'done', v_action.completed_at is not null,
        'at', v_action.completed_at,
        'by', v_completed_by_name)),
    'can_cancel', v_can_start and v_action.status = 'COMMITTED',
    'cancel_block_code', v_block_code,
    'cancel_block_message', v_block_msg,
    'can_record_refund', v_can_complete
      and v_action.status = 'COMMITTED'
      and coalesce(v_action.refund_owed_cents, 0) > 0
      and v_action.refund_recorded_at is null,
    'can_void_refund', v_can_void
      and v_action.status = 'COMMITTED'
      and v_action.refund_recorded_at is not null,
    'can_complete', v_can_complete
      and v_action.status = 'COMMITTED',
    'complete_blockers', v_blockers);
end;
$$;

revoke execute on function public.get_exchange_action(uuid) from public, anon;
grant execute on function public.get_exchange_action(uuid) to authenticated;

-- ============================================================================
-- H. list_open_exchange_work — derived My Work feed, modeled on
--    list_ready_journeys (082). One row per COMMITTED exchange visible to
--    the caller: the starter, anyone homed at the journey's store, or a
--    complete_exchange holder. open_milestones uses the exact
--    complete_blockers wording; is_stalled needs the company threshold AND
--    at least one open milestone.
-- ============================================================================

create or replace function public.list_open_exchange_work()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_employee public.employees%rowtype;
  v_can_complete boolean;
begin
  select * into v_employee
  from public.employees
  where auth_user_id = auth.uid()
    and is_active;
  if v_employee.id is null then
    return '[]'::jsonb;
  end if;
  v_can_complete := public.has_permission('sleep_trial.complete_exchange');

  return coalesce((
    select jsonb_agg(r.row order by r.committed_at)
    from (
      select
        a.committed_at,
        jsonb_build_object(
          'action_id', a.id,
          'journey_id', a.journey_id,
          'child_journey_id', a.child_journey_id,
          'customer_name', c.first_name || ' ' || c.last_name,
          'replacement_product_name', p.item_name,
          'committed_at', a.committed_at,
          'days_committed',
            floor(extract(epoch from (now() - a.committed_at)) / 86400)::int,
          'open_milestones', open_ms.items,
          'is_stalled',
            (a.committed_at
               < now() - make_interval(days => co.exchange_stalled_days))
            and jsonb_array_length(open_ms.items) > 0
        ) as row
      from public.sleep_trial_actions a
      join public.sleep_journeys sj on sj.id = a.journey_id
      join public.customers c on c.id = sj.customer_id
      join public.stores s on s.id = sj.store_id
      join public.companies co on co.id = s.company_id
      left join public.products p on p.id = a.replacement_product_id
      left join public.sleep_journeys cj on cj.id = a.child_journey_id
      cross join lateral (
        select coalesce(jsonb_agg(t.m order by t.ord), '[]'::jsonb) as items
        from (
          values
            (1, 'The replacement has not been delivered yet',
                a.replacement_delivered_on is null),
            (2, 'The original mattress has not been marked received yet',
                a.original_received_on is null),
            (3, 'The replacement still has an unpaid balance',
                coalesce(cj.price, 0) > 0
                  and public.total_paid(cj.id) < cj.price),
            (4, 'The owed refund has not been recorded yet',
                coalesce(a.refund_owed_cents, 0) > 0
                  and a.refund_recorded_at is null)
        ) as t(ord, m, is_open)
        where t.is_open
      ) open_ms
      where a.status = 'COMMITTED'
        and a.action = 'EXCHANGE'
        and public.is_journey_visible(a.journey_id)
        and (a.created_by = v_employee.id
             or v_employee.home_store_id = sj.store_id
             or v_can_complete)
    ) r
  ), '[]'::jsonb);
end;
$$;

revoke execute on function public.list_open_exchange_work() from public, anon;
grant execute on function public.list_open_exchange_work() to authenticated;
