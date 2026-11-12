-- PillowTop POS m138: D1-c2b part 1b -- delivery confirmation calls and
-- the night-before call list, on the SAME contact log.
--
--   * delivery.set_windows: new permission (owner/admin by default,
--     per-person grants for warehouse staff). set_delivery_stop_windows
--     now accepts EITHER delivery.set_windows OR delivery.manage_calendar,
--     parses input without temp tables, returns a plain message on
--     malformed input, and writes no audit row when nothing changed.
--   * CONFIRMATION outcomes are now a closed namespace:
--     confirmed, left_voicemail, no_answer, wrong_number,
--     needs_different_day, and a CONFIRMATION row must carry stop_id.
--     The check is NOT VALID so odd existing rows cannot block install.
--   * log_delivery_contact rejects purpose CONFIRMATION; SCHEDULING is
--     unchanged.
--   * log_delivery_confirmation: the ONE write path for confirmation
--     calls. Server captures window_snapshot from the stop; idempotent
--     like log_delivery_contact.
--   * delivery_contact_key_state ignores CONFIRMATION rows entirely:
--     they never feed held, hold_until, callback_due, bad_number,
--     last_contact or recent_contact_minutes.
--   * get_delivery_confirmation_list: the night-before call list,
--     scoped mine/all, company isolated.
--
-- CONFIRMATION rows may have created_by_employee_id null in future
-- (automated texts); every reader LEFT joins employees already.

-- ============================================================================
-- 1. Permission delivery.set_windows
-- ============================================================================

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
    'inventory.receive_po',
    'delivery.manage_trucks',
    'delivery.manage_calendar',
    'delivery.book_inside_cutoff',
    'delivery.log_confirmation_calls',
    'delivery.set_windows'
  );
$$;

revoke execute on function public.is_valid_permission_key(text) from anon;

-- Existing companies: owner + admin only. Manager and sales get it
-- per-person through employee_permission_overrides when Zach grants it.
insert into public.role_permission_grants (company_id, role, permission_key)
select c.id, g.role, 'delivery.set_windows'
from public.companies c
cross join (values ('owner'), ('admin')) as g (role)
on conflict do nothing;

-- New companies: every grant from m137 plus owner/admin for the new key.
create or replace function public.trg_seed_delivery_permissions()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.role_permission_grants (company_id, role, permission_key)
  values
    (new.id, 'owner', 'delivery.manage_trucks'),
    (new.id, 'admin', 'delivery.manage_trucks'),
    (new.id, 'owner', 'delivery.manage_calendar'),
    (new.id, 'admin', 'delivery.manage_calendar'),
    (new.id, 'owner', 'delivery.book_inside_cutoff'),
    (new.id, 'admin', 'delivery.book_inside_cutoff'),
    (new.id, 'owner', 'delivery.log_confirmation_calls'),
    (new.id, 'admin', 'delivery.log_confirmation_calls'),
    (new.id, 'manager', 'delivery.log_confirmation_calls'),
    (new.id, 'sales', 'delivery.log_confirmation_calls'),
    (new.id, 'owner', 'delivery.set_windows'),
    (new.id, 'admin', 'delivery.set_windows')
  on conflict do nothing;
  return new;
end;
$$;

revoke execute on function public.trg_seed_delivery_permissions()
  from authenticated, anon, public;

-- ============================================================================
-- 2. CONFIRMATION outcome namespace on journey_interactions.
--    NOT VALID: enforced for every new row, but existing odd rows can
--    never block the install.
-- ============================================================================

alter table public.journey_interactions
  drop constraint if exists journey_interactions_contact_outcome_check;

alter table public.journey_interactions
  add constraint journey_interactions_contact_outcome_check
  check (
    (purpose = 'CONFIRMATION'
      and contact_outcome in (
        'confirmed', 'left_voicemail', 'no_answer',
        'wrong_number', 'needs_different_day')
      and stop_id is not null)
    or (purpose <> 'CONFIRMATION'
      and (contact_outcome is null
           or (purpose = 'SCHEDULING' and contact_outcome in (
             'spoke', 'voicemail', 'no_answer', 'texted',
             'will_call_back', 'not_ready', 'wrong_number'))))
  ) not valid;

comment on column public.journey_interactions.contact_outcome is
  'Structured delivery-contact outcome. SCHEDULING values: spoke, voicemail, no_answer, texted, will_call_back, not_ready, wrong_number. CONFIRMATION values: confirmed, left_voicemail, no_answer, wrong_number, needs_different_day (stop_id required).';

