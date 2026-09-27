-- PillowTop POS: exception-expiry persistence + atomic idempotency.
--
-- Fix 1 — decide_sleep_trial_exception's dead expiry write.
-- The old body did `update ... set status='expired'` and then raised an
-- exception; the raise rolled the update back, so 'expired' never
-- persisted. Now:
--   * decide_* marks the row expired and RETURNS 'expired' normally, so
--     the status change commits.
--   * request_sleep_trial_exception lazily sweeps stale pendings to
--     'expired' before its duplicate check (commits on normal return),
--     which also unblocks creating a fresh request after expiry.
--   * a partial unique index makes "one pending request per journey"
--     an atomic invariant instead of a check-then-insert race.
--
-- Fix 2 — check-then-insert idempotency races.
-- record_journey_interaction, open_sleep_concern, add_sleep_concern_entry,
-- and the follow-up inserts all did `SELECT key; INSERT if absent`. Under
-- a real retry race the loser took a raw unique-constraint error. Every
-- claim is now `insert ... on conflict ... returning` (the same pattern
-- as next_document_number), and the concern-level key moves onto
-- sleep_concerns itself so a duplicate retry returns the existing
-- concern before any orphan concern/issues can be written.

-- ============================================================
-- 1. Schema: concern-level idempotency + dedupe/pending invariants
-- ============================================================

alter table public.sleep_concerns
  add column if not exists idempotency_key text;

create unique index if not exists idx_sleep_concerns_idempotency
  on public.sleep_concerns (idempotency_key)
  where idempotency_key is not null;

-- One issue name once per concern: prevents duplicate issues from
-- concurrent "add entry" calls and meaningless grain for reporting.
create unique index if not exists idx_sleep_concern_issues_unique
  on public.sleep_concern_issues (sleep_concern_id, issue_name);

-- At most one pending exception request per journey, enforced
-- atomically rather than by check-then-insert.
create unique index if not exists idx_sleep_trial_exceptions_pending
  on public.sleep_trial_exception_requests (journey_id)
  where status = 'pending';

-- ============================================================
-- 2. record_journey_interaction — atomic claim for the interaction
--    and the optional follow-up
-- ============================================================

