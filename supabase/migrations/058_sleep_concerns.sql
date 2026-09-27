-- PillowTop POS: Sleep Concern workflow + early-exchange exception requests.
--
-- A Sleep Concern is a continuing episode of structured discomfort/adjustment
-- tracking during a Sleep Trial. It uses the Journey Interaction foundation
-- for its activity trail (every entry also writes a journey_interactions row
-- with source_domain='sleep_concern') rather than a parallel notes system.
--
-- Grain rules preserved for reporting: one concern with many issues, entries,
-- diagnostics, and follow-ups is still ONE concern row.

-- ============================================================
-- 1. Retailer-configurable concern types + diagnostic questions
--    Company-scoped, seeded with sensible defaults on first use.
-- ============================================================

create table if not exists public.sleep_concern_types (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  name text not null,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (company_id, name)
);

create table if not exists public.sleep_concern_questions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  concern_type_id uuid references public.sleep_concern_types (id) on delete cascade,
  question_text text not null,
  options jsonb,
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

comment on column public.sleep_concern_questions.concern_type_id is 'NULL = question applies to every concern type';
comment on column public.sleep_concern_questions.options is 'JSON array of choice labels; NULL = free-text answer';

alter table public.sleep_concern_types enable row level security;
alter table public.sleep_concern_questions enable row level security;

drop policy if exists "Concern types viewable by company" on public.sleep_concern_types;
create policy "Concern types viewable by company"
  on public.sleep_concern_types for select
  to authenticated
  using (public.is_own_company(company_id));

drop policy if exists "Concern types manageable by owner/admin" on public.sleep_concern_types;
create policy "Concern types manageable by owner/admin"
  on public.sleep_concern_types for all
  to authenticated
  using (
    public.current_employee_role()::text in ('owner','admin','manager')
    and public.is_own_company(company_id)
  )
  with check (
    public.current_employee_role()::text in ('owner','admin','manager')
    and public.is_own_company(company_id)
  );

drop policy if exists "Concern questions viewable by company" on public.sleep_concern_questions;
create policy "Concern questions viewable by company"
  on public.sleep_concern_questions for select
  to authenticated
  using (public.is_own_company(company_id));

drop policy if exists "Concern questions manageable by owner/admin" on public.sleep_concern_questions;
create policy "Concern questions manageable by owner/admin"
  on public.sleep_concern_questions for all
  to authenticated
  using (
    public.current_employee_role()::text in ('owner','admin','manager')
    and public.is_own_company(company_id)
  )
  with check (
    public.current_employee_role()::text in ('owner','admin','manager')
    and public.is_own_company(company_id)
  );

grant select, insert, update, delete on public.sleep_concern_types to authenticated;
grant select, insert, update, delete on public.sleep_concern_questions to authenticated;

-- Seed the default taxonomy + guided questions for the caller's
-- company if it has none. Idempotent; safe to call on every load.
create or replace function public.ensure_sleep_concern_defaults()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_too_firm uuid;
  v_pressure uuid;
  v_too_soft uuid;
  v_sleeping_hot uuid;