-- ============================================================================
-- 3. log_delivery_contact - CONFIRMATION is rejected; SCHEDULING path is
--    byte-identical to m135 otherwise.
-- ============================================================================

create or replace function public.log_delivery_contact(
  p_journey_id uuid,
  p_purpose text,
  p_outcome text,
  p_note text default null,
  p_callback_after date default null,
  p_occurred_at timestamptz default null,
  p_idempotency_key text default null,
  p_stop_id uuid default null,
  p_window_snapshot jsonb default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee_id uuid;
  v_customer_id uuid;
  v_company_id uuid;
  v_today date;
  v_occurred timestamptz;
  v_interaction_type text;
  v_channel text;
  v_legacy_outcome text;
  v_waiting_on text;
  v_summary text;
  v_commitment text;
  v_interaction_id uuid;
  v_existing_id uuid;
  v_existing_journey uuid;
  v_existing_employee uuid;
begin
  if not public.is_journey_visible(p_journey_id) then
    raise exception 'Not authorized to log a delivery contact for this order';
  end if;

  if p_purpose = 'CONFIRMATION' then
    raise exception 'Confirmation calls are logged from the delivery call list.';
  end if;
  if p_purpose is null or p_purpose <> 'SCHEDULING' then
    raise exception 'Purpose must be SCHEDULING';
  end if;

  select id into v_employee_id
  from public.employees
  where auth_user_id = auth.uid() and is_active;
  if v_employee_id is null then
    raise exception 'Employee record not found';
  end if;

  select sj.customer_id, st.company_id
    into v_customer_id, v_company_id
  from public.sleep_journeys sj
  join public.stores st on st.id = sj.store_id
  where sj.id = p_journey_id;
  if v_customer_id is null then
    raise exception 'Order not found';
  end if;

  -- occurred_at: not in the future (5 min clock skew) and not older
  -- than 7 days.
  v_occurred := coalesce(p_occurred_at, now());
  if v_occurred > now() + interval '5 minutes' then
    raise exception 'The contact time cannot be in the future';
  end if;
  if v_occurred < now() - interval '7 days' then
    raise exception 'The contact time cannot be more than 7 days ago';
  end if;

  v_today := public.delivery_company_today();

  if p_outcome is null or p_outcome not in (
    'spoke', 'voicemail', 'no_answer', 'texted',
    'will_call_back', 'not_ready', 'wrong_number') then
    raise exception 'Choose a valid call outcome';
  end if;

  if p_outcome = 'not_ready' and p_callback_after is null then
    raise exception 'A callback date is required when the customer is not ready yet';
  end if;
  -- callback_after is allowed on every hold outcome (voicemail,
  -- no_answer, texted, will_call_back, not_ready, spoke) and rejected
  -- only for wrong_number.
  if p_outcome = 'wrong_number'
     and p_callback_after is not null then
    raise exception 'A callback date does not apply to a wrong number';
  end if;
  if p_callback_after is not null then
    if p_callback_after < v_today then
      raise exception 'The callback date must be today or later';
    end if;
    if p_callback_after > v_today + 90 then
      raise exception 'The callback date must be within 90 days';
    end if;
  end if;

  -- Legacy mapping (see m134 header comment).
  v_interaction_type := case p_outcome
    when 'texted' then 'text_conversation'
    else 'called_customer' end;
  v_channel := case p_outcome
    when 'texted' then 'sms'
    else 'phone_outbound' end;
  v_legacy_outcome := case p_outcome
    when 'spoke' then 'resolved'
    when 'will_call_back' then 'follow_up_needed'
    when 'not_ready' then 'waiting_on_customer'
    else 'no_response' end;
  v_waiting_on := case p_outcome
    when 'spoke' then 'nothing'
    else 'customer' end;
  v_summary := 'Delivery scheduling ' ||
    case p_outcome
      when 'spoke' then 'call: spoke with customer.'
      when 'voicemail' then 'call: left voicemail.'
      when 'no_answer' then 'call: no answer.'
      when 'texted' then 'text sent.'
      when 'will_call_back' then 'call: customer will call back.'
      when 'not_ready' then 'call: not ready yet.'
      else 'call: wrong number.' end;

  if p_note is not null and btrim(p_note) <> '' then
    v_summary := v_summary || ' ' || btrim(p_note);
  end if;

  v_commitment := case
    when p_callback_after is not null
      then 'Call back on ' || to_char(p_callback_after, 'YYYY-MM-DD')
    else null end;

  if p_stop_id is not null and not exists (
    select 1 from public.delivery_stops ds
    where ds.id = p_stop_id and ds.journey_id = p_journey_id
  ) then
    raise exception 'That delivery stop does not belong to this order';
  end if;

  -- Idempotent retry: return the previously created row, but only when
  -- it belongs to THIS order and THIS employee. A key seen on another
  -- order (or by another user, including another company) is an error,
  -- never a silent cross-order return of someone else's row id.
  if p_idempotency_key is not null then
    select id, journey_id, created_by_employee_id
      into v_existing_id, v_existing_journey, v_existing_employee
    from public.journey_interactions
    where idempotency_key = p_idempotency_key;
    if v_existing_id is not null then
      if v_existing_journey = p_journey_id
         and v_existing_employee = v_employee_id then
        return v_existing_id;
      end if;
      raise exception 'That request key was already used for a different order.';
    end if;
  end if;

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, topic_label, summary, outcome, waiting_on, commitment_made,
    occurred_at, created_by_employee_id, source_domain, is_internal,
    purpose, contact_outcome, callback_after, stop_id, window_snapshot,
    company_id, idempotency_key
  ) values (
    p_journey_id, v_customer_id, v_interaction_type, v_channel, 'outbound',
    'scheduling', 'Delivery scheduling', v_summary, v_legacy_outcome,
    v_waiting_on, v_commitment,
    v_occurred, v_employee_id, 'manual', false,
    'SCHEDULING', p_outcome, p_callback_after, p_stop_id, p_window_snapshot,
    v_company_id, p_idempotency_key
  )
  on conflict (idempotency_key) where idempotency_key is not null
  do nothing
  returning id into v_interaction_id;

  if v_interaction_id is null then
    select id, journey_id, created_by_employee_id
      into v_existing_id, v_existing_journey, v_existing_employee
    from public.journey_interactions
    where idempotency_key = p_idempotency_key;
    if v_existing_id is not null then
      if v_existing_journey = p_journey_id
         and v_existing_employee = v_employee_id then
        return v_existing_id;
      end if;
      raise exception 'That request key was already used for a different order.';
    end if;
    raise exception 'Could not log the delivery contact. Please try again.';
  end if;

  return v_interaction_id;