create or replace function public.record_journey_interaction(
  p_journey_id uuid,
  p_interaction_type text,
  p_summary text,
  p_idempotency_key text,
  p_topic text default null,
  p_channel text default null,
  p_direction text default null,
  p_contact_id uuid default null,
  p_outcome text default null,
  p_waiting_on text default null,
  p_commitment_made text default null,
  p_occurred_at timestamptz default null,
  p_is_internal boolean default false,
  p_importance text default 'normal',
  p_pinned_until date default null,
  p_correction_parent_id uuid default null,
  p_request_category text default null,
  p_source_domain text default 'manual',
  p_source_record_id uuid default null,
  p_follow_up jsonb default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee_id uuid;
  v_customer_id uuid;
  v_channel text;
  v_direction text;
  v_contact_name text;
  v_interaction_id uuid;
  v_existing_id uuid;
  v_fu_due timestamptz;
  v_fu_employee uuid;
begin
  if not public.is_journey_visible(p_journey_id) then
    raise exception 'Not authorized to record an interaction for this journey';
  end if;

  if p_summary is null or btrim(p_summary) = '' then
    raise exception 'Interaction summary is required';
  end if;

  -- Idempotent retry fast path: return the previously created row.
  if p_idempotency_key is not null then
    select id into v_existing_id
    from public.journey_interactions
    where idempotency_key = p_idempotency_key;
    if v_existing_id is not null then
      return v_existing_id;
    end if;
  end if;

  select id into v_employee_id
  from public.employees
  where auth_user_id = auth.uid();

  if v_employee_id is null then
    raise exception 'Employee record not found';
  end if;

  select customer_id into v_customer_id
  from public.sleep_journeys
  where id = p_journey_id;

  v_channel := coalesce(p_channel, case p_interaction_type
    when 'customer_called' then 'phone_inbound'
    when 'called_customer' then 'phone_outbound'
    when 'text_conversation' then 'sms'
    when 'email' then 'email'
    when 'in_person' then 'in_person'
    when 'internal_note' then 'internal'
    when 'correction' then 'internal'
    else 'internal'
  end);
  v_direction := coalesce(p_direction, case p_interaction_type
    when 'customer_called' then 'inbound'
    when 'called_customer' then 'outbound'
    when 'status_update' then 'outbound'
    when 'internal_note' then 'internal'
    when 'correction' then 'internal'
    else 'inbound'
  end);

  -- Contact must belong to this journey's customer; snapshot the name
  -- so later contact edits/deletes do not rewrite history.
  if p_contact_id is not null then
    select name into v_contact_name
    from public.customer_contacts
    where id = p_contact_id
      and customer_id = v_customer_id;
    if v_contact_name is null then
      raise exception 'Contact does not belong to this customer';
    end if;
  end if;

  -- Atomic idempotency claim: a concurrent retry of the same key takes
  -- the conflict path instead of a raw unique-constraint error.
  insert into public.journey_interactions (
    journey_id,
    customer_id,
    interaction_type,
    channel,
    direction,
    topic,
    request_category,
    contact_id,
    contact_name_snapshot,
    summary,
    outcome,
    waiting_on,
    commitment_made,
    occurred_at,
    created_by_employee_id,
    source_domain,
    source_record_id,
    is_internal,
    importance,
    pinned_until,
    correction_parent_id,
    idempotency_key
  ) values (
    p_journey_id,
    v_customer_id,
    p_interaction_type,
    v_channel,
    v_direction,
    p_topic,
    p_request_category,
    p_contact_id,
    v_contact_name,
    btrim(p_summary),
    p_outcome,
    p_waiting_on,
    nullif(btrim(coalesce(p_commitment_made, '')), ''),
    coalesce(p_occurred_at, now()),
    v_employee_id,
    coalesce(p_source_domain, 'manual'),
    p_source_record_id,
    coalesce(p_is_internal, p_interaction_type in ('internal_note','correction')),
    coalesce(p_importance, 'normal'),
    p_pinned_until,
    p_correction_parent_id,
    p_idempotency_key
  )
  on conflict (idempotency_key) where idempotency_key is not null
  do nothing
  returning id into v_interaction_id;

  if v_interaction_id is null then
    -- Lost the race: the winner's row is committed and visible now.
    select id into v_interaction_id
    from public.journey_interactions
    where idempotency_key = p_idempotency_key;
    return v_interaction_id;
  end if;

  -- Optional follow-up in the same transaction: either everything is
  -- recorded or nothing is, so there is no partial-failure window.
  if p_follow_up is not null and p_follow_up->>'due_at' is not null then
    v_fu_due := (p_follow_up->>'due_at')::timestamptz;
    v_fu_employee := coalesce(
      nullif(p_follow_up->>'employee_id', '')::uuid,
      v_employee_id
    );

    insert into public.follow_ups (
      journey_id,
      employee_id,
      type,
      due_at,
      notes,
      method,
      journey_interaction_id,
      idempotency_key
    ) values (
      p_journey_id,
      v_fu_employee,
      'interaction',
      v_fu_due,
      coalesce(p_follow_up->>'notes', 'Follow up: ' || left(btrim(p_summary), 120)),
      p_follow_up->>'method',
      v_interaction_id,
      p_follow_up->>'idempotency_key'
    )
    on conflict (idempotency_key) where idempotency_key is not null
    do nothing;
  end if;

  return v_interaction_id;
end;
$$;

-- ============================================================
-- 3. append_sleep_concern_entry — the entry row claims its key
--    atomically BEFORE the feed interaction is written, so a retry
--    race returns the winner's entry instead of erroring.
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
  -- Defense in depth: internal callers already check journey visibility,
  -- but this helper is security definer, so enforce it here too.
  if not public.is_journey_visible(p_journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  if p_contact_id is not null then
    select name into v_contact_name
    from public.customer_contacts
    where id = p_contact_id and customer_id = p_customer_id;
    if v_contact_name is null then
      raise exception 'Contact does not belong to this customer';
    end if;
  end if;

  -- Claim the idempotency key first. On a retry race this returns no
  -- row and we hand back the winner's entry — no duplicate entry and
  -- no duplicate feed interaction.
  insert into public.sleep_concern_entries (
    sleep_concern_id, entry_type,
    customer_report, employee_notes, recommendation_summary,
    created_by_employee_id, occurred_at, idempotency_key
  ) values (
    p_concern_id, coalesce(p_entry_type, 'update'),
    nullif(btrim(coalesce(p_customer_report, '')), ''),
    nullif(btrim(coalesce(p_employee_notes, '')), ''),
    nullif(btrim(coalesce(p_recommendation, '')), ''),
    p_employee_id, coalesce(p_occurred_at, now()), p_idempotency_key
  )
  on conflict (idempotency_key) where idempotency_key is not null
  do nothing
  returning id into v_entry_id;

  if v_entry_id is null then
    select id into v_entry_id
    from public.sleep_concern_entries
    where idempotency_key = p_idempotency_key;
    return v_entry_id;
  end if;

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, contact_id, contact_name_snapshot, summary,
    occurred_at, created_by_employee_id,
    source_domain, source_record_id, is_internal
  ) values (
    p_journey_id, p_customer_id, 'issue_concern',
    coalesce(p_channel, 'phone_inbound'),
    case when coalesce(p_channel, 'phone_inbound') in ('phone_outbound') then 'outbound'
         when coalesce(p_channel, 'phone_inbound') = 'internal' then 'internal'
         else 'inbound' end,
    'comfort', p_contact_id, v_contact_name, p_summary,
    coalesce(p_occurred_at, now()), p_employee_id,
    'sleep_concern', v_entry_id, false
  )
  returning id into v_interaction_id;

  update public.sleep_concern_entries
  set journey_interaction_id = v_interaction_id
  where id = v_entry_id;

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
-- 4. open_sleep_concern — the claim is on the concern row itself.
--    Ordering matters: the atomic claim runs BEFORE the duplicate-
--    episode check so a retry returns the existing concern instead
--    of tripping 'existing_open_concern'. A fresh call that loses the
--    duplicate check aborts and rolls its new concern row back.
-- ============================================================

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
  if v_journey.delivered_at is null then
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

-- ============================================================
-- 5. add_sleep_concern_entry — atomic claim via the entry insert,
--    with a unique_violation safety net so ANY concurrent-claim
--    conflict returns the existing entry rather than a raw error.
-- ============================================================

create or replace function public.add_sleep_concern_entry(
  p_concern_id uuid,
  p_idempotency_key text,
  p_customer_report text default null,
  p_employee_notes text default null,
  p_recommendation text default null,
  p_diagnostics jsonb default null,
  p_new_issues jsonb default null,
  p_new_status text default null,
  p_resolution_type text default null,
  p_resolution_summary text default null,
  p_follow_up jsonb default null,
  p_contact_id uuid default null,
  p_channel text default null,
  p_occurred_at timestamptz default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_concern public.sleep_concerns%rowtype;
  v_employee_id uuid;
  v_existing uuid;
  v_entry_id uuid;
  v_issue jsonb;
  v_summary text;
begin
  select * into v_concern from public.sleep_concerns where id = p_concern_id;
  if v_concern.id is null then
    raise exception 'Concern not found';
  end if;

  if not public.is_journey_visible(v_concern.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select id into v_employee_id
  from public.employees where auth_user_id = auth.uid();
  if v_employee_id is null then
    raise exception 'Employee record not found';
  end if;

  if v_concern.status in ('resolved','exchange_requested') then
    raise exception 'Concern is % and cannot be updated', v_concern.status;
  end if;

  if p_idempotency_key is not null then
    select id into v_existing
    from public.sleep_concern_entries
    where idempotency_key = p_idempotency_key
      and sleep_concern_id = p_concern_id;
    if v_existing is not null then
      return v_existing;
    end if;
  end if;

  v_summary := coalesce(
    nullif(btrim(p_customer_report), ''),
    nullif(btrim(p_recommendation), ''),
    nullif(btrim(p_employee_notes), ''),
    'Concern update'
  );

  -- Everything below is inside a subtransaction: if any concurrent
  -- claim wins (entry key, issue name, follow-up key), the partial
  -- work rolls back and the winner's entry is returned instead of a
  -- raw constraint error.
  begin
    v_entry_id := public.append_sleep_concern_entry(
      p_concern_id, v_concern.journey_id, v_concern.customer_id, v_employee_id,
      'update', v_summary,
      p_customer_report, p_employee_notes, p_recommendation,
      p_diagnostics, p_idempotency_key, p_occurred_at,
      p_contact_id, p_channel
    );

    if p_new_issues is not null then
      for v_issue in select * from jsonb_array_elements(p_new_issues)
      loop
        insert into public.sleep_concern_issues (
          sleep_concern_id, concern_type_id, issue_name, added_by_employee_id
        ) values (
          p_concern_id,
          nullif(v_issue->>'concern_type_id','')::uuid,
          coalesce(nullif(btrim(v_issue->>'name'), ''), 'Other'),
          v_employee_id
        )
        on conflict (sleep_concern_id, issue_name) do nothing;
      end loop;
    end if;

    if p_new_status is not null and p_new_status <> v_concern.status then
      if p_new_status not in ('open','monitoring','resolved','escalated') then
        raise exception 'Invalid concern status: %', p_new_status;
      end if;
      update public.sleep_concerns
      set status = p_new_status,
          resolved_at = case when p_new_status = 'resolved' then now() else null end,
          resolved_by_employee_id = case when p_new_status = 'resolved' then v_employee_id else null end,
          resolution_type = case when p_new_status = 'resolved' then p_resolution_type else null end,
          resolution_summary = case when p_new_status = 'resolved' then p_resolution_summary else null end,
          updated_at = now()
      where id = p_concern_id;
    end if;

    if p_follow_up is not null and p_follow_up->>'due_at' is not null then
      insert into public.follow_ups (
        journey_id, employee_id, type, due_at, notes, method,
        journey_interaction_id, sleep_concern_id, idempotency_key
      ) values (
        v_concern.journey_id,
        coalesce(nullif(p_follow_up->>'employee_id','')::uuid, v_employee_id),
        'sleep_concern',
        (p_follow_up->>'due_at')::timestamptz,
        coalesce(p_follow_up->>'notes', 'Sleep concern follow-up'),
        p_follow_up->>'method',
        (select journey_interaction_id from public.sleep_concern_entries where id = v_entry_id),
        p_concern_id,
        p_follow_up->>'idempotency_key'
      )
      on conflict (idempotency_key) where idempotency_key is not null
      do nothing;
    end if;
  exception
    when unique_violation then
      -- Lost a concurrent claim: roll back to the block start and
      -- return the entry that already carries this key, if any.
      select id into v_existing
      from public.sleep_concern_entries
      where idempotency_key = p_idempotency_key
        and sleep_concern_id = p_concern_id;
      if v_existing is not null then
        return v_existing;
      end if;
      raise;
  end;

  return v_entry_id;
end;
$$;

-- ============================================================
-- 6. request_sleep_trial_exception — lazy expiry sweep + atomic
--    one-pending invariant
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

  -- Persisted lazy expiry: stale pendings become 'expired' here and
  -- COMMIT when this function returns normally — the transition is
  -- real, not rolled back by a later error. This also keeps the
  -- pending-duplicate check below from being blocked forever by a
  -- request whose window has passed.
  update public.sleep_trial_exception_requests
  set status = 'expired'
  where journey_id = p_journey_id
    and status = 'pending'
    and expires_at is not null
    and expires_at <= now();

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
exception
  when unique_violation then
    -- Concurrent pending request won the unique-index race.
    raise exception 'An early exchange exception request is already pending for this journey';
end;
$$;

-- ============================================================
-- 7. decide_sleep_trial_exception — persisted expiry + atomic decide.
--    Return type changes uuid → text so the caller learns the
--    outcome ('approved' | 'denied' | 'expired').
-- ============================================================

drop function if exists public.decide_sleep_trial_exception(uuid, text);

create function public.decide_sleep_trial_exception(
  p_request_id uuid,
  p_decision text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.sleep_trial_exception_requests%rowtype;
  v_approver uuid;
  v_company_id uuid;
begin
  if p_decision not in ('approved','denied') then
    raise exception 'Decision must be approved or denied';
  end if;

  select * into v_request
  from public.sleep_trial_exception_requests
  where id = p_request_id;

  if v_request.id is null then
    raise exception 'Exception request not found';
  end if;

  -- Persisted expiry: the status change is followed by a normal
  -- RETURN, so it commits — the row really becomes 'expired' in the
  -- database, not just in the error the caller sees.
  if v_request.status = 'pending'
     and v_request.expires_at is not null
     and v_request.expires_at <= now() then
    update public.sleep_trial_exception_requests
    set status = 'expired'
    where id = p_request_id;
    return 'expired';
  end if;

  if v_request.status <> 'pending' then
    raise exception 'Only pending requests may be decided';
  end if;

  select e.id, s.company_id
  into v_approver, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid();

  if v_approver is null or v_approver = v_request.requester_employee_id then
    raise exception 'Requester cannot decide their own request';
  end if;

  if not exists (
    select 1
    from public.sleep_journeys sj
    join public.stores js on js.id = sj.store_id
    where sj.id = v_request.journey_id
      and js.company_id = v_company_id
  ) then
    raise exception 'Not authorized to decide this request';
  end if;

  if not exists (
    select 1 from public.employees
    where id = v_approver and role::text in ('owner','admin','manager')
  ) then
    raise exception 'Only owner, admin, or manager may decide exception requests';
  end if;

  -- Atomic decide: the status predicate is re-evaluated after any row
  -- lock wait, so a concurrent decision can't be overwritten.
  update public.sleep_trial_exception_requests
  set status = p_decision,
      approver_employee_id = v_approver,
      decided_at = now()
  where id = p_request_id
    and status = 'pending';

  if not found then
    raise exception 'This request was already decided';
  end if;

  -- Record the decision in Journey Activity.
  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain, source_record_id, is_internal
  )
  select v_request.journey_id, sj.customer_id, 'other', 'internal', 'internal',
    'return_exchange',
    'Early exchange exception ' || p_decision || '.',
    v_approver, 'sleep_trial_exception', p_request_id, true
  from public.sleep_journeys sj where sj.id = v_request.journey_id;

  return p_decision;
end;
$$;

grant execute on function public.decide_sleep_trial_exception(uuid,text) to authenticated;

-- ============================================================
-- 8. request_concern_exchange — same check-then-update race: the
--    status predicate moves into the UPDATE so a concurrent call
--    can't also pass and write a duplicate status_change entry.
-- ============================================================

create or replace function public.request_concern_exchange(p_concern_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_concern public.sleep_concerns%rowtype;
  v_employee_id uuid;
  v_status record;
  v_approved_exception boolean;
begin
  select * into v_concern from public.sleep_concerns where id = p_concern_id;
  if v_concern.id is null then
    raise exception 'Concern not found';
  end if;
  if not public.is_journey_visible(v_concern.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select id into v_employee_id
  from public.employees where auth_user_id = auth.uid();
  if v_employee_id is null then
    raise exception 'Employee record not found';
  end if;

  select * into v_status from public.trial_status(v_concern.journey_id);

  select exists (
    select 1 from public.sleep_trial_exception_requests r
    where r.journey_id = v_concern.journey_id
      and r.status = 'approved'
  ) into v_approved_exception;

  if not coalesce(v_status.eligible, false) and not v_approved_exception then
    raise exception 'Journey is not yet exchange-eligible. Request an early exchange exception first.';
  end if;

  -- Atomic: the terminal-status predicate is re-checked under the row
  -- lock, so a concurrent exchange request can't double-write.
  update public.sleep_concerns
  set status = 'exchange_requested', updated_at = now()
  where id = p_concern_id
    and status not in ('resolved','exchange_requested');

  if not found then
    raise exception 'Concern is already %', v_concern.status;
  end if;

  perform public.append_sleep_concern_entry(
    p_concern_id, v_concern.journey_id, v_concern.customer_id, v_employee_id,
    'status_change',
    'Customer wants an exchange — exchange requested.',
    null, null, null, null, null, null, null, 'internal'
  );

  return p_concern_id;
end;
$$;

grant execute on function public.request_concern_exchange(uuid) to authenticated;
