-- PillowTop POS: security/integrity hardening for the Journey
-- Interaction + Sleep Trial + Sleep Concern migrations (056–058).
--
--   * trial_status: add the missing is_journey_visible guard so the
--     security-definer helper cannot leak another tenant's trial dates.
--   * append_sleep_concern_entry: reject a contact_id that does not
--     belong to the journey's customer (record_journey_interaction
--     already does this; the concern path silently stored it).
--   * request_sleep_trial_exception: verify the linked concern belongs
--     to the journey it is attached to.
--   * customer_contacts: stamp created_by_employee_id server-side.
--   * Explicit EXECUTE grants on the public RPCs, matching the
--     grant-execute-to-authenticated convention used by the transfer /
--     deposit approval workflows.

-- ============================================================
-- 1. trial_status — tenant guard
-- ============================================================

create or replace function public.trial_status(p_journey_id uuid)
returns table (
  started_at date,
  trial_length_nights integer,
  minimum_adjustment_nights integer,
  current_night integer,
  nights_remaining integer,
  eligible_at date,
  ends_at date,
  eligible boolean,
  expired boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_journey public.sleep_journeys%rowtype;
  v_store public.stores%rowtype;
  v_length int;
  v_minimum int;
begin
  if not public.is_journey_visible(p_journey_id) then
    return;
  end if;

  select * into v_journey from public.sleep_journeys where id = p_journey_id;
  if v_journey.id is null or v_journey.delivered_at is null then
    return;
  end if;

  select * into v_store from public.stores where id = v_journey.store_id;

  v_length := coalesce(v_journey.trial_length_nights, v_store.trial_length_nights, 120);
  v_minimum := coalesce(v_journey.minimum_adjustment_nights, v_store.minimum_adjustment_nights, 0);

  started_at := v_journey.delivered_at;
  trial_length_nights := v_length;
  minimum_adjustment_nights := v_minimum;
  current_night := greatest((current_date - v_journey.delivered_at) + 1, 1);
  nights_remaining := greatest(v_length - (current_date - v_journey.delivered_at), 0);
  eligible_at := v_journey.delivered_at + v_minimum;
  ends_at := v_journey.delivered_at + v_length;
  eligible := current_date >= eligible_at;
  expired := current_date > ends_at;
  return next;
end;
$$;

-- ============================================================
-- 2. append_sleep_concern_entry — contact must belong to the
--    journey's customer (same rule as record_journey_interaction)
-- ============================================================

create or replace function public.append_sleep_concern_entry(
  p_concern_id uuid,
  p_journey_id uuid,
  p_customer_id uuid,
  p_employee_id uuid,
  p_entry_type text,
  p_summary text,
  p_customer_report text,
  p_employee_notes text,
  p_recommendation text,
  p_diagnostics jsonb,
  p_idempotency_key text,
  p_occurred_at timestamptz,
  p_contact_id uuid,
  p_channel text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_interaction_id uuid;
  v_entry_id uuid;
  v_contact_name text;
  v_diag jsonb;
begin
  if p_contact_id is not null then
    select name into v_contact_name
    from public.customer_contacts
    where id = p_contact_id and customer_id = p_customer_id;
    if v_contact_name is null then
      raise exception 'Contact does not belong to this customer';
    end if;
  end if;

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, contact_id, contact_name_snapshot, summary,
    occurred_at, created_by_employee_id,
    source_domain, is_internal
  ) values (
    p_journey_id, p_customer_id, 'issue_concern',
    coalesce(p_channel, 'phone_inbound'),
    case when coalesce(p_channel, 'phone_inbound') in ('phone_outbound') then 'outbound'
         when coalesce(p_channel, 'phone_inbound') = 'internal' then 'internal'
         else 'inbound' end,
    'comfort', p_contact_id, v_contact_name, p_summary,
    coalesce(p_occurred_at, now()), p_employee_id,
    'sleep_concern', false
  )
  returning id into v_interaction_id;

  insert into public.sleep_concern_entries (
    sleep_concern_id, journey_interaction_id, entry_type,
    customer_report, employee_notes, recommendation_summary,
    created_by_employee_id, occurred_at, idempotency_key
  ) values (
    p_concern_id, v_interaction_id, coalesce(p_entry_type, 'update'),
    nullif(btrim(coalesce(p_customer_report, '')), ''),
    nullif(btrim(coalesce(p_employee_notes, '')), ''),
    nullif(btrim(coalesce(p_recommendation, '')), ''),
    p_employee_id, coalesce(p_occurred_at, now()), p_idempotency_key
  )
  returning id into v_entry_id;

  update public.journey_interactions
  set source_record_id = v_entry_id
  where id = v_interaction_id;

  if p_diagnostics is not null then
    for v_diag in select * from jsonb_array_elements(p_diagnostics)
    loop
      if nullif(btrim(coalesce(v_diag->>'response', '')), '') is not null then
        insert into public.sleep_concern_diagnostic_responses (
          sleep_concern_id, entry_id, question_id,
          question_snapshot, response, recorded_by
        ) values (
          p_concern_id, v_entry_id,
          nullif(v_diag->>'question_id', '')::uuid,
          coalesce(v_diag->'question_snapshot', '{}'::jsonb),
          v_diag->>'response',
          p_employee_id
        );
      end if;
    end loop;
  end if;

  update public.sleep_concerns
  set updated_at = now()
  where id = p_concern_id;

  return v_entry_id;
end;
$$;

revoke execute on function public.append_sleep_concern_entry(uuid,uuid,uuid,uuid,text,text,text,text,text,jsonb,text,timestamptz,uuid,text) from public, anon, authenticated;

-- ============================================================
-- 3. request_sleep_trial_exception — the linked concern must
--    belong to this journey
-- ============================================================

create or replace function public.request_sleep_trial_exception(
  p_journey_id uuid,
  p_sleep_concern_id uuid,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee_id uuid;
  v_status record;
  v_request_id uuid;
begin
  if not public.is_journey_visible(p_journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select id into v_employee_id
  from public.employees where auth_user_id = auth.uid();
  if v_employee_id is null then
    raise exception 'Employee record not found';
  end if;

  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required';
  end if;

  if p_sleep_concern_id is not null
     and not exists (
       select 1 from public.sleep_concerns
       where id = p_sleep_concern_id and journey_id = p_journey_id
     ) then
    raise exception 'Concern does not belong to this journey';
  end if;

  select * into v_status from public.trial_status(p_journey_id);
  if v_status.started_at is null then
    raise exception 'Journey has no active sleep trial';
  end if;
  if v_status.eligible then
    raise exception 'Journey is already exchange-eligible — no exception needed';
  end if;
  if v_status.expired then
    raise exception 'The sleep trial has already ended';
  end if;

  if exists (
    select 1 from public.sleep_trial_exception_requests
    where journey_id = p_journey_id and status = 'pending'
  ) then
    raise exception 'An early exchange exception request is already pending for this journey';
  end if;

  insert into public.sleep_trial_exception_requests (
    journey_id, sleep_concern_id, requester_employee_id, reason,
    current_trial_night, normal_eligibility_date, expires_at
  ) values (
    p_journey_id, p_sleep_concern_id, v_employee_id, btrim(p_reason),
    v_status.current_night, v_status.eligible_at,
    (v_status.eligible_at + 1)::timestamptz
  )
  returning id into v_request_id;

  -- Surface the request in Journey Activity.
  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain, source_record_id, is_internal
  )
  select p_journey_id, sj.customer_id, 'customer_request', 'internal', 'internal',
    'return_exchange',
    'Early exchange exception requested (night ' || v_status.current_night
      || ' of ' || v_status.minimum_adjustment_nights || ' minimum). Reason: ' || btrim(p_reason),
    v_employee_id, 'sleep_trial_exception', v_request_id, true
  from public.sleep_journeys sj where sj.id = p_journey_id;

  return v_request_id;
end;
$$;

-- ============================================================
-- 4. customer_contacts — stamp the creating employee server-side
-- ============================================================

create or replace function public.stamp_contact_created_by()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.created_by_employee_id is null then
    select id into new.created_by_employee_id
    from public.employees
    where auth_user_id = auth.uid();
  end if;
  return new;
end;
$$;

drop trigger if exists customer_contacts_created_by on public.customer_contacts;
create trigger customer_contacts_created_by
  before insert on public.customer_contacts
  for each row execute function public.stamp_contact_created_by();

revoke execute on function public.stamp_contact_created_by() from public, anon, authenticated;

-- ============================================================
-- 5. Explicit EXECUTE grants on the public RPCs (matches the
--    convention used by transfer / deposit approval functions)
-- ============================================================

grant execute on function public.record_journey_interaction(uuid,text,text,text,text,text,text,uuid,text,text,text,timestamptz,boolean,text,date,uuid,text,text,uuid,jsonb) to authenticated;
grant execute on function public.mark_interaction_entered_in_error(uuid,text) to authenticated;
grant execute on function public.set_interaction_importance(uuid,boolean,date) to authenticated;
grant execute on function public.correct_trial_start(uuid,date,text) to authenticated;
grant execute on function public.trial_status(uuid) to authenticated;
grant execute on function public.ensure_sleep_concern_defaults() to authenticated;
grant execute on function public.open_sleep_concern(uuid,jsonb,text,text,text,text,jsonb,jsonb,uuid,text,timestamptz,boolean) to authenticated;
grant execute on function public.add_sleep_concern_entry(uuid,text,text,text,text,jsonb,jsonb,text,text,text,jsonb,uuid,text,timestamptz) to authenticated;
grant execute on function public.request_concern_exchange(uuid) to authenticated;
grant execute on function public.request_sleep_trial_exception(uuid,uuid,text) to authenticated;
grant execute on function public.decide_sleep_trial_exception(uuid,text) to authenticated;