begin
  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid();

  if v_company_id is null then
    return;
  end if;

  if exists (select 1 from public.sleep_concern_types where company_id = v_company_id) then
    return;
  end if;

  insert into public.sleep_concern_types (company_id, name, sort_order) values
    (v_company_id, 'Too Firm', 1),
    (v_company_id, 'Too Soft', 2),
    (v_company_id, 'Pressure Points', 3),
    (v_company_id, 'Back Discomfort', 4),
    (v_company_id, 'Hip Discomfort', 5),
    (v_company_id, 'Shoulder Discomfort', 6),
    (v_company_id, 'Sleeping Hot', 7),
    (v_company_id, 'Motion Transfer', 8),
    (v_company_id, 'Partner Comfort Difference', 9),
    (v_company_id, 'Difficulty Adjusting', 10),
    (v_company_id, 'Edge Comfort', 11),
    (v_company_id, 'Mattress Height / Setup', 12),
    (v_company_id, 'Perceived Sagging / Body Impression', 13),
    (v_company_id, 'Other Comfort Concern', 14),
    (v_company_id, 'Possible Product Defect', 15);

  select id into v_too_firm from public.sleep_concern_types
    where company_id = v_company_id and name = 'Too Firm';
  select id into v_pressure from public.sleep_concern_types
    where company_id = v_company_id and name = 'Pressure Points';
  select id into v_too_soft from public.sleep_concern_types
    where company_id = v_company_id and name = 'Too Soft';
  select id into v_sleeping_hot from public.sleep_concern_types
    where company_id = v_company_id and name = 'Sleeping Hot';

  -- Too Firm / Pressure diagnostics (source doc §80)
  insert into public.sleep_concern_questions (company_id, concern_type_id, question_text, options, sort_order) values
    (v_company_id, v_too_firm, 'Where are you feeling pressure?', '["Shoulders","Hips","Lower Back","Other"]', 1),
    (v_company_id, v_pressure, 'Where are you feeling pressure?', '["Shoulders","Hips","Lower Back","Other"]', 1),
    (v_company_id, v_too_firm, 'What sleep position do you use most?', '["Side","Back","Stomach","Combination"]', 2),
    (v_company_id, v_pressure, 'What sleep position do you use most?', '["Side","Back","Stomach","Combination"]', 2),
    (v_company_id, v_too_firm, 'Has the mattress softened since the first week?', '["Yes","No","Unsure"]', 3),
    (v_company_id, v_pressure, 'Has the mattress softened since the first week?', '["Yes","No","Unsure"]', 3),
    (v_company_id, v_too_firm, 'Is discomfort strongest:', '["Falling asleep","During the night","Upon waking","Multiple"]', 4),
    (v_company_id, v_pressure, 'Is discomfort strongest:', '["Falling asleep","During the night","Upon waking","Multiple"]', 4);

  -- Too Soft diagnostics
  insert into public.sleep_concern_questions (company_id, concern_type_id, question_text, options, sort_order) values
    (v_company_id, v_too_soft, 'Do you feel you are sinking too deeply?', '["Yes","No","Unsure"]', 1),
    (v_company_id, v_too_soft, 'Do you feel unsupported through the lower back?', '["Yes","No","Unsure"]', 2),
    (v_company_id, v_too_soft, 'Is it difficult to get out of bed?', '["Yes","No","Unsure"]', 3),
    (v_company_id, v_too_soft, 'Was the sensation there from the first night, or did it develop later?', '["First night","Developed later","Unsure"]', 4);

  -- Sleeping Hot diagnostics
  insert into public.sleep_concern_questions (company_id, concern_type_id, question_text, options, sort_order) values
    (v_company_id, v_sleeping_hot, 'Is the heat mainly underneath the sleeper or throughout the room?', '["Underneath sleeper","Throughout room","Both"]', 1),
    (v_company_id, v_sleeping_hot, 'What sheets and protector are being used?', null, 2),
    (v_company_id, v_sleeping_hot, 'Was temperature an issue on the prior mattress?', '["Yes","No","Unsure"]', 3);
end;
$$;

-- ============================================================
-- 2. Sleep Concern core tables
-- ============================================================

