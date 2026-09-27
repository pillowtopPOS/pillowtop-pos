-- PillowTop POS: preserve the clicked topic label + add
-- 'comfort_improvement' topic.
--
-- Quick topic chips are state-aware labels mapped onto a shared topic
-- taxonomy, so several distinct labels collapse to the same stored
-- value (e.g. Sleep Trial "Comfort Concern" and "Customer Reports
-- Improvement" both stored 'comfort'). This migration:
--   1. Adds 'comfort_improvement' to the topic check constraint so
--      concern-vs-improvement stays distinguishable.
--   2. Adds journey_interactions.topic_label — the exact chip label
--      the user clicked. Not constrained: labels vary by journey
--      state and may change over time.
--   3. Extends record_journey_interaction with p_topic_label.
--
-- IMPORTANT: CREATE OR REPLACE cannot change a function's parameter
-- list — it would create a second overload. The existing 20-parameter
-- version (granted in 059) is dropped by its exact signature first,
-- then recreated with p_topic_label appended last so positional
-- callers keep working, then re-granted to authenticated. The body is
-- 060's version unchanged apart from storing topic_label — the atomic
-- on-conflict idempotency behavior is preserved.

-- ============================================================
-- 1. Topic check constraint: add 'comfort_improvement'
--    (inline column CHECK in 056 is auto-named
--    journey_interactions_topic_check)
-- ============================================================

alter table public.journey_interactions
  drop constraint if exists journey_interactions_topic_check;

alter table public.journey_interactions
  add constraint journey_interactions_topic_check
  check (topic in (
    'inventory_eta',
    'product_delay',
    'delivery',
    'pickup',
    'scheduling',
    'payment',
    'pricing',
    'product_question',
    'order_change',
    'comfort',
    'comfort_improvement',
    'return_exchange',
    'warranty',
    'customer_availability',
    'contact_info',
    'general',
    'other'
  ));

-- ============================================================
-- 2. topic_label column
-- ============================================================

alter table public.journey_interactions
  add column if not exists topic_label text;

comment on column public.journey_interactions.topic_label is 'Exact quick-topic chip label the user clicked (state-specific); topic remains the controlled taxonomy value';

-- ============================================================
-- 3. record_journey_interaction — drop the 20-param signature,
--    recreate with p_topic_label, re-grant to authenticated
-- ============================================================

drop function if exists public.record_journey_interaction(uuid,text,text,text,text,text,text,uuid,text,text,text,timestamptz,boolean,text,date,uuid,text,text,uuid,jsonb);

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
  p_follow_up jsonb default null,
  p_topic_label text default null
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
    topic_label,
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
    nullif(btrim(coalesce(p_topic_label, '')), ''),
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

grant execute on function public.record_journey_interaction(uuid,text,text,text,text,text,text,uuid,text,text,text,timestamptz,boolean,text,date,uuid,text,text,uuid,jsonb,text) to authenticated;

-- Verify exactly one record_journey_interaction exists (no leftover
-- overload from the dropped signature).
do $$
declare
  n int;
begin
  select count(*) into n
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
  where ns.nspname = 'public' and p.proname = 'record_journey_interaction';
  if n <> 1 then
    raise exception 'Expected exactly one record_journey_interaction, found %', n;
  end if;
end;
$$;
