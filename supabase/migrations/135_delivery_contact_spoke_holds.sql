-- ============================================================================
-- 135: "Spoke with customer" now holds like the other hold outcomes.
--
-- Reason: logging "Spoke with customer" from My Work without booking a
-- day means no delivery day was picked, so the ball is with the
-- customer. m134 treated spoke as resolved (never holds); m135 moves it
-- into the hold set.
--
-- Changes (create or replace only; no table changes, no backfill):
--   1. delivery_contact_key_state: 'spoke' joins the hold outcome set
--      (voicemail, no_answer, texted, will_call_back, not_ready, spoke).
--      Every other rule is unchanged: the latest SCHEDULING contact
--      decides, any newer contact in the customer key clears the hold,
--      a delivery_stops row (any status) created for ANY journey in the
--      key after the contact clears it, hold_days = 0 disables holds,
--      hold_until = start of callback_after day in company-local time
--      else occurred_at + hold_days. wrong_number still never holds and
--      still sets bad_number.
--   2. log_delivery_contact: callback_after is now allowed on 'spoke'
--      too. It is still rejected ONLY for 'wrong_number' and still
--      required only for 'not_ready'.
--
-- Grants are re-asserted exactly as in m134: key_state stays revoked
-- from everyone (it only runs inside security-definer callers);
-- log_delivery_contact stays revoked from public/anon and granted to
-- authenticated. Safe to run twice.
-- ============================================================================

-- ============================================================================
-- 1. delivery_contact_key_state - same body as m134 with 'spoke' added
--    to the hold outcome set.
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

  -- Latest delivery contact across the whole customer key (any purpose).
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
    -- Any newer delivery contact anywhere in the key clears the hold.
    select exists (
      select 1
      from public.journey_interactions ji2
      join public.customers jc2 on jc2.id = ji2.customer_id
      where ji2.company_id = p_company_id
        and ji2.entered_in_error_at is null
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

    -- m135: 'spoke' joins the hold set. Spoke without a booking means
    -- no day was picked, so the ball is with the customer.
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

comment on column public.journey_interactions.callback_after is
  'Company-local date the customer asked to be called back. Required for not_ready, allowed on every hold outcome (voicemail, no_answer, texted, will_call_back, not_ready, spoke), rejected for wrong_number. When set it defines hold_until (start of that day, company-local); when omitted the hold falls back to occurred_at + delivery_contact_hold_days.';

-- ============================================================================
-- 2. log_delivery_contact - same body as m134 except callback_after is
--    allowed on 'spoke' and rejected only for 'wrong_number'.
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

  if p_purpose is null or p_purpose not in ('SCHEDULING', 'CONFIRMATION') then
    raise exception 'Purpose must be SCHEDULING or CONFIRMATION';
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

  if p_purpose = 'SCHEDULING' then
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
  else
    -- CONFIRMATION: provisional generic legacy mapping until the
    -- night-before slice defines its outcome list.
    v_interaction_type := 'status_update';
    v_channel := 'phone_outbound';
    v_legacy_outcome := 'information_only';
    v_waiting_on := 'nothing';
    v_summary := 'Delivery confirmation contact.';
  end if;

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
    p_purpose, p_outcome, p_callback_after, p_stop_id, p_window_snapshot,
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