create table if not exists public.sleep_concerns (
  id uuid primary key default gen_random_uuid(),
  journey_id uuid not null references public.sleep_journeys (id) on delete cascade,
  customer_id uuid not null references public.customers (id) on delete restrict,
  status text not null default 'open' check (status in (
    'open','monitoring','resolved','escalated','exchange_requested'
  )),
  opened_by_employee_id uuid references public.employees (id) on delete set null,
  opened_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by_employee_id uuid references public.employees (id) on delete set null,
  resolution_type text,
  resolution_summary text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.sleep_concerns is 'Structured comfort-concern episode during a Sleep Trial. exchange_requested records that the customer wants an exchange; a real Exchange system does not exist yet.';

create index if not exists idx_sleep_concerns_journey on public.sleep_concerns (journey_id);
create index if not exists idx_sleep_concerns_status on public.sleep_concerns (status);

create table if not exists public.sleep_concern_issues (
  id uuid primary key default gen_random_uuid(),
  sleep_concern_id uuid not null references public.sleep_concerns (id) on delete cascade,
  concern_type_id uuid references public.sleep_concern_types (id) on delete set null,
  issue_name text not null,
  added_by_employee_id uuid references public.employees (id) on delete set null,
  created_at timestamptz not null default now()
);

comment on column public.sleep_concern_issues.issue_name is 'Snapshot of the type name so config changes do not rewrite history';

create index if not exists idx_sleep_concern_issues_concern on public.sleep_concern_issues (sleep_concern_id);

create table if not exists public.sleep_concern_entries (
  id uuid primary key default gen_random_uuid(),
  sleep_concern_id uuid not null references public.sleep_concerns (id) on delete cascade,
  journey_interaction_id uuid references public.journey_interactions (id) on delete set null,
  entry_type text not null default 'update' check (entry_type in (
    'update','customer_report','recommendation','status_change'
  )),
  customer_report text,
  employee_notes text,
  recommendation_summary text,
  created_by_employee_id uuid references public.employees (id) on delete set null,
  occurred_at timestamptz not null default now(),
  recorded_at timestamptz not null default now(),
  idempotency_key text,
  created_at timestamptz not null default now()
);

create index if not exists idx_sleep_concern_entries_concern on public.sleep_concern_entries (sleep_concern_id);
create unique index if not exists idx_sleep_concern_entries_idempotency
  on public.sleep_concern_entries (idempotency_key)
  where idempotency_key is not null;

create table if not exists public.sleep_concern_diagnostic_responses (
  id uuid primary key default gen_random_uuid(),
  sleep_concern_id uuid not null references public.sleep_concerns (id) on delete cascade,
  entry_id uuid references public.sleep_concern_entries (id) on delete cascade,
  question_id uuid references public.sleep_concern_questions (id) on delete set null,
  question_snapshot jsonb not null,
  response text not null,
  recorded_by uuid references public.employees (id) on delete set null,
  created_at timestamptz not null default now()
);

comment on column public.sleep_concern_diagnostic_responses.question_snapshot is '{text, options, concern_type_name} captured at answer time so later question edits keep history readable (source doc §82)';

create index if not exists idx_sleep_concern_diagnostics_concern on public.sleep_concern_diagnostic_responses (sleep_concern_id);

-- follow_ups linkage to a concern
alter table public.follow_ups
  add column if not exists sleep_concern_id uuid
    references public.sleep_concerns (id) on delete set null;

create index if not exists idx_follow_ups_concern on public.follow_ups (sleep_concern_id);

-- RLS
alter table public.sleep_concerns enable row level security;
alter table public.sleep_concern_issues enable row level security;
alter table public.sleep_concern_entries enable row level security;
alter table public.sleep_concern_diagnostic_responses enable row level security;

drop policy if exists "Sleep concerns viewable by authenticated users" on public.sleep_concerns;
create policy "Sleep concerns viewable by authenticated users"
  on public.sleep_concerns for select
  to authenticated
  using (public.is_journey_visible(journey_id));

drop policy if exists "Concern issues viewable by authenticated users" on public.sleep_concern_issues;
create policy "Concern issues viewable by authenticated users"
  on public.sleep_concern_issues for select
  to authenticated
  using (exists (
    select 1 from public.sleep_concerns sc
    where sc.id = sleep_concern_issues.sleep_concern_id
      and public.is_journey_visible(sc.journey_id)
  ));

drop policy if exists "Concern entries viewable by authenticated users" on public.sleep_concern_entries;
create policy "Concern entries viewable by authenticated users"
  on public.sleep_concern_entries for select
  to authenticated
  using (exists (
    select 1 from public.sleep_concerns sc
    where sc.id = sleep_concern_entries.sleep_concern_id
      and public.is_journey_visible(sc.journey_id)
  ));

drop policy if exists "Concern diagnostics viewable by authenticated users" on public.sleep_concern_diagnostic_responses;
create policy "Concern diagnostics viewable by authenticated users"
  on public.sleep_concern_diagnostic_responses for select
  to authenticated
  using (exists (
    select 1 from public.sleep_concerns sc
    where sc.id = sleep_concern_diagnostic_responses.sleep_concern_id
      and public.is_journey_visible(sc.journey_id)
  ));

-- Writes go through security-definer RPCs so duplicate prevention,
-- interaction-feed linkage, and status transitions stay centralized.
grant select on public.sleep_concerns to authenticated;
grant select on public.sleep_concern_issues to authenticated;
grant select on public.sleep_concern_entries to authenticated;
grant select on public.sleep_concern_diagnostic_responses to authenticated;

-- ============================================================
-- 3. Internal helper: append one concern entry + its feed interaction
--    (+ optional diagnostic rows). Shared by open/add/status RPCs.
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
-- 4. RPC: open a sleep concern
--    p_issues:       [{concern_type_id, name}]
--    p_diagnostics:  [{question_id, question_snapshot, response}]
--    p_follow_up:    {due_at, method, notes, employee_id, idempotency_key}
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

  -- Idempotent retry: the first entry carries the idempotency key, so
  -- an existing key means the concern was already created.
  if p_idempotency_key is not null then
    select e.sleep_concern_id into v_existing
    from public.sleep_concern_entries e
    join public.sleep_concerns sc on sc.id = e.sleep_concern_id
    where e.idempotency_key = p_idempotency_key
      and sc.journey_id = p_journey_id
    limit 1;
    if v_existing is not null then
      return v_existing;
    end if;
  end if;

  -- Duplicate-episode prevention (source doc §92): an open episode
  -- blocks a new one unless the caller explicitly allows it.
  if not p_allow_duplicate then
    select id into v_existing
    from public.sleep_concerns
    where journey_id = p_journey_id
      and status in ('open','monitoring','escalated')
    limit 1;
    if v_existing is not null then
      raise exception 'existing_open_concern:%', v_existing;
    end if;
  end if;

  insert into public.sleep_concerns (
    journey_id, customer_id, opened_by_employee_id
  ) values (
    p_journey_id, v_journey.customer_id, v_employee_id
  )
  returning id into v_concern_id;

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
    );
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
    if v_fu->>'idempotency_key' is null
       or not exists (
         select 1 from public.follow_ups
         where idempotency_key = v_fu->>'idempotency_key'
       ) then
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
      );
    end if;
  end if;

  return v_concern_id;
