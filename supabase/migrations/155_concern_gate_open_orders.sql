-- 155_concern_gate_open_orders.sql
-- Slice 2 support: let a sleep concern be opened while the order is still
-- open, as long as at least one unit's trial has actually started (a
-- per-unit fulfillment activated its sleep_trial_item).
--
-- Replaces open_sleep_concern copied verbatim from
-- supabase/migrations/060_exception_and_idempotency_fixes.sql:377-513
-- (the latest definition; it superseded m058:403). The ONLY change is the
-- delivered_at gate: it now raises the identical message only when
-- delivered_at is null AND the journey has no live started trial item
-- (status ACTIVE, EXCHANGE_IN_PROGRESS or RETURN_IN_PROGRESS, the same set
-- used at 092:141-144). Behavior is identical on journeys with no started
-- trial item.
--
-- Rollback: recreate open_sleep_concern from
-- supabase/migrations/060_exception_and_idempotency_fixes.sql:377-513.

create or replace function public.open_sleep_concern(
  p_journey_id uuid,
  p_issues jsonb,
  p_idempotency_key text,
  p_customer_report text default null,
  p_employee_notes text default null,
  p_recommendation text default null,
  p_diagnostics jsonb default null,
  p_follow_up jsonb default null,
  p_contact_id uuid default null,
  p_channel text default null,
  p_occurred_at timestamptz default null,
  p_allow_duplicate boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee_id uuid;
  v_journey public.sleep_journeys%rowtype;
  v_existing uuid;
  v_concern_id uuid;
  v_entry_id uuid;
  v_issue jsonb;
  v_issue_names text;
  v_fu jsonb;
begin
  if not public.is_journey_visible(p_journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select id into v_employee_id
  from public.employees where auth_user_id = auth.uid();
  if v_employee_id is null then
    raise exception 'Employee record not found';
  end if;

  select * into v_journey from public.sleep_journeys where id = p_journey_id;
  if v_journey.id is null then
    raise exception 'Journey not found';
  end if;
  if v_journey.delivered_at is null
     and not exists (
       select 1 from public.sleep_trial_items sti
       where sti.journey_id = p_journey_id
         and sti.status in ('ACTIVE','EXCHANGE_IN_PROGRESS','RETURN_IN_PROGRESS')
     ) then
    raise exception 'Sleep concerns require a delivered mattress (trial start)';
  end if;

  if p_issues is null or jsonb_array_length(p_issues) = 0 then
    raise exception 'Select at least one issue';
  end if;

  -- Atomic idempotency claim on the concern row. A retry takes the
  -- conflict path and returns the existing concern id; a fresh call
  -- proceeds holding the new concern id.
  insert into public.sleep_concerns (
    journey_id, customer_id, opened_by_employee_id, idempotency_key
  ) values (
    p_journey_id, v_journey.customer_id, v_employee_id, p_idempotency_key
  )
  on conflict (idempotency_key) where idempotency_key is not null
  do nothing
  returning id into v_concern_id;

  if v_concern_id is null then
    select id into v_concern_id
    from public.sleep_concerns
    where idempotency_key = p_idempotency_key;
    return v_concern_id;
  end if;

  -- Duplicate-episode prevention (source doc §92): an open episode
  -- blocks a new one unless the caller explicitly allows it. Runs
  -- after the claim so a legit retry is not misread as a duplicate;
  -- a violation raises and rolls back the concern row just inserted.
  if not p_allow_duplicate then
    select id into v_existing
    from public.sleep_concerns
    where journey_id = p_journey_id
      and status in ('open','monitoring','escalated')
      and id <> v_concern_id
    limit 1;
    if v_existing is not null then
      raise exception 'existing_open_concern:%', v_existing;
    end if;
  end if;

  select string_agg(coalesce(i->>'name', 'Other'), ' / ')
    into v_issue_names
  from jsonb_array_elements(p_issues) i;

  for v_issue in select * from jsonb_array_elements(p_issues)
  loop
    insert into public.sleep_concern_issues (
      sleep_concern_id, concern_type_id, issue_name, added_by_employee_id
    ) values (
      v_concern_id,
      nullif(v_issue->>'concern_type_id', '')::uuid,
      coalesce(nullif(btrim(v_issue->>'name'), ''), 'Other'),
      v_employee_id
    )
    on conflict (sleep_concern_id, issue_name) do nothing;
  end loop;

  v_entry_id := public.append_sleep_concern_entry(
    v_concern_id, p_journey_id, v_journey.customer_id, v_employee_id,
    'update',
    'Sleep concern opened: ' || v_issue_names,
    p_customer_report, p_employee_notes, p_recommendation,
    p_diagnostics, p_idempotency_key, p_occurred_at,
    p_contact_id, p_channel
  );

  -- Optional follow-up in the same transaction.
  v_fu := p_follow_up;
  if v_fu is not null and v_fu->>'due_at' is not null then
    insert into public.follow_ups (
      journey_id, employee_id, type, due_at, notes, method,
      journey_interaction_id, sleep_concern_id, idempotency_key
    ) values (
      p_journey_id,
      coalesce(nullif(v_fu->>'employee_id','')::uuid, v_employee_id),
      'sleep_concern',
      (v_fu->>'due_at')::timestamptz,
      coalesce(v_fu->>'notes', 'Sleep concern follow-up: ' || v_issue_names),
      v_fu->>'method',
      (select journey_interaction_id from public.sleep_concern_entries where id = v_entry_id),
      v_concern_id,
      v_fu->>'idempotency_key'
    )
    on conflict (idempotency_key) where idempotency_key is not null
    do nothing;
  end if;

  return v_concern_id;
end;
$$;

grant execute on function public.open_sleep_concern(uuid,jsonb,text,text,text,text,jsonb,jsonb,uuid,text,timestamptz,boolean) to authenticated;
