-- PillowTop POS: Journey Interaction foundation + customer contacts +
-- general-purpose follow-ups.
--
-- journey_interactions is the append-oriented record of meaningful
-- customer/employee conversation (calls, texts, in-person, internal notes).
-- It is deliberately NOT an extension of journey_events, which remains a
-- closed-enum transition log that drives state derivation and automation.
--
-- follow_ups.type is widened from ('quote','deposit') to include
-- 'interaction' so Journey Interaction follow-ups share the existing
-- table and the existing My Work projection. No second task system.

-- ============================================================
-- 1. Customer contacts
--    A customer can have multiple named contacts (e.g. a delivery
--    contact distinct from the primary customer). Each interaction
--    can reference one.
-- ============================================================

create table if not exists public.customer_contacts (
  id uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers (id) on delete cascade,
  name text not null,
  role_label text,
  phone text,
  email text,
  is_delivery_contact boolean not null default false,
  created_by_employee_id uuid references public.employees (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.customer_contacts is 'Named contacts for a customer (delivery contact, spouse, etc.)';

create index if not exists idx_customer_contacts_customer
  on public.customer_contacts (customer_id);

alter table public.customer_contacts enable row level security;

drop policy if exists "Customer contacts viewable by authenticated users" on public.customer_contacts;
create policy "Customer contacts viewable by authenticated users"
  on public.customer_contacts for select
  to authenticated
  using (public.is_customer_visible(customer_id));

drop policy if exists "Customer contacts insertable by authenticated users" on public.customer_contacts;
create policy "Customer contacts insertable by authenticated users"
  on public.customer_contacts for insert
  to authenticated
  with check (public.is_customer_visible(customer_id));

drop policy if exists "Customer contacts updatable by authenticated users" on public.customer_contacts;
create policy "Customer contacts updatable by authenticated users"
  on public.customer_contacts for update
  to authenticated
  using (public.is_customer_visible(customer_id))
  with check (public.is_customer_visible(customer_id));

drop policy if exists "Customer contacts deletable by authenticated users" on public.customer_contacts;
create policy "Customer contacts deletable by authenticated users"
  on public.customer_contacts for delete
  to authenticated
  using (public.is_customer_visible(customer_id));

grant select, insert, update, delete on public.customer_contacts to authenticated;

-- ============================================================
-- 2. Journey interactions
--    Append-oriented. No UPDATE/DELETE policies for authenticated:
--    substantive history is corrected via a correction row or marked
--    entered-in-error through RPCs, never hard-deleted.
-- ============================================================

create table if not exists public.journey_interactions (
  id uuid primary key default gen_random_uuid(),
  journey_id uuid not null references public.sleep_journeys (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete restrict,
  interaction_type text not null check (interaction_type in (
    'customer_called',
    'called_customer',
    'text_conversation',
    'email',
    'in_person',
    'customer_request',
    'status_update',
    'issue_concern',
    'internal_note',
    'other',
    'correction'
  )),
  channel text not null check (channel in (
    'phone_inbound',
    'phone_outbound',
    'sms',
    'email',
    'in_person',
    'internal',
    'system'
  )),
  direction text not null check (direction in ('inbound','outbound','internal','system')),
  topic text check (topic in (
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
    'return_exchange',
    'warranty',
    'customer_availability',
    'contact_info',
    'general',
    'other'
  )),
  request_category text,
  contact_id uuid references public.customer_contacts (id) on delete set null,
  contact_name_snapshot text,
  summary text not null,
  outcome text check (outcome in (
    'resolved',
    'follow_up_needed',
    'waiting_on_customer',
    'waiting_on_retailer',
    'waiting_on_external',
    'escalated',
    'no_response',
    'information_only'
  )),
  waiting_on text check (waiting_on in (
    'nothing',
    'customer',
    'inventory',
    'vendor',
    'delivery_team',
    'manager',
    'another_employee',
    'external_party'
  )),
  commitment_made text,
  occurred_at timestamptz not null default now(),
  recorded_at timestamptz not null default now(),
  created_by_employee_id uuid references public.employees (id) on delete set null,
  source_domain text not null default 'manual',
  source_record_id uuid,
  is_internal boolean not null default false,
  importance text not null default 'normal' check (importance in ('normal','important')),
  pinned_until date,
  entered_in_error_at timestamptz,
  entered_in_error_by uuid references public.employees (id) on delete set null,
  entered_in_error_reason text,
  correction_parent_id uuid references public.journey_interactions (id) on delete set null,
  idempotency_key text,
  created_at timestamptz not null default now()
);

comment on table public.journey_interactions is 'Append-oriented record of customer/employee interactions. Never hard-deleted; corrected or marked entered-in-error.';

create index if not exists idx_journey_interactions_journey
  on public.journey_interactions (journey_id);
create index if not exists idx_journey_interactions_customer
  on public.journey_interactions (customer_id);
create index if not exists idx_journey_interactions_occurred
  on public.journey_interactions (occurred_at);
create unique index if not exists idx_journey_interactions_idempotency
  on public.journey_interactions (idempotency_key)
  where idempotency_key is not null;
create index if not exists idx_journey_interactions_source
  on public.journey_interactions (source_domain, source_record_id);

alter table public.journey_interactions enable row level security;

drop policy if exists "Journey interactions viewable by authenticated users" on public.journey_interactions;
create policy "Journey interactions viewable by authenticated users"
  on public.journey_interactions for select
  to authenticated
  using (public.is_journey_visible(journey_id));

-- Intentionally no INSERT, UPDATE, or DELETE policy: a direct insert
-- grant would let any authenticated user bypass record_journey_interaction
-- and forge created_by_employee_id, source_domain, or a mismatched
-- customer_id. All writes go through the security-definer RPCs below.

grant select on public.journey_interactions to authenticated;

-- ============================================================
-- 3. Follow-ups: widen type, add source links + method + idempotency
-- ============================================================

alter table public.follow_ups drop constraint if exists follow_ups_type_check;
alter table public.follow_ups
  add constraint follow_ups_type_check
  check (type in ('quote','deposit','interaction','sleep_concern'));

alter table public.follow_ups
  add column if not exists journey_interaction_id uuid
    references public.journey_interactions (id) on delete set null;

alter table public.follow_ups
  add column if not exists method text;

alter table public.follow_ups
  add column if not exists idempotency_key text;

create unique index if not exists idx_follow_ups_idempotency
  on public.follow_ups (idempotency_key)
  where idempotency_key is not null;

comment on column public.follow_ups.journey_interaction_id is 'The interaction this follow-up was created from, if any';
comment on column public.follow_ups.method is 'Planned contact method: call, text, email, in_person';

-- ============================================================
-- 4. RPC: record a journey interaction (+ optional follow-up in the
--    same transaction). Idempotent via p_idempotency_key so retries
--    cannot duplicate the interaction or the follow-up.
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

  -- Idempotent retry: return the previously created interaction.
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

  -- Channel/direction default from the interaction type when the
  -- caller does not specify them explicitly.
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
  returning id into v_interaction_id;

  -- Optional follow-up in the same transaction: either everything is
  -- recorded or nothing is, so there is no partial-failure window.
  if p_follow_up is not null and p_follow_up->>'due_at' is not null then
    v_fu_due := (p_follow_up->>'due_at')::timestamptz;
    v_fu_employee := coalesce(
      nullif(p_follow_up->>'employee_id', '')::uuid,
      v_employee_id
    );

    if p_follow_up->>'idempotency_key' is not null
       and exists (
         select 1 from public.follow_ups
         where idempotency_key = p_follow_up->>'idempotency_key'
       ) then
      return v_interaction_id;
    end if;

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
    );
  end if;

  return v_interaction_id;
end;
$$;

-- ============================================================
-- 5. RPC: mark an interaction entered-in-error. History is preserved;
--    the row is flagged rather than deleted. Author or manager+.
-- ============================================================

create or replace function public.mark_interaction_entered_in_error(
  p_interaction_id uuid,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_interaction public.journey_interactions%rowtype;
  v_employee_id uuid;
  v_is_privileged boolean;
begin
  select * into v_interaction
  from public.journey_interactions
  where id = p_interaction_id;

  if v_interaction.id is null then
    raise exception 'Interaction not found';
  end if;

  if not public.is_journey_visible(v_interaction.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select id into v_employee_id
  from public.employees
  where auth_user_id = auth.uid();

  select exists (
    select 1
    from public.employees e
    join public.stores es on es.id = e.home_store_id
    join public.sleep_journeys sj on sj.id = v_interaction.journey_id
    join public.stores js on js.id = sj.store_id
    where e.auth_user_id = auth.uid()
      and es.company_id = js.company_id
      and e.role::text in ('owner','admin','manager')
  ) into v_is_privileged;

  if v_employee_id is null
     or (v_interaction.created_by_employee_id is distinct from v_employee_id and not v_is_privileged) then
    raise exception 'Only the author or a manager may mark an interaction entered in error';
  end if;

  update public.journey_interactions
  set entered_in_error_at = now(),
      entered_in_error_by = v_employee_id,
      entered_in_error_reason = nullif(btrim(coalesce(p_reason, '')), '')
  where id = p_interaction_id
    and entered_in_error_at is null;

  return p_interaction_id;
end;
$$;

-- ============================================================
-- 6. RPC: pin / unpin an interaction (importance + optional expiry).
-- ============================================================

create or replace function public.set_interaction_importance(
  p_interaction_id uuid,
  p_important boolean,
  p_pinned_until date default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_journey_id uuid;
begin
  select journey_id into v_journey_id
  from public.journey_interactions
  where id = p_interaction_id;

  if v_journey_id is null then
    raise exception 'Interaction not found';
  end if;

  if not public.is_journey_visible(v_journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  update public.journey_interactions
  set importance = case when p_important then 'important' else 'normal' end,
      pinned_until = case when p_important then p_pinned_until else null end
  where id = p_interaction_id;

  return p_interaction_id;
end;
$$;
