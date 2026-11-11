-- PillowTop POS m134: delivery contact log on journey_interactions.
--
-- ONE contact log, tied to the ORDER (journey_id) and the CUSTOMER
-- (customer_id), serving SCHEDULING calls now and CONFIRMATION calls
-- (night-before window call) later. Extends journey_interactions - no
-- parallel table - so "when did we last talk to this person" has a
-- single source.
--
-- New columns (all nullable or defaulted; existing rows untouched, no
-- backfill):
--   purpose            GENERAL (default) | SCHEDULING | CONFIRMATION
--   contact_outcome    structured outcome; see check + mapping below
--   callback_after     date, SCHEDULING only (validated in the RPC)
--   stop_id            delivery_stops link, CONFIRMATION slice (unused now)
--   window_snapshot    jsonb, CONFIRMATION slice (unused now)
--   company_id         denormalized from the journey's store at insert;
--                      NULL on every pre-m134 row. EVERY read treats
--                      NULL company_id as "not a delivery contact".
--
-- contact_outcome check: the seven SCHEDULING values are constrained;
-- CONFIRMATION rows may carry any non-null outcome text TODAY so the
-- night-before slice can add its own outcome list. When that slice
-- lands, tighten by replacing journey_interactions_contact_outcome_check
-- with the confirmed value list - no data rewrite needed because the
-- RPC is the only write path.
--
-- Hold is COMPUTED at read time (delivery_contact_key_state), never
-- stored, so it cannot go stale.
--
-- Safe to run twice (if not exists / create or replace).

-- ============================================================================
-- 1. companies.delivery_contact_hold_days - "Waiting on customer" window.
--    0 disables holds entirely. Edited via get_/set_delivery_contact_hold_days
--    (owner/admin, same rule as week_start_day / delivery cutoff).
-- ============================================================================

alter table public.companies
  add column if not exists delivery_contact_hold_days integer not null default 2
    check (delivery_contact_hold_days between 0 and 14);

-- ============================================================================
-- 2. journey_interactions columns
-- ============================================================================

alter table public.journey_interactions
  add column if not exists purpose text not null default 'GENERAL';

alter table public.journey_interactions
  add column if not exists contact_outcome text;

alter table public.journey_interactions
  add column if not exists callback_after date;

alter table public.journey_interactions
  add column if not exists stop_id uuid
    references public.delivery_stops (id) on delete set null;

alter table public.journey_interactions
  add column if not exists window_snapshot jsonb;

alter table public.journey_interactions
  add column if not exists company_id uuid
    references public.companies (id) on delete set null;

alter table public.journey_interactions
  drop constraint if exists journey_interactions_purpose_check;
alter table public.journey_interactions
  add constraint journey_interactions_purpose_check
  check (purpose in ('GENERAL', 'SCHEDULING', 'CONFIRMATION'));

-- SCHEDULING outcomes are a closed list. CONFIRMATION is deliberately
-- unconstrained for now (any non-null text); tighten the check when the
-- night-before slice defines its outcome list.
alter table public.journey_interactions
  drop constraint if exists journey_interactions_contact_outcome_check;
alter table public.journey_interactions
  add constraint journey_interactions_contact_outcome_check
  check (
    contact_outcome is null
    or (purpose = 'SCHEDULING' and contact_outcome in (
      'spoke', 'voicemail', 'no_answer', 'texted',
      'will_call_back', 'not_ready', 'wrong_number'))
    or (purpose = 'CONFIRMATION')
  );

comment on column public.journey_interactions.purpose is
  'GENERAL = ordinary journey interaction; SCHEDULING = delivery-day call log; CONFIRMATION = night-before window call (next slice)';
comment on column public.journey_interactions.contact_outcome is
  'Structured delivery-contact outcome. SCHEDULING values: spoke, voicemail, no_answer, texted, will_call_back, not_ready, wrong_number. CONFIRMATION values defined by the next slice (check currently permits any non-null text).';