end;
$$;

-- ============================================================
-- 5. RPC: add an update to an existing concern
--    Optionally adds new issues, diagnostics, a status change, and a
--    follow-up — all in one transaction.
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
  v_status_changed boolean := false;
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
      )
      select p_concern_id,
             nullif(v_issue->>'concern_type_id','')::uuid,
             coalesce(nullif(btrim(v_issue->>'name'), ''), 'Other'),
             v_employee_id
      where not exists (
        select 1 from public.sleep_concern_issues i
        where i.sleep_concern_id = p_concern_id
          and i.issue_name = coalesce(nullif(btrim(v_issue->>'name'), ''), 'Other')
      );
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
    v_status_changed := true;
  end if;

  if p_follow_up is not null and p_follow_up->>'due_at' is not null then
    if p_follow_up->>'idempotency_key' is null
       or not exists (
         select 1 from public.follow_ups
         where idempotency_key = p_follow_up->>'idempotency_key'
       ) then
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
      );
    end if;
  end if;

  return v_entry_id;
end;
$$;

-- ============================================================
-- 6. RPC: mark a concern exchange_requested.
--    Allowed only when the journey is exchange-eligible OR an early
--    exception was approved. Records intent; no Exchange system exists.
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
  if v_concern.status in ('resolved','exchange_requested') then
    raise exception 'Concern is already %', v_concern.status;
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

  update public.sleep_concerns
  set status = 'exchange_requested', updated_at = now()
  where id = p_concern_id;

  perform public.append_sleep_concern_entry(
    p_concern_id, v_concern.journey_id, v_concern.customer_id, v_employee_id,
    'status_change',
    'Customer wants an exchange — exchange requested.',
    null, null, null, null, null, null, null, 'internal'
  );

  return p_concern_id;
end;
$$;

-- ============================================================
-- 7. Early exchange exception requests
--    Modeled directly on deposit_approval_requests: requester,
--    approver, status, expiry. Records the approval decision only —
--    it does not initiate a real exchange (none exists).
-- ============================================================

create table if not exists public.sleep_trial_exception_requests (
  id uuid primary key default gen_random_uuid(),
  journey_id uuid not null references public.sleep_journeys (id) on delete cascade,
  sleep_concern_id uuid references public.sleep_concerns (id) on delete set null,
  requester_employee_id uuid not null references public.employees (id) on delete restrict,
  approver_employee_id uuid references public.employees (id) on delete set null,
  reason text not null,
  requested_action text not null default 'early_exchange',
  current_trial_night integer,
  normal_eligibility_date date,
  status text not null default 'pending' check (status in (
    'pending','approved','denied','expired','cancelled'
  )),
  requested_at timestamptz not null default now(),
  decided_at timestamptz,
  expires_at timestamptz
);

create index if not exists idx_sleep_trial_exceptions_journey
  on public.sleep_trial_exception_requests (journey_id);
create index if not exists idx_sleep_trial_exceptions_status
  on public.sleep_trial_exception_requests (status);

alter table public.sleep_trial_exception_requests enable row level security;

drop policy if exists "Sleep trial exceptions viewable by authenticated users" on public.sleep_trial_exception_requests;
create policy "Sleep trial exceptions viewable by authenticated users"
  on public.sleep_trial_exception_requests for select
  to authenticated
  using (public.is_journey_visible(journey_id));

-- Decisions happen inside security-definer RPCs only.
grant select on public.sleep_trial_exception_requests to authenticated;

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

create or replace function public.decide_sleep_trial_exception(
  p_request_id uuid,
  p_decision text
)
returns uuid
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

  if v_request.status <> 'pending' then
    raise exception 'Only pending requests may be decided';
  end if;

  -- Auto-expire once normal eligibility has arrived.
  if v_request.expires_at is not null and v_request.expires_at <= now() then
    update public.sleep_trial_exception_requests
    set status = 'expired'
    where id = p_request_id;
    raise exception 'This request has expired — the trial reached normal eligibility';
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

  update public.sleep_trial_exception_requests
  set status = p_decision,
      approver_employee_id = v_approver,
      decided_at = now()
  where id = p_request_id;

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

  return p_request_id;
end;
$$;