end;
$$;

revoke execute on function public.log_delivery_contact(uuid, text, text, text, date, timestamptz, text, uuid, jsonb)
  from public, anon;
grant execute on function public.log_delivery_contact(uuid, text, text, text, date, timestamptz, text, uuid, jsonb)
  to authenticated;

-- ============================================================================
-- 4. delivery_contact_key_state - identical to m135 except CONFIRMATION
--    rows are excluded from the latest-contact read AND from the
--    "newer contact clears the hold" check. They can never move a
--    scheduling hold, callback_due or bad_number.
-- ============================================================================

create or replace function public.delivery_contact_key_state(
  p_company_id uuid,
  p_customer_id uuid,
  p_norm_phone text,
  p_journey_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_tz text;
  v_today date;
  v_hold_days integer;
  v_latest record;
  v_cand record;
  v_newer boolean;
  v_stop boolean;
  v_hold_until timestamptz;
  v_held boolean := false;
  v_callback_due boolean := false;
  v_bad_number boolean := false;
  v_recent_minutes integer;
begin
  if p_company_id is null or p_customer_id is null then
    return jsonb_build_object(
      'last_contact', null, 'held', false, 'hold_until', null,
      'callback_due', false, 'bad_number', false,
      'recent_contact_minutes', null);
  end if;

  select c.business_timezone, c.delivery_contact_hold_days
    into v_tz, v_hold_days
  from public.companies c where c.id = p_company_id;
  v_tz := coalesce(v_tz, 'America/Denver');
  v_hold_days := coalesce(v_hold_days, 2);
  v_today := (now() at time zone v_tz)::date;

  -- Latest SCHEDULING contact across the whole customer key.
  -- CONFIRMATION rows are invisible to this function entirely.
  select
    ji.id, ji.journey_id, ji.occurred_at, ji.recorded_at,
    ji.purpose, ji.contact_outcome, ji.callback_after,
    ji.created_by_employee_id, ji.summary,
    sjn.journey_number,
    jc.first_name || ' ' || jc.last_name as customer_name,
    e.name as employee_name
  into v_latest
  from public.journey_interactions ji
  join public.sleep_journeys sjn on sjn.id = ji.journey_id
  join public.customers jc on jc.id = ji.customer_id
  left join public.employees e on e.id = ji.created_by_employee_id
  where ji.company_id = p_company_id
    and ji.entered_in_error_at is null
    and ji.purpose = 'SCHEDULING'
    and (ji.customer_id = p_customer_id
         or (p_norm_phone is not null
             and public.delivery_norm_phone(jc.phone) = p_norm_phone))
  order by ji.occurred_at desc, ji.recorded_at desc
  limit 1;

  if v_latest.id is null then
    return jsonb_build_object(
      'last_contact', null, 'held', false, 'hold_until', null,
      'callback_due', false, 'bad_number', false,
      'recent_contact_minutes', null);
  end if;

  v_recent_minutes := greatest(
    0, floor(extract(epoch from (now() - v_latest.occurred_at)) / 60)
  )::integer;
  v_callback_due := v_latest.callback_after is not null
    and v_latest.callback_after <= v_today;
  v_bad_number := v_latest.purpose = 'SCHEDULING'
    and v_latest.contact_outcome = 'wrong_number';

  -- Latest SCHEDULING contact is the hold candidate.
  select
    ji.id, ji.journey_id, ji.occurred_at, ji.recorded_at,
    ji.contact_outcome, ji.callback_after
  into v_cand
  from public.journey_interactions ji
  join public.customers jc on jc.id = ji.customer_id
  where ji.company_id = p_company_id
    and ji.entered_in_error_at is null
    and ji.purpose = 'SCHEDULING'
    and (ji.customer_id = p_customer_id
         or (p_norm_phone is not null
             and public.delivery_norm_phone(jc.phone) = p_norm_phone))
  order by ji.occurred_at desc, ji.recorded_at desc
  limit 1;

  if v_cand.id is not null then
    -- Any newer SCHEDULING contact anywhere in the key clears the
    -- hold. CONFIRMATION rows never count here.
    select exists (
      select 1
      from public.journey_interactions ji2
      join public.customers jc2 on jc2.id = ji2.customer_id
      where ji2.company_id = p_company_id
        and ji2.entered_in_error_at is null
        and ji2.purpose = 'SCHEDULING'
        and (ji2.customer_id = p_customer_id
             or (p_norm_phone is not null
                 and public.delivery_norm_phone(jc2.phone) = p_norm_phone))
        and (ji2.occurred_at > v_cand.occurred_at
             or (ji2.occurred_at = v_cand.occurred_at
                 and ji2.recorded_at > v_cand.recorded_at))
    ) into v_newer;

    -- A stop created for ANY journey in the key after the contact
    -- (booking counts - on this order or a sibling) clears the hold.
    select exists (
      select 1
      from public.delivery_stops ds
      join public.sleep_journeys sjk on sjk.id = ds.journey_id
      join public.stores stk on stk.id = sjk.store_id
      join public.customers ck on ck.id = sjk.customer_id
      where ds.company_id = p_company_id
        and stk.company_id = p_company_id
        and ds.created_at > v_cand.occurred_at
        and (sjk.customer_id = p_customer_id
             or (p_norm_phone is not null
                 and public.delivery_norm_phone(ck.phone) = p_norm_phone))
    ) into v_stop;

    v_hold_until := case
      when v_cand.callback_after is not null
        then (v_cand.callback_after::timestamp at time zone v_tz)
      else v_cand.occurred_at + make_interval(days => v_hold_days)
    end;

    v_held := v_cand.contact_outcome in (
        'voicemail', 'no_answer', 'texted', 'will_call_back',
        'not_ready', 'spoke')
      and v_hold_days > 0
      and not v_newer
      and not v_stop
      and now() < v_hold_until;
  end if;

  return jsonb_build_object(
    'last_contact', jsonb_build_object(
      'purpose', v_latest.purpose,
      'contact_outcome', v_latest.contact_outcome,
      'occurred_at', v_latest.occurred_at,
      'employee_name', v_latest.employee_name,
      'journey_id', v_latest.journey_id,
      'journey_number', v_latest.journey_number,
      'customer_name', v_latest.customer_name,
      'on_this_order', v_latest.journey_id = p_journey_id),
    'held', v_held,
    'hold_until', v_hold_until,
    'callback_due', v_callback_due,
    'bad_number', v_bad_number,
    'recent_contact_minutes', v_recent_minutes);
end;
$$;

revoke execute on function public.delivery_contact_key_state(uuid, uuid, text, uuid)
  from public, anon, authenticated;

-- ============================================================================
-- 5. log_delivery_confirmation - the ONE write path for night-before
--    confirmation calls. Any holder of delivery.log_confirmation_calls
--    may log for ANY booked stop in their company (coworker coverage).
--    window_snapshot is captured server-side from the stop; in
--    day_only mode the window fields are null.
-- ============================================================================

create or replace function public.log_delivery_confirmation(
  p_journey_id uuid,
  p_stop_id uuid,
  p_outcome text,
  p_note text default null,
  p_occurred_at timestamptz default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee_id uuid;
  v_customer_id uuid;
  v_company_id uuid;
  v_stop record;
  v_day_mode text;
  v_occurred timestamptz;
  v_summary text;
  v_legacy_outcome text;
  v_waiting_on text;
  v_snapshot jsonb;
  v_interaction_id uuid;
  v_existing_id uuid;
  v_existing_journey uuid;
  v_existing_employee uuid;
begin
  if not public.has_permission('delivery.log_confirmation_calls') then
    raise exception 'You do not have permission to log confirmation calls.';
  end if;

  select e.id, s.company_id
    into v_employee_id, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid() and e.is_active;
  if v_employee_id is null then
    raise exception 'Employee record not found';
  end if;

  select sj.customer_id into v_customer_id
  from public.sleep_journeys sj
  join public.stores st on st.id = sj.store_id
  where sj.id = p_journey_id
    and st.company_id = v_company_id;
  if v_customer_id is null then
    raise exception 'Order not found';
  end if;

  select ds.id, ds.journey_id, ds.delivery_date, ds.truck_id,
         ds.window_start, ds.window_end
    into v_stop
  from public.delivery_stops ds
  where ds.id = p_stop_id
    and ds.journey_id = p_journey_id
    and ds.company_id = v_company_id
    and ds.status = 'BOOKED';
  if v_stop.id is null then
    raise exception 'That delivery stop does not belong to this order';
  end if;
  if v_stop.delivery_date < public.delivery_company_today() then
    raise exception 'That delivery day has already passed';
  end if;

  if p_outcome is null or p_outcome not in (
    'confirmed', 'left_voicemail', 'no_answer',
    'wrong_number', 'needs_different_day') then
    raise exception 'Choose a valid confirmation outcome';
  end if;

  v_occurred := coalesce(p_occurred_at, now());
  if v_occurred > now() + interval '5 minutes' then
    raise exception 'The contact time cannot be in the future';
  end if;
  if v_occurred < now() - interval '7 days' then
    raise exception 'The contact time cannot be more than 7 days ago';
  end if;

  select c.delivery_day_mode into v_day_mode
  from public.companies c where c.id = v_company_id;

  v_snapshot := jsonb_build_object(
    'delivery_date', v_stop.delivery_date,
    'window_start', case when v_day_mode = 'day_only' then null
                         else v_stop.window_start end,
    'window_end', case when v_day_mode = 'day_only' then null
                       else v_stop.window_end end,
    'truck_id', v_stop.truck_id);

  -- Provisional legacy mapping, same style as the SCHEDULING rows.
  v_legacy_outcome := case p_outcome
    when 'confirmed' then 'resolved'
    when 'needs_different_day' then 'follow_up_needed'
    else 'no_response' end;
  v_waiting_on := case p_outcome
    when 'confirmed' then 'nothing'
    else 'customer' end;
  v_summary := 'Delivery confirmation call: ' ||
    case p_outcome
      when 'confirmed' then 'customer confirmed.'
      when 'left_voicemail' then 'left voicemail.'
      when 'no_answer' then 'no answer.'
      when 'wrong_number' then 'wrong number.'
      else 'customer needs a different day.' end;

  if p_note is not null and btrim(p_note) <> '' then
    v_summary := v_summary || ' ' || btrim(p_note);
  end if;

  -- Idempotent retry: same journey and same employee only, exactly
  -- like log_delivery_contact.
  if p_idempotency_key is not null then
    select id, journey_id, created_by_employee_id
      into v_existing_id, v_existing_journey, v_existing_employee
    from public.journey_interactions
    where idempotency_key = p_idempotency_key;
    if v_existing_id is not null then
      if v_existing_journey = p_journey_id
         and v_existing_employee = v_employee_id then
        return jsonb_build_object(
          'interaction_id', v_existing_id, 'deduplicated', true);
      end if;
      raise exception 'That request key was already used for a different order.';
    end if;
  end if;

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, topic_label, summary, outcome, waiting_on, commitment_made,
    occurred_at, created_by_employee_id, source_domain, is_internal,
    purpose, contact_outcome, callback_after, stop_id, window_snapshot,
    company_id, idempotency_key
  ) values (
    p_journey_id, v_customer_id, 'called_customer', 'phone_outbound',
    'outbound', 'delivery', 'Delivery confirmation', v_summary,
    v_legacy_outcome, v_waiting_on, null,
    v_occurred, v_employee_id, 'manual', false,
    'CONFIRMATION', p_outcome, null, p_stop_id, v_snapshot,
    v_company_id, p_idempotency_key
  )
  on conflict (idempotency_key) where idempotency_key is not null
  do nothing
  returning id into v_interaction_id;

  if v_interaction_id is null then
    select id, journey_id, created_by_employee_id
      into v_existing_id, v_existing_journey, v_existing_employee
    from public.journey_interactions
    where idempotency_key = p_idempotency_key;
    if v_existing_id is not null then
      if v_existing_journey = p_journey_id
         and v_existing_employee = v_employee_id then
        return jsonb_build_object(
          'interaction_id', v_existing_id, 'deduplicated', true);
      end if;
      raise exception 'That request key was already used for a different order.';
    end if;
    raise exception 'Could not log the delivery confirmation. Please try again.';
  end if;

  return jsonb_build_object(
    'interaction_id', v_interaction_id, 'deduplicated', false);
end;
$$;

revoke execute on function public.log_delivery_confirmation(uuid, uuid, text, text, timestamptz, text)
  from public, anon;
grant execute on function public.log_delivery_confirmation(uuid, uuid, text, text, timestamptz, text)
  to authenticated;

-- ============================================================================
-- 6. get_delivery_confirmation_list - the night-before call list.
--    Set-based; CONFIRMATION rows with a null employee are kept.
-- ============================================================================

create or replace function public.get_delivery_confirmation_list(
  p_date date default null,
  p_scope text default 'mine'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_employee_id uuid;
  v_company_id uuid;
  v_tomorrow date;
  v_date date;
  v_mode text;
  v_day_start time;
  v_day_end time;
  v_dates jsonb;
  v_items jsonb;
begin
  select e.id, s.company_id
    into v_employee_id, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid() and e.is_active;
  if v_company_id is null then
    raise exception 'Only active employees can view the confirmation list.';
  end if;
  if not public.has_permission('delivery.log_confirmation_calls') then
    raise exception 'You do not have permission to view the confirmation list.';
  end if;
  if p_scope is null or p_scope not in ('mine', 'all') then
    raise exception 'Scope must be mine or all.';
  end if;

  select c.delivery_day_mode, c.delivery_day_start, c.delivery_day_end
    into v_mode, v_day_start, v_day_end
  from public.companies c where c.id = v_company_id;

  v_tomorrow := public.delivery_company_today() + 1;

  if p_date is null then
    select min(ds.delivery_date) into v_date
    from public.delivery_stops ds
    where ds.company_id = v_company_id
      and ds.status = 'BOOKED'
      and ds.delivery_date >= v_tomorrow;
  else
    v_date := p_date;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'date', d.delivery_date, 'stop_count', d.n
    ) order by d.delivery_date), '[]'::jsonb)
  into v_dates
  from (
    select ds.delivery_date, count(*) as n
    from public.delivery_stops ds
    where ds.company_id = v_company_id
      and ds.status = 'BOOKED'
      and ds.delivery_date >= v_tomorrow
    group by ds.delivery_date
    order by ds.delivery_date
    limit 7
  ) d;

  if v_date is null then
    return jsonb_build_object(
      'date', null, 'day_mode', v_mode,
      'day_start', v_day_start, 'day_end', v_day_end,
      'available_dates', v_dates, 'scope', p_scope, 'items', '[]'::jsonb);
  end if;

  with stops as (
    select
      ds.id as stop_id,
      ds.journey_id,
      ds.delivery_date,
      ds.truck_id,
      ds.route_position,
      ds.booked_by,
      ds.window_start,
      ds.window_end,
      sj.journey_number,
      sj.assigned_employee_id,
      sj.customer_id,
      cu.first_name || ' ' || cu.last_name as customer_name,
      cu.phone as customer_phone,
      cu.email as customer_email,
      nullif(trim(concat_ws(', ',
        nullif(trim(concat_ws(' ', cu.street_address, cu.street_address_line_2)), ''),
        nullif(trim(concat_ws(' ', cu.city, cu.state, cu.zip_code)), '')
      )), '') as delivery_address,
      t.name as truck_name,
      ae.name as assigned_employee_name
    from public.delivery_stops ds
    join public.sleep_journeys sj on sj.id = ds.journey_id
    join public.stores st on st.id = sj.store_id
    join public.customers cu on cu.id = sj.customer_id
    left join public.delivery_trucks t on t.id = ds.truck_id
    left join public.employees ae on ae.id = sj.assigned_employee_id
    where ds.company_id = v_company_id
      and ds.delivery_date = v_date
      and ds.status = 'BOOKED'
      and st.company_id = v_company_id
      and (p_scope = 'all'
           or sj.assigned_employee_id = v_employee_id
           or (sj.assigned_employee_id is null
               and ds.booked_by = v_employee_id))
  ),
  conf as (
    select
      ji.stop_id,
      count(*) as attempts,
      (array_agg(ji.contact_outcome
        order by ji.occurred_at desc, ji.recorded_at desc))[1] as last_outcome,
      (array_agg(ji.occurred_at
        order by ji.occurred_at desc, ji.recorded_at desc))[1] as last_at,
      (array_agg(ji.summary
        order by ji.occurred_at desc, ji.recorded_at desc))[1] as last_note,
      (array_agg(ji.window_snapshot
        order by ji.occurred_at desc, ji.recorded_at desc))[1] as last_snapshot,
      (array_agg(ji.created_by_employee_id
        order by ji.occurred_at desc, ji.recorded_at desc))[1] as last_employee_id
    from public.journey_interactions ji
    where ji.company_id = v_company_id
      and ji.purpose = 'CONFIRMATION'
      and ji.stop_id is not null
      and ji.entered_in_error_at is null
      and ji.stop_id in (select s.stop_id from stops s)
    group by ji.stop_id
  )
  select coalesce(jsonb_agg(x.jb order by
      x.truck_id nulls last, x.route_position nulls last, x.customer_name),
    '[]'::jsonb)
  into v_items
  from (
    select
      jsonb_build_object(
        'stop_id', s.stop_id,
        'journey_id', s.journey_id,
        'journey_number', s.journey_number,
        'customer_name', s.customer_name,
        'customer_phone', s.customer_phone,
        'customer_email', s.customer_email,
        'delivery_address', s.delivery_address,
        'truck_id', s.truck_id,
        'truck_name', s.truck_name,
        'route_position', s.route_position,
        'window_start', case when v_mode = 'day_only' then null else s.window_start end,
        'window_end', case when v_mode = 'day_only' then null else s.window_end end,
        'outside_day_hours',
          case
            when v_mode = 'day_only' or s.window_start is null then false
            else s.window_start < v_day_start or s.window_end > v_day_end
          end,
        'assigned_employee_id', s.assigned_employee_id,
        'assigned_employee_name', s.assigned_employee_name,
        'status',
          case
            when c.stop_id is null then 'not_called'
            when c.last_outcome = 'confirmed'
                 and (c.last_snapshot ->> 'delivery_date') = s.delivery_date::text
                 and (v_mode = 'day_only'
                      or (((c.last_snapshot ->> 'window_start')
                            is not distinct from
                           (case when s.window_start is null then null
                                 else to_char(s.window_start, 'HH24:MI:SS') end))
                          and ((c.last_snapshot ->> 'window_end')
                            is not distinct from
                           (case when s.window_end is null then null
                                 else to_char(s.window_end, 'HH24:MI:SS') end))))
              then 'confirmed'
            when c.last_outcome = 'confirmed' then 'confirmed_window_changed'
            else c.last_outcome
          end,
        'attempts', coalesce(c.attempts, 0),
        'last_call', case when c.stop_id is null then null else jsonb_build_object(
          'outcome', c.last_outcome,
          'occurred_at', c.last_at,
          'by_name', be.name,
          'note', c.last_note,
          'window_snapshot', c.last_snapshot
        ) end
      ) as jb,
      s.truck_id,
      s.route_position,
      s.customer_name
    from stops s
    left join conf c on c.stop_id = s.stop_id
    left join public.employees be on be.id = c.last_employee_id
  ) x;

  return jsonb_build_object(
    'date', v_date,
    'day_mode', v_mode,
    'day_start', v_day_start,
    'day_end', v_day_end,
    'available_dates', v_dates,
    'scope', p_scope,
    'items', v_items);