comment on column public.journey_interactions.callback_after is
  'Company-local date the customer asked to be called back. Required for not_ready, allowed on every hold outcome (voicemail, no_answer, texted, will_call_back, not_ready), rejected for spoke/wrong_number. When set it defines hold_until (start of that day, company-local); when omitted the hold falls back to occurred_at + delivery_contact_hold_days.';
comment on column public.journey_interactions.company_id is
  'Denormalized company of the journey''s store, set server-side at insert. NULL = not a delivery contact (all pre-m134 rows). Reads must always filter on it; never join across companies.';

-- ============================================================================
-- 3. Indexes - justified by the read shapes below:
--    * key_state / history look up a company''s delivery contacts by
--      customer_id (fast path) and scan by occurred_at for phone matches
--      and "latest contact" (company-scoped, delivery rows only).
--    * delivery_stops (journey_id, created_at) serves the hold rule
--      "no stop created for any key journey after the contact" - the
--      existing indexes are partial (BOOKED only) or keyed by date.
--    * customers expression index supports resolving "same person"
--      lookups by normalized phone.
-- ============================================================================

create index if not exists journey_interactions_company_customer_occurred
  on public.journey_interactions (company_id, customer_id, occurred_at desc)
  where company_id is not null;

create index if not exists journey_interactions_company_occurred
  on public.journey_interactions (company_id, occurred_at desc)
  where company_id is not null;

create index if not exists delivery_stops_journey_created
  on public.delivery_stops (journey_id, created_at);

-- ============================================================================
-- 4. delivery_norm_phone - canonical phone for customer-key matching.
--    Digits only; a leading 1 on an 11-digit number is dropped; must be
--    exactly 10 digits; repeated-digit numbers and 1234567890 are junk.
--    Resolved at READ time from customers.phone, so a corrected typo
--    heals history - no phone snapshot is stored.
-- ============================================================================

create or replace function public.delivery_norm_phone(p_phone text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  v text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
begin
  if length(v) = 11 and left(v, 1) = '1' then
    v := substr(v, 2);
  end if;
  if length(v) <> 10 then
    return null;
  end if;
  if v ~ '^(.)\1{9}$' or v = '1234567890' then
    return null;
  end if;
  return v;
end;
$$;

-- customers_norm_phone_idx evaluates this function on every INSERT or
-- UPDATE of customers.phone under the CALLING user's rights, so
-- authenticated (and service_role) must keep EXECUTE or order entry
-- breaks with "permission denied for function". It is immutable and
-- exposes nothing.
revoke execute on function public.delivery_norm_phone(text) from public, anon;
grant execute on function public.delivery_norm_phone(text) to authenticated, service_role;

-- Functional index on the normalized phone expression (customers.phone
-- itself is never indexed by content). Lets "find customers sharing this
-- normalized phone" use an index instead of a table scan.
create index if not exists customers_norm_phone_idx
  on public.customers ((public.delivery_norm_phone(phone)));

-- ============================================================================
-- 5. delivery_contact_key_state - the computed hold + last-contact state
--    for one customer key inside one company.
--
--    Customer key = contact rows with company_id = p_company_id,
--    entered_in_error_at is null, and (contact.customer_id =
--    p_customer_id OR normalized phone of the contact''s customer equals
--    p_norm_phone). Never crosses companies: company_id on the contact
--    row is the hard boundary.
--
--    Hold rules (all must hold):
--      * latest SCHEDULING contact outcome in the hold set
--        (voicemail, no_answer, texted, will_call_back, not_ready)
--      * companies.delivery_contact_hold_days > 0
--      * no newer delivery contact exists anywhere in the key
--      * no delivery_stops row (ANY status) was created for ANY journey
--        in the key after that contact
--      * now() < hold_until
--    hold_until = start of callback_after day in company-local time when
--    set, else occurred_at + hold_days days. callback_due flips true
--    once callback_after <= company-local today. wrong_number never
--    holds (bad_number instead, until a newer contact). spoke never
--    holds. A hold is a SIGNAL, never a lock.
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

    v_held := v_cand.contact_outcome in (
        'voicemail', 'no_answer', 'texted', 'will_call_back', 'not_ready')
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
-- 6. log_delivery_contact - the ONE write path for delivery contacts.
--
--    contact_outcome -> legacy journey_interactions mapping (so Journey
--    Activity and "Last customer contact" keep working):
--
--      outcome        | interaction_type | channel      | outcome          | waiting_on
--      ---------------|------------------|--------------|------------------|------------
--      spoke          | called_customer  | phone_outbound| resolved        | nothing
--      voicemail      | called_customer  | phone_outbound| no_response     | customer
--      no_answer      | called_customer  | phone_outbound| no_response     | customer
--      texted         | text_conversation| sms          | no_response     | customer
--      will_call_back | called_customer  | phone_outbound| follow_up_needed| customer
--      not_ready      | called_customer  | phone_outbound| waiting_on_customer| customer
--      wrong_number   | called_customer  | phone_outbound| no_response     | customer
--
--    All rows: direction 'outbound', topic 'scheduling', topic_label
--    'Delivery scheduling', source_domain 'manual', is_internal false,
--    importance 'normal'. p_note is appended to the summary. For
--    CONFIRMATION (next slice) the legacy columns get a provisional
--    generic mapping; it firms up when confirmation outcomes are
--    defined. No automatic follow-up creation.
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
    -- no_answer, texted, will_call_back, not_ready) and rejected only
    -- for the resolved outcomes (spoke, wrong_number).
    if p_outcome in ('spoke', 'wrong_number')
       and p_callback_after is not null then
      raise exception 'A callback date only applies when we are waiting on the customer';
    end if;
    if p_callback_after is not null then
      if p_callback_after < v_today then
        raise exception 'The callback date must be today or later';
      end if;
      if p_callback_after > v_today + 90 then
        raise exception 'The callback date must be within 90 days';
      end if;
    end if;

    -- Legacy mapping (see header comment).
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