end;
$$;

revoke execute on function public.get_delivery_confirmation_list(date, text)
  from public, anon;
grant execute on function public.get_delivery_confirmation_list(date, text)
  to authenticated;

-- ============================================================================
-- 7. set_delivery_stop_windows - m137 rules unchanged, three deltas:
--    permission is delivery.set_windows OR delivery.manage_calendar;
--    malformed casts return a plain message; a no-op returns 0 with no
--    audit row. No temp tables (parsed once into a jsonb variable).
-- ============================================================================

create or replace function public.set_delivery_stop_windows(
  p_date date,
  p_items jsonb
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_employee_id uuid;
  v_items jsonb;
  v_changed integer;
begin
  v_company_id := public.delivery_caller_company();
  if v_company_id is null then
    raise exception 'Only active employees can manage deliveries.';
  end if;
  if not (public.has_permission('delivery.manage_calendar')
          or public.has_permission('delivery.set_windows')) then
    raise exception 'You do not have permission to set delivery windows.';
  end if;
  perform public.delivery_assert_day_writable(p_date);

  v_employee_id := public.delivery_caller_employee_id();

  if p_items is null
     or jsonb_typeof(p_items) <> 'array'
     or jsonb_array_length(p_items) = 0 then
    raise exception 'Send at least one stop window.';
  end if;

  -- Parse and dedupe (last duplicate stop_id wins) inside a guarded
  -- block so a bad uuid or time returns a plain message instead of a
  -- raw cast error.
  begin
    select coalesce(jsonb_agg(jsonb_build_object(
        'stop_id', d.stop_id,
        'window_start', d.window_start,
        'window_end', d.window_end
      ) order by d.stop_id), '[]'::jsonb)
    into v_items
    from (
      select distinct on (x.stop_id)
             x.stop_id, x.window_start, x.window_end
      from (
        select t.ord,
               (t.item ->> 'stop_id')::uuid as stop_id,
               nullif(t.item ->> 'window_start', '')::time as window_start,
               nullif(t.item ->> 'window_end', '')::time as window_end
        from jsonb_array_elements(p_items) with ordinality as t(item, ord)
      ) x
      order by x.stop_id, x.ord desc
    ) d;
  exception when others then
    raise exception 'One of the windows has a bad stop id or time.';
  end;

  if exists (
    select 1
    from jsonb_to_recordset(v_items) as x(stop_id uuid, window_start time, window_end time)
    where (window_start is null) <> (window_end is null)
       or (window_start is not null and window_end <= window_start)
  ) then
    raise exception 'Each window needs both a start and an end time, with the end after the start.';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(v_items) as x(stop_id uuid, window_start time, window_end time)
    left join public.delivery_stops ds on ds.id = x.stop_id
    where ds.id is null
       or ds.company_id <> v_company_id
       or ds.delivery_date <> p_date
       or ds.status <> 'BOOKED'
  ) then
    raise exception 'Every window must name a booked stop for this company on that date.';
  end if;

  -- Nothing actually changed: return 0 and write no audit row.
  select count(*) into v_changed
  from jsonb_to_recordset(v_items) as x(stop_id uuid, window_start time, window_end time)
  join public.delivery_stops ds on ds.id = x.stop_id
  where ds.window_start is distinct from x.window_start
     or ds.window_end is distinct from x.window_end;
  if v_changed = 0 then
    return 0;
  end if;

  -- Apply and audit in one statement. The event's details read the
  -- pre-update snapshot (data-modifying CTE effects are invisible to
  -- sibling CTEs), giving a true before/after map.
  with items as (
    select *
    from jsonb_to_recordset(v_items) as x(stop_id uuid, window_start time, window_end time)
  ),
  upd as (
    update public.delivery_stops ds
    set window_start = i.window_start,
        window_end = i.window_end,
        updated_at = now()
    from items i
    where ds.id = i.stop_id
      and ds.company_id = v_company_id
      and ds.delivery_date = p_date
      and ds.status = 'BOOKED'
      and (ds.window_start is distinct from i.window_start
           or ds.window_end is distinct from i.window_end)
    returning ds.id
  ),
  ev as (
    insert into public.delivery_route_events (
      company_id, date, action, actor_id, details
    )
    select v_company_id, p_date, 'WINDOW_SET', v_employee_id,
           jsonb_build_object('changes', coalesce(jsonb_agg(jsonb_build_object(
             'stop_id', b.id,
             'journey_id', b.journey_id,
             'from_start', b.window_start,
             'from_end', b.window_end,
             'to_start', i.window_start,
             'to_end', i.window_end
           ) order by b.id), '[]'::jsonb))
    from items i
    join public.delivery_stops b on b.id = i.stop_id
    returning id
  )
  select count(*) into v_changed from upd;

  return v_changed;
end;
$$;

revoke execute on function public.set_delivery_stop_windows(date, jsonb)
  from public, anon;
grant execute on function public.set_delivery_stop_windows(date, jsonb)
  to authenticated;