-- ============================================================================
-- 7. get_delivery_contact_history - contacts across the customer key for
--    one order, plus the computed hold state and a recency value for the
--    "called N minutes ago" notice.
-- ============================================================================

create or replace function public.get_delivery_contact_history(
  p_journey_id uuid,
  p_limit integer default 20
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_company_id uuid;
  v_norm_phone text;
  v_state jsonb;
  v_contacts jsonb;
begin
  if not public.is_journey_visible(p_journey_id) then
    raise exception 'Not authorized to view delivery contacts for this order';
  end if;

  select sj.customer_id, st.company_id
    into v_customer_id, v_company_id
  from public.sleep_journeys sj
  join public.stores st on st.id = sj.store_id
  where sj.id = p_journey_id;
  if v_customer_id is null then
    raise exception 'Order not found';
  end if;

  select public.delivery_norm_phone(c.phone) into v_norm_phone
  from public.customers c where c.id = v_customer_id;

  v_state := public.delivery_contact_key_state(
    v_company_id, v_customer_id, v_norm_phone, p_journey_id);

  select coalesce(jsonb_agg(row_json order by occurred_at desc, recorded_at desc), '[]'::jsonb)
    into v_contacts
  from (
    select
      ji.occurred_at, ji.recorded_at,
      jsonb_build_object(
        'journey_id', ji.journey_id,
        'journey_number', sjn.journey_number,
        'customer_name', jc.first_name || ' ' || jc.last_name,
        'employee_name', e.name,
        'purpose', ji.purpose,
        'contact_outcome', ji.contact_outcome,
        'note', ji.summary,
        'occurred_at', ji.occurred_at,
        'callback_after', ji.callback_after,
        'on_this_order', ji.journey_id = p_journey_id
      ) as row_json
    from public.journey_interactions ji
    join public.sleep_journeys sjn on sjn.id = ji.journey_id
    join public.customers jc on jc.id = ji.customer_id
    left join public.employees e on e.id = ji.created_by_employee_id
    where ji.company_id = v_company_id
      and ji.entered_in_error_at is null
      and (ji.customer_id = v_customer_id
           or (v_norm_phone is not null
               and public.delivery_norm_phone(jc.phone) = v_norm_phone))
    order by ji.occurred_at desc, ji.recorded_at desc
    limit least(greatest(coalesce(p_limit, 20), 1), 100)
  ) t;

  return v_state || jsonb_build_object('contacts', v_contacts);
end;
$$;

revoke execute on function public.get_delivery_contact_history(uuid, integer)
  from public, anon;
grant execute on function public.get_delivery_contact_history(uuid, integer)
  to authenticated;

-- ============================================================================
-- 8. get_/set_delivery_contact_hold_days - company setting, owner/admin
--    edit (same rule as set_company_week_start / the delivery cutoff's
--    can_edit flag).
-- ============================================================================

create or replace function public.get_delivery_contact_hold_days()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_days integer;
  v_role text;
begin
  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid() and e.is_active;
  if v_company_id is null then
    raise exception 'Only active employees can view company settings.';
  end if;

  select c.delivery_contact_hold_days into v_days
  from public.companies c where c.id = v_company_id;

  select e.role::text into v_role
  from public.employees e
  where e.auth_user_id = auth.uid() and e.is_active;

  return jsonb_build_object(
    'hold_days', coalesce(v_days, 2),
    'can_edit', coalesce(v_role in ('owner', 'admin'), false)
  );
end;
$$;

revoke execute on function public.get_delivery_contact_hold_days() from public, anon;
grant execute on function public.get_delivery_contact_hold_days() to authenticated;

create or replace function public.set_delivery_contact_hold_days(p_days integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_role text;
begin
  select e.role, s.company_id into v_role, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid() and e.is_active;

  if v_role is null or v_role not in ('owner', 'admin') then
    raise exception 'Only owners and admins can change company settings.';
  end if;
  if v_company_id is null then
    raise exception 'Only active employees can change company settings.';
  end if;
  if p_days is null or p_days < 0 or p_days > 14 then
    raise exception 'Hold days must be a whole number between 0 and 14.';
  end if;

  update public.companies
  set delivery_contact_hold_days = p_days
  where id = v_company_id;
end;
$$;

revoke execute on function public.set_delivery_contact_hold_days(integer) from public, anon;
grant execute on function public.set_delivery_contact_hold_days(integer) to authenticated;

-- ============================================================================
-- 9. list_ready_journeys - same signature and existing keys, plus per-row
--    delivery-contact state. create or replace keeps the (boolean) ->
--    jsonb signature so grants survive; anon/public execute is revoked
--    explicitly below (it was only implicitly blocked before).
-- ============================================================================

create or replace function public.list_ready_journeys(p_all_stores boolean default false)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_employee public.employees%rowtype;
  v_active_store uuid;
  v_company_id uuid;
begin
  select * into v_employee
  from public.employees
  where auth_user_id = auth.uid()
    and is_active;
  if v_employee.id is null then
    return '[]'::jsonb;
  end if;

  -- Same claim is_store_visible reads; a missing or malformed value means
  -- rule 2 simply does not apply rather than raising a cast error.
  begin
    v_active_store := (auth.jwt() -> 'user_metadata' ->> 'active_store_id')::uuid;
  exception when others then
    v_active_store := null;
  end;

  -- Caller's company via their home store - the same resolution
  -- has_permission and the rest of the app use. Null home store means
  -- no company rows, which is the safe direction.
  select s.company_id into v_company_id
  from public.stores s
  where s.id = v_employee.home_store_id;

  return coalesce((
    -- MATERIALIZED is load-bearing: without it the planner inlines these
    -- CTEs and re-runs delivery_contact_key_state once per joined row
    -- (measured: ~4.2s for 500 rows vs ~33ms materialized at 20k
    -- interactions).
    with base as materialized (
      select
        sj.id as journey_id,
        sj.customer_id,
        sj.journey_number,
        sj.ready_after_wait_at,
        sj.assigned_employee_id,
        public.delivery_norm_phone(c.phone) as norm_phone,
        c.first_name || ' ' || c.last_name as customer_name,
        s.name as store_name,
        e.name as assigned_employee_name,
        coalesce(ready_ev.ready_at, sj.ready_after_wait_at, sj.updated_at) as ready_at,
        coalesce(ready_ev.ready_at, sj.ready_after_wait_at, sj.updated_at) as stamp
      from public.sleep_journeys sj
      join public.customers c on c.id = sj.customer_id
      join public.stores s on s.id = sj.store_id
      left join public.employees e on e.id = sj.assigned_employee_id
      left join lateral (
        select max(je.created_at) as ready_at
        from public.journey_events je
        where je.journey_id = sj.id
          and je.event_type = 'inventory_received'
      ) ready_ev on true
      where sj.current_state = 'Ready to Schedule'
        and sj.fulfillment_type = 'delivery'
        and sj.cancelled_at is null
        and sj.delivered_at is null
        and exists (
          select 1
          from public.journey_line_items li2
          where li2.journey_id = sj.id
            and coalesce(li2.fulfillment_type_override, sj.fulfillment_type) <> 'pickup'
        )
        and s.company_id = v_company_id
        and (
          p_all_stores
          or sj.assigned_employee_id = v_employee.id
          or (v_active_store is not null and v_active_store = sj.store_id)
          or (v_employee.role = 'manager'
              and v_employee.home_store_id = sj.store_id)
        )
    ),
    -- One key-state computation per distinct customer key, not per row:
    -- several ready orders for the same person share the same contact
    -- set, and the per-call cost is a scan of that company's contacts.
    keys as materialized (
      select distinct customer_id, norm_phone
      from base
    ),
    states as materialized (
      select k.customer_id, k.norm_phone,
        public.delivery_contact_key_state(
          v_company_id, k.customer_id, k.norm_phone, null) as dc
      from keys k
    )
    select jsonb_agg(r.row order by r.ready_at asc nulls last, r.stamp)
    from (
      select
        b.ready_at,
        b.stamp,
        jsonb_build_object(
          'journey_id', b.journey_id,
          'journey_number', b.journey_number,
          'customer_name', b.customer_name,
          'store_name', b.store_name,
          'ready_after_wait_at', b.ready_after_wait_at,
          'ready_at', b.ready_at,
          'assigned_employee_name', b.assigned_employee_name,
          'item_summary', case
            when items.n = 0 then null
            when items.n = 1 then items.first_name
            else items.first_name || ' and ' || (items.n - 1) || ' more'
          end,
          'last_contact', case
            when jsonb_typeof(st.dc -> 'last_contact') = 'object'
            then (st.dc -> 'last_contact') || jsonb_build_object(
              'on_this_order',
              (st.dc -> 'last_contact' ->> 'journey_id') = b.journey_id::text)
            else null
          end,
          'held', coalesce((st.dc ->> 'held')::boolean, false),
          'hold_until', st.dc -> 'hold_until',
          'callback_due', coalesce((st.dc ->> 'callback_due')::boolean, false),
          'bad_number', coalesce((st.dc ->> 'bad_number')::boolean, false)
        ) as row
      from base b
      join states st
        on st.customer_id = b.customer_id
       and st.norm_phone is not distinct from b.norm_phone
      left join lateral (
        select
          (array_agg(li.item_name order by li.created_at))[1] as first_name,
          count(*) as n
        from public.journey_line_items li
        where li.journey_id = b.journey_id
      ) items on true
    ) r
  ), '[]'::jsonb);
end;
$$;

revoke execute on function public.list_ready_journeys(boolean) from public, anon;
grant execute on function public.list_ready_journeys(boolean) to authenticated;
