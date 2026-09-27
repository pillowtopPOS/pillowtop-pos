-- 067_sleep_trial_policy.sql
--
-- Sleep Trial Engine, phase ST-2 (docs/sleep-trial-engine.md Sections 5, 6.5,
-- 7.1, 26.2, 31, 33): the versioned policy model plus draft/publish commands.
-- Nothing reads the policy yet — binding and the evaluator arrive in ST-3/ST-4,
-- so existing trials keep using store/journey columns.
--
-- Write lockdown (062/065/066 pattern): no direct writes for authenticated.
-- All changes go through save/discard/publish RPCs, which require
-- has_permission('sleep_trial.manage_policy') and audit every real change.

-- ---------------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------------

create table if not exists public.policies (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  policy_type text not null,           -- 'SLEEP_TRIAL' (only type implemented)
  name text not null,
  current_version_id uuid,             -- FK added after policy_versions exists
  created_at timestamptz not null default now(),
  created_by uuid references public.employees (id)
);

-- One policy per type per company (spec 26.2: unique for SLEEP_TRIAL).
create unique index if not exists policies_company_type_key
  on public.policies (company_id, policy_type);

create table if not exists public.policy_versions (
  id uuid primary key default gen_random_uuid(),
  policy_id uuid not null references public.policies (id) on delete cascade,
  company_id uuid not null references public.companies (id) on delete cascade,
  version_number integer not null,
  status text not null check (status in ('DRAFT', 'PUBLISHED', 'RETIRED')),
  definition jsonb not null,
  definition_schema_version integer not null default 1,
  summary_text text,
  effective_from timestamptz,
  effective_until timestamptz,
  created_at timestamptz not null default now(),
  created_by uuid references public.employees (id),
  published_at timestamptz,
  published_by uuid references public.employees (id),
  publish_note text,
  unique (policy_id, version_number)
);

-- Deferred FK: policies.current_version_id -> policy_versions.id
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'policies_current_version_fk'
  ) then
    alter table public.policies
      add constraint policies_current_version_fk
      foreign key (current_version_id) references public.policy_versions (id);
  end if;
end $$;

-- At most one DRAFT and one PUBLISHED version per policy (canonical 17.68).
create unique index if not exists policy_versions_one_draft
  on public.policy_versions (policy_id) where status = 'DRAFT';
create unique index if not exists policy_versions_one_published
  on public.policy_versions (policy_id) where status = 'PUBLISHED';

create index if not exists idx_policy_versions_policy
  on public.policy_versions (policy_id, status);

-- ---------------------------------------------------------------------------
-- 2. Immutability + RLS
-- ---------------------------------------------------------------------------

-- Once a version leaves DRAFT, its definition, schema version, and activation
-- timestamp are frozen forever. effective_until is set when the next version
-- publishes, so it is intentionally not guarded. Direct deletes of anything
-- but a DRAFT are rejected — published history is never erased — but deletes
-- cascaded from a parent (companies/policies row removal) fire at trigger
-- depth > 1 and are allowed through.
create or replace function public.policy_versions_guard()
returns trigger
language plpgsql
as $$
begin
  if TG_OP = 'DELETE' then
    if old.status <> 'DRAFT' and pg_trigger_depth() <= 1 then
      raise exception 'Only draft policy versions can be deleted';
    end if;
    return old;
  end if;

  if old.status <> 'DRAFT' and (
    new.definition is distinct from old.definition
    or new.definition_schema_version is distinct from old.definition_schema_version
    or new.effective_from is distinct from old.effective_from
  ) then
    raise exception 'Published policy versions are immutable';
  end if;
  return new;
end;
$$;

drop trigger if exists policy_versions_guard on public.policy_versions;
create trigger policy_versions_guard
  before update or delete on public.policy_versions
  for each row execute function public.policy_versions_guard();

alter table public.policies enable row level security;
alter table public.policy_versions enable row level security;

drop policy if exists "Policies viewable in own company" on public.policies;
create policy "Policies viewable in own company"
  on public.policies for select
  to authenticated
  using (company_id = public.current_employee_company_id());

drop policy if exists "Policy versions viewable in own company" on public.policy_versions;
create policy "Policy versions viewable in own company"
  on public.policy_versions for select
  to authenticated
  using (company_id = public.current_employee_company_id());

grant select on public.policies, public.policy_versions to authenticated;
revoke insert, update, delete, truncate on public.policies, public.policy_versions
  from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Validation helpers (pure functions over the definition jsonb)
-- ---------------------------------------------------------------------------

-- Each helper takes the accumulated errors array and returns it unchanged or
-- with one {path, message} appended, so checks chain as one-liners.

create or replace function public.stv_err(p_errors jsonb, p_path text, p_message text)
returns jsonb
language sql
immutable
as $$
  select p_errors || jsonb_build_array(
    jsonb_build_object('path', p_path, 'message', p_message));
$$;

-- Safe jsonb number → int: returns null for non-numbers, fractions, and
-- out-of-range values instead of raising. The validator must report bad
-- input, never throw.
create or replace function public.stv_to_int(p_value jsonb)
returns int
language plpgsql
immutable
as $$
declare
  v_num numeric;
begin
  if p_value is null or jsonb_typeof(p_value) <> 'number' then
    return null;
  end if;
  v_num := (p_value #>> '{}')::numeric;
  if v_num <> trunc(v_num) or v_num < -2147483648 or v_num > 2147483647 then
    return null;
  end if;
  return v_num::int;
end;
$$;

create or replace function public.stv_int(
  p_errors jsonb, p_value jsonb, p_path text,
  p_min int, p_max int, p_required boolean default true
)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_num numeric;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    if p_required then
      return public.stv_err(p_errors, p_path, 'is required');
    end if;
    return p_errors;
  end if;
  if jsonb_typeof(p_value) <> 'number' then
    return public.stv_err(p_errors, p_path, 'must be a whole number');
  end if;
  v_num := (p_value #>> '{}')::numeric;
  if v_num <> trunc(v_num) then
    return public.stv_err(p_errors, p_path, 'must be a whole number');
  end if;
  if v_num < p_min or v_num > p_max then
    return public.stv_err(p_errors, p_path, 'must be between ' || p_min || ' and ' || p_max);
  end if;
  return p_errors;
end;
$$;

create or replace function public.stv_bool(p_errors jsonb, p_value jsonb, p_path text)
returns jsonb
language plpgsql
immutable
as $$
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return public.stv_err(p_errors, p_path, 'is required');
  end if;
  if jsonb_typeof(p_value) <> 'boolean' then
    return public.stv_err(p_errors, p_path, 'must be true or false');
  end if;
  return p_errors;
end;
$$;

create or replace function public.stv_enum(
  p_errors jsonb, p_value jsonb, p_path text, p_allowed text[]
)
returns jsonb
language plpgsql
immutable
as $$
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return public.stv_err(p_errors, p_path, 'is required');
  end if;
  if jsonb_typeof(p_value) <> 'string' or not (p_value #>> '{}' = any (p_allowed)) then
    return public.stv_err(
      p_errors, p_path,
      'must be one of: ' || array_to_string(p_allowed, ', '));
  end if;
  return p_errors;
end;
$$;

create or replace function public.stv_text(
  p_errors jsonb, p_value jsonb, p_path text, p_max_len int default null
)
returns jsonb
language plpgsql
immutable
as $$
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return p_errors; -- text fields are optional
  end if;
  if jsonb_typeof(p_value) <> 'string' then
    return public.stv_err(p_errors, p_path, 'must be text');
  end if;
  if p_max_len is not null and char_length(p_value #>> '{}') > p_max_len then
    return public.stv_err(p_errors, p_path, 'must be ' || p_max_len || ' characters or fewer');
  end if;
  return p_errors;
end;
$$;

-- exchange.replacement_trial: ordered list {n, rule, nights?}, FIXED needs
-- nights. Used by both the base section and overrides.
create or replace function public.stv_replacement_trial(
  p_errors jsonb, p_value jsonb, p_path text, p_max_count int
)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_entry jsonb;
  v_i int;
  v_rule text;
  v_nights numeric;
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return public.stv_err(p_errors, p_path, 'is required');
  end if;
  if jsonb_typeof(p_value) <> 'array' then
    return public.stv_err(p_errors, p_path, 'must be a list of rules');
  end if;
  if jsonb_array_length(p_value) > p_max_count then
    p_errors := public.stv_err(
      p_errors, p_path,
      'has more entries than the ' || p_max_count || ' exchange(s) allowed');
  end if;
  for v_i in 0 .. jsonb_array_length(p_value) - 1 loop
    v_entry := p_value -> v_i;
    p_errors := public.stv_int(
      p_errors, v_entry -> 'n', p_path || '[' || v_i || '].n', 1, greatest(p_max_count, 1));
    v_rule := v_entry ->> 'rule';
    if v_rule not in ('FULL_NEW', 'REMAINING', 'FIXED', 'NONE') then
      p_errors := public.stv_err(
        p_errors, p_path || '[' || v_i || '].rule',
        'must be one of: FULL_NEW, REMAINING, FIXED, NONE');
    elsif v_rule = 'FIXED' then
      p_errors := public.stv_int(
        p_errors, v_entry -> 'nights', p_path || '[' || v_i || '].nights', 1, 730);
    end if;
  end loop;
  return p_errors;
end;
$$;

-- exchange.replacement_minimum / return.minimum_nights share the
-- "named rule or fixed nights" shape.
create or replace function public.stv_minimum_rule(
  p_errors jsonb, p_value jsonb, p_path text,
  p_same_as_label text, p_length int
)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_rule jsonb;
  v_kind text;
begin
  -- return.minimum_nights is a bare value: 'SAME_AS_EXCHANGE' or an integer.
  if jsonb_typeof(p_value) = 'string' then
    if p_value #>> '{}' = p_same_as_label then
      return p_errors;
    end if;
    return public.stv_err(p_errors, p_path, 'must be ' || p_same_as_label || ' or a whole number');
  end if;
  if jsonb_typeof(p_value) = 'number' then
    return public.stv_int(p_errors, p_value, p_path, 0, greatest(p_length - 1, 0));
  end if;
  -- exchange.replacement_minimum is an object: {rule, nights?}.
  if jsonb_typeof(p_value) <> 'object' then
    return public.stv_err(p_errors, p_path, 'is required');
  end if;
  v_kind := p_value ->> 'rule';
  if v_kind not in (p_same_as_label, 'NONE', 'FIXED') then
    return public.stv_err(
      p_errors, p_path || '.rule',
      'must be one of: ' || p_same_as_label || ', NONE, FIXED');
  end if;
  if v_kind = 'FIXED' then
    p_errors := public.stv_int(
      p_errors, p_value -> 'nights', p_path || '.nights', 0, greatest(p_length - 1, 0));
  end if;
  return p_errors;
end;
$$;

-- Fee schedule validation shared by every named schedule. Accumulates both
-- errors and warnings; returns {"errors": [...], "warnings": [...]}.
create or replace function public.stv_fee_schedule(
  p_acc jsonb, p_sched jsonb, p_path text, p_min_nights int
)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_errors jsonb := coalesce(p_acc -> 'errors', '[]'::jsonb);
  v_warnings jsonb := coalesce(p_acc -> 'warnings', '[]'::jsonb);
  v_windows jsonb;
  v_w jsonb;
  v_wpath text;
  v_i int;
  v_count int;
  v_prev_to int := 0;
  v_from int;
  v_to int;
  v_open_count int := 0;
  v_outcome text;
  v_pct numeric;
  v_flat numeric;
  v_min_c numeric;
  v_max_c numeric;
begin
  if p_sched is null or jsonb_typeof(p_sched) <> 'object' then
    v_errors := public.stv_err(v_errors, p_path, 'schedule must be an object');
    return jsonb_build_object('errors', v_errors, 'warnings', v_warnings);
  end if;

  v_windows := p_sched -> 'windows';
  if v_windows is null or jsonb_typeof(v_windows) <> 'array'
     or jsonb_array_length(v_windows) = 0 then
    v_errors := public.stv_err(v_errors, p_path || '.windows', 'must be a non-empty list');
    return jsonb_build_object('errors', v_errors, 'warnings', v_warnings);
  end if;

  v_count := jsonb_array_length(v_windows);
  for v_i in 0 .. v_count - 1 loop
    v_w := v_windows -> v_i;
    v_wpath := p_path || '.windows[' || v_i || ']';

    v_from := public.stv_to_int(v_w -> 'from_night');
    v_outcome := v_w ->> 'outcome';
    if v_from is null
       or jsonb_typeof(coalesce(v_w -> 'outcome', 'null'::jsonb)) <> 'string' then
      v_errors := public.stv_err(v_errors, v_wpath, 'window needs a whole-number from_night and an outcome');
      continue;
    end if;

    -- Defensive casts: the validator must report bad types, not throw.
    if v_w -> 'to_night' is null or jsonb_typeof(v_w -> 'to_night') = 'null' then
      v_to := null;
    elsif jsonb_typeof(v_w -> 'to_night') = 'number' then
      v_to := public.stv_to_int(v_w -> 'to_night');
      if v_to is null then
        v_errors := public.stv_err(v_errors, v_wpath || '.to_night', 'must be a whole number or null');
        v_to := v_from;
      end if;
    else
      v_errors := public.stv_err(v_errors, v_wpath || '.to_night', 'must be a number or null');
      v_to := v_from;
    end if;

    v_pct := case
      when v_w -> 'percent_bp' is null or jsonb_typeof(v_w -> 'percent_bp') = 'null' then 0
      when jsonb_typeof(v_w -> 'percent_bp') = 'number' then (v_w ->> 'percent_bp')::numeric
      else -1 end;
    v_flat := case
      when v_w -> 'flat_cents' is null or jsonb_typeof(v_w -> 'flat_cents') = 'null' then 0
      when jsonb_typeof(v_w -> 'flat_cents') = 'number' then (v_w ->> 'flat_cents')::numeric
      else -1 end;
    v_min_c := case
      when v_w -> 'min_cents' is null or jsonb_typeof(v_w -> 'min_cents') = 'null' then null
      when jsonb_typeof(v_w -> 'min_cents') = 'number' then (v_w ->> 'min_cents')::numeric
      else -1 end;
    v_max_c := case
      when v_w -> 'max_cents' is null or jsonb_typeof(v_w -> 'max_cents') = 'null' then null
      when jsonb_typeof(v_w -> 'max_cents') = 'number' then (v_w ->> 'max_cents')::numeric
      else -1 end;

    if v_from <> v_prev_to + 1 then
      v_errors := public.stv_err(
        v_errors, v_wpath || '.from_night',
        'windows must be contiguous (expected ' || (v_prev_to + 1) || ')');
    end if;
    if v_from < 1 then
      v_errors := public.stv_err(v_errors, v_wpath || '.from_night', 'must be at least 1');
    end if;
    if v_to is not null and v_to < v_from then
      v_errors := public.stv_err(v_errors, v_wpath || '.to_night', 'cannot be before from_night');
    end if;
    if v_to is null then
      v_open_count := v_open_count + 1;
      if v_i <> v_count - 1 then
        v_errors := public.stv_err(v_errors, v_wpath || '.to_night', 'only the last window can be open-ended');
      end if;
    else
      v_prev_to := v_to;
    end if;

    if v_outcome not in ('ALLOWED', 'APPROVAL_REQUIRED', 'PROHIBITED') then
      v_errors := public.stv_err(
        v_errors, v_wpath || '.outcome',
        'must be one of: ALLOWED, APPROVAL_REQUIRED, PROHIBITED');
    end if;
    if v_pct = -1 then
      v_errors := public.stv_err(v_errors, v_wpath || '.percent_bp', 'must be a number');
    elsif v_pct < 0 or v_pct > 10000 then
      v_errors := public.stv_err(v_errors, v_wpath || '.percent_bp', 'must be between 0 and 10000');
    end if;
    if v_flat = -1 then
      v_errors := public.stv_err(v_errors, v_wpath || '.flat_cents', 'must be a number');
    elsif v_flat < 0 then
      v_errors := public.stv_err(v_errors, v_wpath || '.flat_cents', 'cannot be negative');
    elsif v_flat > 500000 then
      v_errors := public.stv_err(v_errors, v_wpath || '.flat_cents', 'cannot exceed $5,000');
    end if;
    if v_min_c = -1 then
      v_errors := public.stv_err(v_errors, v_wpath || '.min_cents', 'must be a number');
    elsif v_min_c is not null and v_min_c < 0 then
      v_errors := public.stv_err(v_errors, v_wpath || '.min_cents', 'cannot be negative');
    end if;
    if v_max_c = -1 then
      v_errors := public.stv_err(v_errors, v_wpath || '.max_cents', 'must be a number');
    elsif v_max_c is not null and v_max_c < 0 then
      v_errors := public.stv_err(v_errors, v_wpath || '.max_cents', 'cannot be negative');
    end if;
    if v_min_c is not null and v_max_c is not null and v_min_c > v_max_c then
      v_errors := public.stv_err(v_errors, v_wpath, 'min_cents cannot exceed max_cents');
    end if;

    -- Warnings (never block publish)
    if v_outcome = 'APPROVAL_REQUIRED' and v_pct = 0 and v_flat = 0 then
      v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
        'path', v_wpath,
        'message', 'Window requires approval but charges no fee'));
    end if;
    if p_min_nights > 0 and v_from <= p_min_nights then
      v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
        'path', v_wpath,
        'message', 'Nights ' || v_from || ' to ' || coalesce(v_to::text, 'end')
          || ' overlap the ' || p_min_nights || '-night minimum'));
    end if;
  end loop;

  if v_open_count <> 1 then
    v_errors := public.stv_err(v_errors, p_path || '.windows', 'exactly one open-ended window is required, and it must be last');
  end if;

  return jsonb_build_object('errors', v_errors, 'warnings', v_warnings);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. validate_sleep_trial_definition
-- ---------------------------------------------------------------------------

-- Validates the full schema_version 1 shape (Section 26.2) against the field
-- rules of Section 5.3, the override rules of Section 6.5, the fee window
-- rules of Section 13.1, and the blockers/warnings split of Section 31.
-- Pure: reads only the supplied jsonb, so the same result is guaranteed in a
-- draft save, a publish, or a hypothetical test (ST-7).
create or replace function public.validate_sleep_trial_definition(p_definition jsonb)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_errors jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_acc jsonb;
  v_base jsonb;
  v_trial jsonb;
  v_exchange jsonb;
  v_return jsonb;
  v_fees jsonb;
  v_protector jsonb;
  v_split jsonb;
  v_inspection jsonb;
  v_exceptions jsonb;
  v_comm jsonb;
  v_schedules jsonb;
  v_overrides jsonb;
  v_sched_key text;
  v_length int;
  v_min int;
  v_max_count int;
  v_night jsonb;
  v_override jsonb;
  v_scope jsonb;
  v_scope_type text;
  v_scope_value text;
  v_set jsonb;
  v_set_key text;
  v_seen text[] := '{}';
  v_whitelist constant text[] := array[
    'trial.enabled', 'trial.length_nights', 'trial.minimum_nights',
    'trial.extensions_allowed', 'trial.max_extension_nights',
    'exchange.allowed', 'exchange.max_count', 'exchange.replacement_trial',
    'exchange.replacement_minimum', 'exchange.early_exception_allowed',
    'exchange.expired_exception_allowed', 'return.allowed',
    'return.approval_required', 'return.exception_allowed',
    'return.minimum_nights', 'fees.exchange_schedule', 'fees.return_schedule',
    'protector.required'
  ];
begin
  if p_definition is null or jsonb_typeof(p_definition) <> 'object' then
    return jsonb_build_object(
      'errors', jsonb_build_array(jsonb_build_object(
        'path', '', 'message', 'Definition must be an object')),
      'warnings', '[]'::jsonb);
  end if;

  if coalesce(p_definition ->> 'schema_version', '') <> '1' then
    v_errors := public.stv_err(v_errors, 'schema_version', 'must be 1');
  end if;

  v_base := p_definition -> 'base';
  if v_base is null or jsonb_typeof(v_base) <> 'object' then
    return jsonb_build_object(
      'errors', v_errors || jsonb_build_array(jsonb_build_object(
        'path', 'base', 'message', 'is required')),
      'warnings', v_warnings);
  end if;

  v_trial := v_base -> 'trial';
  v_exchange := v_base -> 'exchange';
  v_return := v_base -> 'return';
  v_fees := v_base -> 'fees';
  v_protector := v_base -> 'protector';
  v_split := v_base -> 'split_king';
  v_inspection := v_base -> 'inspection';
  v_exceptions := v_base -> 'exceptions';
  v_comm := v_base -> 'communication';
  v_schedules := p_definition -> 'fee_schedules';
  v_overrides := p_definition -> 'overrides';

  -- Section 2: Trial Terms ---------------------------------------------------
  v_errors := public.stv_bool(v_errors, v_trial -> 'enabled', 'base.trial.enabled');
  v_errors := public.stv_int(v_errors, v_trial -> 'length_nights', 'base.trial.length_nights', 1, 730);
  v_length := public.stv_to_int(v_trial -> 'length_nights');

  v_errors := public.stv_int(v_errors, v_trial -> 'minimum_nights', 'base.trial.minimum_nights', 0, 730);
  v_min := public.stv_to_int(v_trial -> 'minimum_nights');
  if v_length is not null and v_min is not null and v_min >= v_length then
    v_errors := public.stv_err(
      v_errors, 'base.trial.minimum_nights',
      'must be less than the trial length');
  end if;

  -- start_event: only FULFILLMENT_COMPLETED exists today; SALE_DATE is reserved.
  v_errors := public.stv_enum(
    v_errors, v_trial -> 'start_event', 'base.trial.start_event',
    array['FULFILLMENT_COMPLETED']);
  v_errors := public.stv_enum(
    v_errors, v_trial -> 'count_starts', 'base.trial.count_starts',
    array['DAY_AFTER_FULFILLMENT', 'FULFILLMENT_DATE']);
  v_errors := public.stv_int(v_errors, v_trial -> 'ending_soon_days', 'base.trial.ending_soon_days', 0, 60);
  v_errors := public.stv_bool(v_errors, v_trial -> 'extensions_allowed', 'base.trial.extensions_allowed');
  v_errors := public.stv_int(v_errors, v_trial -> 'max_extension_nights', 'base.trial.max_extension_nights', 1, 365);
  v_errors := public.stv_bool(v_errors, v_trial -> 'eligibility_reached_task', 'base.trial.eligibility_reached_task');
  v_errors := public.stv_bool(v_errors, v_trial -> 'ending_soon_task', 'base.trial.ending_soon_task');

  if v_trial -> 'checkin_nights' is not null then
    if jsonb_typeof(v_trial -> 'checkin_nights') <> 'array' then
      v_errors := public.stv_err(v_errors, 'base.trial.checkin_nights', 'must be a list of night numbers');
    else
      for v_night in select value from jsonb_array_elements(v_trial -> 'checkin_nights') loop
        if jsonb_typeof(v_night) <> 'number' then
          v_errors := public.stv_err(v_errors, 'base.trial.checkin_nights', 'every entry must be a whole number');
        else
          if (v_night #>> '{}')::numeric < 1 then
            v_errors := public.stv_err(v_errors, 'base.trial.checkin_nights', 'nights must be at least 1');
          elsif v_length is not null and (v_night #>> '{}')::numeric > v_length then
            v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
              'path', 'base.trial.checkin_nights',
              'message', 'Check-in night ' || (v_night #>> '{}') || ' is beyond the ' || v_length || '-night trial'));
          end if;
        end if;
      end loop;
    end if;
  end if;

  -- Section 3: Exchanges -----------------------------------------------------
  v_errors := public.stv_bool(v_errors, v_exchange -> 'allowed', 'base.exchange.allowed');
  v_errors := public.stv_int(v_errors, v_exchange -> 'max_count', 'base.exchange.max_count', 1, 5);
  v_max_count := coalesce(public.stv_to_int(v_exchange -> 'max_count'), 1);

  v_errors := public.stv_replacement_trial(
    v_errors, v_exchange -> 'replacement_trial', 'base.exchange.replacement_trial', v_max_count);
  v_errors := public.stv_minimum_rule(
    v_errors, v_exchange -> 'replacement_minimum', 'base.exchange.replacement_minimum',
    'SAME_AS_POLICY', coalesce(v_length, 730));
  v_errors := public.stv_enum(
    v_errors, v_exchange -> 'downgrade_difference', 'base.exchange.downgrade_difference',
    array['REFUND_ORIGINAL', 'STORE_CREDIT', 'NOT_REFUNDED']);
  v_errors := public.stv_bool(v_errors, v_exchange -> 'require_concern', 'base.exchange.require_concern');
  v_errors := public.stv_int(v_errors, v_exchange -> 'require_concern_age_days', 'base.exchange.require_concern_age_days', 0, 60);
  v_errors := public.stv_bool(v_errors, v_exchange -> 'early_exception_allowed', 'base.exchange.early_exception_allowed');
  v_errors := public.stv_bool(v_errors, v_exchange -> 'expired_exception_allowed', 'base.exchange.expired_exception_allowed');
  v_errors := public.stv_bool(v_errors, v_exchange -> 'cross_brand_allowed', 'base.exchange.cross_brand_allowed');
  v_errors := public.stv_bool(v_errors, v_exchange -> 'size_change_allowed', 'base.exchange.size_change_allowed');

  -- Section 4: Returns -------------------------------------------------------
  v_errors := public.stv_bool(v_errors, v_return -> 'allowed', 'base.return.allowed');
  v_errors := public.stv_bool(v_errors, v_return -> 'approval_required', 'base.return.approval_required');
  v_errors := public.stv_bool(v_errors, v_return -> 'exception_allowed', 'base.return.exception_allowed');
  v_errors := public.stv_minimum_rule(
    v_errors, v_return -> 'minimum_nights', 'base.return.minimum_nights',
    'SAME_AS_EXCHANGE', coalesce(v_length, 730));
  v_errors := public.stv_enum(
    v_errors, v_return -> 'refund_method', 'base.return.refund_method',
    array['ORIGINAL_TENDER', 'STORE_CREDIT', 'CUSTOMER_CHOICE']);

  -- Section 5: Fees ----------------------------------------------------------
  v_errors := public.stv_enum(
    v_errors, v_fees -> 'basis', 'base.fees.basis',
    array['NET_SELLING_PRICE', 'PRE_DISCOUNT_SELLING_PRICE']);
  if v_fees -> 'tiered' is not null then
    v_errors := public.stv_bool(v_errors, v_fees -> 'tiered', 'base.fees.tiered');
  end if;
  if v_fees -> 'waiver_allowed' is not null then
    v_errors := public.stv_bool(v_errors, v_fees -> 'waiver_allowed', 'base.fees.waiver_allowed');
  end if;

  if v_schedules is null or jsonb_typeof(v_schedules) <> 'object' then
    v_errors := public.stv_err(v_errors, 'fee_schedules', 'is required');
  else
    -- The two built-in schedules always exist (Section 5.3).
    for v_sched_key in select key from (values ('exchange_default'), ('return_default')) as k(key) loop
      if v_schedules -> v_sched_key is null then
        v_errors := public.stv_err(v_errors, 'fee_schedules.' || v_sched_key, 'built-in schedule is missing');
      end if;
    end loop;

    for v_sched_key in select key from jsonb_object_keys(v_schedules) as key loop
      v_acc := public.stv_fee_schedule(
        jsonb_build_object('errors', v_errors, 'warnings', v_warnings),
        v_schedules -> v_sched_key,
        'fee_schedules.' || v_sched_key,
        coalesce(v_min, 0));
      v_errors := v_acc -> 'errors';
      v_warnings := v_acc -> 'warnings';
    end loop;

    -- Schedule references must resolve.
    if v_fees ->> 'exchange_schedule' is not null
       and v_schedules -> (v_fees ->> 'exchange_schedule') is null then
      v_errors := public.stv_err(v_errors, 'base.fees.exchange_schedule', 'unknown fee schedule key');
    end if;
    if v_fees ->> 'return_schedule' is not null
       and v_schedules -> (v_fees ->> 'return_schedule') is null then
      v_errors := public.stv_err(v_errors, 'base.fees.return_schedule', 'unknown fee schedule key');
    end if;
  end if;

  -- Section 6: Protector -----------------------------------------------------
  v_errors := public.stv_bool(v_errors, v_protector -> 'required', 'base.protector.required');
  if v_protector -> 'qualifying_category_ids' is not null
     and jsonb_typeof(v_protector -> 'qualifying_category_ids') <> 'array' then
    v_errors := public.stv_err(v_errors, 'base.protector.qualifying_category_ids', 'must be a list of category ids');
  end if;
  if jsonb_typeof(v_protector -> 'required') = 'boolean'
     and (v_protector ->> 'required')::boolean
     and coalesce(
       case when jsonb_typeof(v_protector -> 'qualifying_category_ids') = 'array'
            then jsonb_array_length(v_protector -> 'qualifying_category_ids') end, 0) = 0 then
    v_errors := public.stv_err(
      v_errors, 'base.protector.qualifying_category_ids',
      'at least one qualifying category is required when the protector is required');
  end if;
  if v_protector -> 'qualifying_product_ids' is not null
     and jsonb_typeof(v_protector -> 'qualifying_product_ids') <> 'array' then
    v_errors := public.stv_err(v_errors, 'base.protector.qualifying_product_ids', 'must be a list of product ids');
  end if;
  v_errors := public.stv_int(v_errors, v_protector -> 'purchase_window_days', 'base.protector.purchase_window_days', 0, 120);
  v_errors := public.stv_enum(
    v_errors, v_protector -> 'missing_behavior', 'base.protector.missing_behavior',
    array['BLOCK_WITH_OVERRIDE', 'APPROVAL_REQUIRED', 'WARN_ONLY']);
  v_errors := public.stv_enum(
    v_errors, v_protector -> 'applies_to', 'base.protector.applies_to',
    array['EXCHANGE_AND_RETURN', 'EXCHANGE_ONLY', 'RETURN_ONLY']);
  v_errors := public.stv_enum(
    v_errors, v_protector -> 'split_king_units', 'base.protector.split_king_units',
    array['ONE', 'TWO']);
  if v_min is not null
     and coalesce(public.stv_to_int(v_protector -> 'purchase_window_days'), 0) > v_min then
    v_warnings := v_warnings || jsonb_build_array(jsonb_build_object(
      'path', 'base.protector.purchase_window_days',
      'message', 'Protector purchase window is longer than the ' || v_min || '-night minimum'));
  end if;

  -- Section 7: Product Rules (split king + inspection live in the base) ------
  v_errors := public.stv_enum(
    v_errors, v_split -> 'treatment', 'base.split_king.treatment',
    array['INDEPENDENT', 'PAIRED']);
  if v_inspection -> 'required' is not null then
    v_errors := public.stv_bool(v_errors, v_inspection -> 'required', 'base.inspection.required');
  end if;
  if v_inspection -> 'checklist' is not null then
    if jsonb_typeof(v_inspection -> 'checklist') <> 'array'
       or jsonb_array_length(v_inspection -> 'checklist') > 15 then
      v_errors := public.stv_err(v_errors, 'base.inspection.checklist', 'must be a list of at most 15 items');
    end if;
  end if;
  if v_inspection -> 'photos_required' is not null then
    v_errors := public.stv_bool(v_errors, v_inspection -> 'photos_required', 'base.inspection.photos_required');
  end if;
  if v_inspection -> 'failed_behavior' is not null then
    v_errors := public.stv_enum(
      v_errors, v_inspection -> 'failed_behavior', 'base.inspection.failed_behavior',
      array['BLOCK', 'APPROVAL_REQUIRED']);
  end if;

  -- Section 8: Approvals & Exceptions ---------------------------------------
  v_errors := public.stv_int(v_errors, v_exceptions -> 'approval_valid_days', 'base.exceptions.approval_valid_days', 1, 90);
  if v_exceptions -> 'reason_required' is not null then
    v_errors := public.stv_bool(v_errors, v_exceptions -> 'reason_required', 'base.exceptions.reason_required');
  end if;
  if v_exceptions -> 'attachments_allowed' is not null then
    v_errors := public.stv_bool(v_errors, v_exceptions -> 'attachments_allowed', 'base.exceptions.attachments_allowed');
  end if;
  if v_exceptions -> 'self_approval_note_required' is not null then
    v_errors := public.stv_bool(v_errors, v_exceptions -> 'self_approval_note_required', 'base.exceptions.self_approval_note_required');
  end if;

  -- Section 9: Customer Communication ---------------------------------------
  v_errors := public.stv_text(v_errors, v_comm -> 'policy_text', 'base.communication.policy_text', 5000);
  -- SIGNATURE is reserved post-MVP.
  if v_comm -> 'acknowledgment' is not null then
    v_errors := public.stv_enum(
      v_errors, v_comm -> 'acknowledgment', 'base.communication.acknowledgment',
      array['NONE', 'CHECKBOX']);
  end if;
  if v_comm -> 'show_on_receipt' is not null then
    v_errors := public.stv_bool(v_errors, v_comm -> 'show_on_receipt', 'base.communication.show_on_receipt');
  end if;

  -- Overrides (Section 6) ----------------------------------------------------
  if v_overrides is not null then
    if jsonb_typeof(v_overrides) <> 'array' then
      v_errors := public.stv_err(v_errors, 'overrides', 'must be a list');
    else
      for v_i in 0 .. jsonb_array_length(v_overrides) - 1 loop
        v_override := v_overrides -> v_i;
        v_scope := v_override -> 'scope';
        v_scope_type := v_scope ->> 'type';
        v_scope_value := v_scope ->> 'value';
        declare
          v_opath text := 'overrides[' || v_i || ']';
        begin
          if v_scope_type is null or v_scope_type not in ('CATEGORY', 'BRAND', 'PRODUCT', 'CONDITION') then
            -- STORE is retired (L5), PROMOTION is reserved post-MVP, COMPANY is
            -- the base definition rather than an override.
            v_errors := public.stv_err(
              v_errors, v_opath || '.scope.type',
              'must be one of: CATEGORY, BRAND, PRODUCT, CONDITION');
          end if;
          if v_scope_value is null or btrim(v_scope_value) = '' then
            v_errors := public.stv_err(v_errors, v_opath || '.scope.value', 'is required');
          elsif v_scope_type is not null then
            if (v_scope_type || ':' || v_scope_value) = any (v_seen) then
              v_errors := public.stv_err(
                v_errors, v_opath || '.scope',
                'another override already uses this scope (canonical 17.40)');
            end if;
            v_seen := v_seen || (v_scope_type || ':' || v_scope_value);
          end if;

          v_set := v_override -> 'set';
          if v_set is null or jsonb_typeof(v_set) <> 'object' then
            v_errors := public.stv_err(v_errors, v_opath || '.set', 'must be an object of field overrides');
          else
            for v_set_key in select key from jsonb_object_keys(v_set) as key loop
              if not (v_set_key = any (v_whitelist)) then
                v_errors := public.stv_err(
                  v_errors, v_opath || '.set.' || v_set_key,
                  'is not an overridable field (Section 6.5)');
              else
                case v_set_key
                  when 'trial.enabled', 'trial.extensions_allowed',
                       'exchange.allowed', 'exchange.early_exception_allowed',
                       'exchange.expired_exception_allowed', 'return.allowed',
                       'return.approval_required', 'return.exception_allowed',
                       'protector.required' then
                    v_errors := public.stv_bool(v_errors, v_set -> v_set_key, v_opath || '.set.' || v_set_key);
                  when 'trial.length_nights' then
                    v_errors := public.stv_int(v_errors, v_set -> v_set_key, v_opath || '.set.' || v_set_key, 1, 730);
                  when 'trial.minimum_nights' then
                    v_errors := public.stv_int(v_errors, v_set -> v_set_key, v_opath || '.set.' || v_set_key, 0, 730);
                  when 'trial.max_extension_nights' then
                    v_errors := public.stv_int(v_errors, v_set -> v_set_key, v_opath || '.set.' || v_set_key, 1, 365);
                  when 'exchange.max_count' then
                    v_errors := public.stv_int(v_errors, v_set -> v_set_key, v_opath || '.set.' || v_set_key, 1, 5);
                  when 'exchange.replacement_trial' then
                    v_errors := public.stv_replacement_trial(
                      v_errors, v_set -> v_set_key, v_opath || '.set.' || v_set_key, v_max_count);
                  when 'exchange.replacement_minimum' then
                    v_errors := public.stv_minimum_rule(
                      v_errors, v_set -> v_set_key, v_opath || '.set.' || v_set_key,
                      'SAME_AS_POLICY', coalesce(v_length, 730));
                  when 'return.minimum_nights' then
                    v_errors := public.stv_minimum_rule(
                      v_errors, v_set -> v_set_key, v_opath || '.set.' || v_set_key,
                      'SAME_AS_EXCHANGE', coalesce(v_length, 730));
                  when 'fees.exchange_schedule', 'fees.return_schedule' then
                    if jsonb_typeof(v_set -> v_set_key) <> 'string' then
                      v_errors := public.stv_err(v_errors, v_opath || '.set.' || v_set_key, 'must be a schedule key');
                    elsif v_schedules is not null
                          and v_schedules -> (v_set ->> v_set_key) is null then
                      v_errors := public.stv_err(v_errors, v_opath || '.set.' || v_set_key, 'unknown fee schedule key');
                    end if;
                  else
                    null;
                end case;
              end if;
            end loop;
          end if;
        end;
      end loop;
    end if;
  end if;

  return jsonb_build_object('errors', v_errors, 'warnings', v_warnings);
end;
$$;

grant execute on function public.validate_sleep_trial_definition(jsonb) to authenticated;

-- The stv_* validation helpers are pure functions (immutable, no data access)
-- and validate_sleep_trial_definition — which clients may call — is a security
-- invoker, so the helpers keep default execute grants. Only write-path and
-- security-definer internals are revoked below.

-- ---------------------------------------------------------------------------
-- 5. Field-level diff (for the publish audit event)
-- ---------------------------------------------------------------------------

create or replace function public.stv_flatten(p_value jsonb, p_path text default '')
returns table(path text, value text)
language plpgsql
immutable
as $$
declare
  k text;
begin
  if jsonb_typeof(p_value) = 'object' then
    for k in select key from jsonb_object_keys(p_value) as key loop
      return query
        select public.stv_flatten(
          p_value -> k,
          case when p_path = '' then k else p_path || '.' || k end);
    end loop;
  else
    -- Arrays compare as a whole leaf; scalars as their text.
    return query select p_path, p_value::text;
  end if;
end;
$$;

create or replace function public.stv_definition_diff(p_before jsonb, p_after jsonb)
returns jsonb
language sql
immutable
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'path', coalesce(a.path, b.path),
           'before', b.value,
           'after', a.value)
         order by coalesce(a.path, b.path)), '[]'::jsonb)
  from public.stv_flatten(coalesce(p_after, 'null'::jsonb)) a
  full outer join public.stv_flatten(coalesce(p_before, 'null'::jsonb)) b
    on b.path = a.path
  where a.value is distinct from b.value;
$$;

revoke execute on function public.stv_flatten(jsonb, text) from public, anon, authenticated;
revoke execute on function public.stv_definition_diff(jsonb, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Draft / publish commands
-- ---------------------------------------------------------------------------

-- Returns the company's SLEEP_TRIAL policy id, creating the policy row if this
-- company has somehow never been seeded.
create or replace function public.stv_sleep_trial_policy(p_company_id uuid, p_actor uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_policy_id uuid;
begin
  select id into v_policy_id
  from public.policies
  where company_id = p_company_id and policy_type = 'SLEEP_TRIAL';

  if v_policy_id is null then
    insert into public.policies (company_id, policy_type, name, created_by)
    values (p_company_id, 'SLEEP_TRIAL', 'Sleep Trial Policy', p_actor)
    returning id into v_policy_id;
  end if;

  return v_policy_id;
end;
$$;

revoke execute on function public.stv_sleep_trial_policy(uuid, uuid) from public, anon, authenticated;

-- Create the draft if none exists, else replace its definition. Saves even
-- with validation errors (spec 5.2: the draft is the working surface).
-- Returns the validation result.
create or replace function public.save_sleep_trial_draft(p_definition jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid;
  v_company_id uuid;
  v_policy_id uuid;
  v_draft_id uuid;
  v_old_definition jsonb;
  v_validation jsonb;
  v_diff jsonb;
begin
  if not public.has_permission('sleep_trial.manage_policy') then
    raise exception 'Missing permission: sleep_trial.manage_policy';
  end if;

  select e.id, s.company_id into v_actor, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid();

  v_policy_id := public.stv_sleep_trial_policy(v_company_id, v_actor);
  v_validation := public.validate_sleep_trial_definition(p_definition);

  select id, definition into v_draft_id, v_old_definition
  from public.policy_versions
  where policy_id = v_policy_id and status = 'DRAFT';

  if v_draft_id is not null then
    if v_old_definition is distinct from p_definition then
      update public.policy_versions
      set definition = p_definition,
          definition_schema_version = coalesce(
            public.stv_to_int(p_definition -> 'schema_version'), 1)
      where id = v_draft_id;

      -- Audit the field-level diff only — full definitions on every autosave
      -- are noise. An empty diff means nothing real changed; skip the row.
      v_diff := public.stv_definition_diff(v_old_definition, p_definition);
      if coalesce(jsonb_array_length(v_diff), 0) > 0 then
        perform public.log_audit_event(
          p_company_id   := v_company_id,
          p_entity_type  := 'policy_version',
          p_entity_id    := v_draft_id,
          p_event_type   := 'SLEEP_TRIAL_POLICY_DRAFT_SAVED',
          p_after        := jsonb_build_object('diff', v_diff),
          p_actor_employee_id := v_actor
        );
      end if;
    end if;
  else
    insert into public.policy_versions (
      policy_id, company_id, version_number, status, definition,
      definition_schema_version, created_by
    )
    select v_policy_id, v_company_id,
           coalesce(max(version_number), 0) + 1, 'DRAFT', p_definition,
           coalesce(
             public.stv_to_int(p_definition -> 'schema_version'), 1),
           v_actor
    from public.policy_versions
    where policy_id = v_policy_id
    returning id into v_draft_id;

    perform public.log_audit_event(
      p_company_id   := v_company_id,
      p_entity_type  := 'policy_version',
      p_entity_id    := v_draft_id,
      p_event_type   := 'SLEEP_TRIAL_POLICY_DRAFT_SAVED',
      p_after        := jsonb_build_object('definition', p_definition),
      p_actor_employee_id := v_actor
    );
  end if;

  return v_validation;
end;
$$;

create or replace function public.discard_sleep_trial_draft()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid;
  v_company_id uuid;
  v_draft record;
begin
  if not public.has_permission('sleep_trial.manage_policy') then
    raise exception 'Missing permission: sleep_trial.manage_policy';
  end if;

  select e.id, s.company_id into v_actor, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid();

  select v.id, v.version_number into v_draft
  from public.policy_versions v
  join public.policies p on p.id = v.policy_id
  where p.company_id = v_company_id
    and p.policy_type = 'SLEEP_TRIAL'
    and v.status = 'DRAFT';

  if v_draft.id is null then
    return;
  end if;

  delete from public.policy_versions where id = v_draft.id;

  perform public.log_audit_event(
    p_company_id   := v_company_id,
    p_entity_type  := 'policy_version',
    p_entity_id    := v_draft.id,
    p_event_type   := 'SLEEP_TRIAL_POLICY_DRAFT_DISCARDED',
    p_before       := jsonb_build_object('version_number', v_draft.version_number),
    p_actor_employee_id := v_actor
  );
end;
$$;

-- Publishes the draft: validates (any error blocks), retires the current
-- published version, stamps the draft PUBLISHED, and points the policy at it.
-- The audit event carries a field-level diff against the previous version.
create or replace function public.publish_sleep_trial_draft(p_summary_text text, p_note text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid;
  v_company_id uuid;
  v_policy_id uuid;
  v_draft record;
  v_current record;
  v_errors jsonb;
  v_diff jsonb;
begin
  if not public.has_permission('sleep_trial.manage_policy') then
    raise exception 'Missing permission: sleep_trial.manage_policy';
  end if;

  select e.id, s.company_id into v_actor, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid();

  select p.id into v_policy_id
  from public.policies p
  where p.company_id = v_company_id and p.policy_type = 'SLEEP_TRIAL';

  if v_policy_id is null then
    raise exception 'No Sleep Trial policy exists for this company';
  end if;

  select id, version_number, definition into v_draft
  from public.policy_versions
  where policy_id = v_policy_id and status = 'DRAFT';

  if v_draft.id is null then
    raise exception 'No draft to publish';
  end if;

  v_errors := public.validate_sleep_trial_definition(v_draft.definition) -> 'errors';
  if coalesce(jsonb_array_length(v_errors), 0) > 0 then
    raise exception 'Policy definition has validation errors'
      using detail = v_errors::text;
  end if;

  -- Section 31 blockers that depend on company state rather than the
  -- definition itself: exception/approval features enabled with no role able
  -- to approve. (Owner grants can't be revoked, so this only fires if grants
  -- were hand-edited.) These are booleans here because validation passed.
  if (
    coalesce((v_draft.definition #>> '{base,exchange,early_exception_allowed}')::boolean, false)
    or coalesce((v_draft.definition #>> '{base,exchange,expired_exception_allowed}')::boolean, false)
    or coalesce((v_draft.definition #>> '{base,return,exception_allowed}')::boolean, false)
    or coalesce((v_draft.definition #>> '{base,return,approval_required}')::boolean, false)
  ) and not exists (
    select 1 from public.role_permission_grants g
    where g.company_id = v_company_id
      and g.permission_key = 'sleep_trial.approve_exceptions'
  ) then
    raise exception 'Exceptions or return approvals are enabled, but no role has the Approve exceptions permission';
  end if;

  select id, version_number, definition into v_current
  from public.policy_versions
  where policy_id = v_policy_id and status = 'PUBLISHED';

  v_diff := public.stv_definition_diff(v_current.definition, v_draft.definition);

  if v_current.id is not null then
    update public.policy_versions
    set status = 'RETIRED', effective_until = now()
    where id = v_current.id;
  end if;

  update public.policy_versions
  set status = 'PUBLISHED',
      effective_from = now(),
      published_at = now(),
      published_by = v_actor,
      summary_text = p_summary_text,
      publish_note = p_note
  where id = v_draft.id;

  update public.policies
  set current_version_id = v_draft.id
  where id = v_policy_id;

  perform public.log_audit_event(
    p_company_id   := v_company_id,
    p_entity_type  := 'policy_version',
    p_entity_id    := v_draft.id,
    p_event_type   := 'SLEEP_TRIAL_POLICY_PUBLISHED',
    p_before       := jsonb_build_object('version_number', v_current.version_number),
    p_after        := jsonb_build_object(
                        'version_number', v_draft.version_number,
                        'summary_text', p_summary_text,
                        'diff', v_diff),
    p_note         := p_note,
    p_actor_employee_id := v_actor
  );
end;
$$;

grant execute on function public.save_sleep_trial_draft(jsonb) to authenticated;
grant execute on function public.discard_sleep_trial_draft() to authenticated;
grant execute on function public.publish_sleep_trial_draft(text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 7. Seed: Version 1 for every company
-- ---------------------------------------------------------------------------

-- Seeds Version 1. The literal below is the Section 5.3 default set (120
-- nights, 30-night minimum, 14-day ending-soon warning, day-after counting,
-- no fees per L12) — what every NEW company gets. Existing tenants instead
-- get the decided values (Section 35: 60-night minimum, 15-day warning); the
-- backfill passes p_use_tbm_values = true, which patches just those fields.
create or replace function public.seed_sleep_trial_policy(
  p_company_id uuid,
  p_use_tbm_values boolean default false
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_policy_id uuid;
  v_version_id uuid;
  v_definition jsonb := $def$
  {
    "schema_version": 1,
    "base": {
      "trial": {
        "enabled": true, "length_nights": 120, "minimum_nights": 30,
        "start_event": "FULFILLMENT_COMPLETED",
        "count_starts": "DAY_AFTER_FULFILLMENT",
        "ending_soon_days": 14, "extensions_allowed": true,
        "max_extension_nights": 30, "checkin_nights": [14],
        "eligibility_reached_task": false, "ending_soon_task": false
      },
      "exchange": {
        "allowed": true, "max_count": 1,
        "replacement_trial": [{"n": 1, "rule": "FULL_NEW"}],
        "replacement_minimum": {"rule": "SAME_AS_POLICY"},
        "downgrade_difference": "STORE_CREDIT",
        "require_concern": false, "require_concern_age_days": 0,
        "early_exception_allowed": true, "expired_exception_allowed": true,
        "cross_brand_allowed": true, "size_change_allowed": true
      },
      "return": {
        "allowed": false, "approval_required": true,
        "exception_allowed": true, "minimum_nights": "SAME_AS_EXCHANGE",
        "refund_method": "ORIGINAL_TENDER"
      },
      "fees": {
        "tiered": false, "basis": "NET_SELLING_PRICE", "waiver_allowed": true,
        "exchange_schedule": "exchange_default", "return_schedule": "return_default"
      },
      "protector": {
        "required": false, "qualifying_category_ids": [],
        "qualifying_product_ids": [], "purchase_window_days": 0,
        "missing_behavior": "BLOCK_WITH_OVERRIDE",
        "applies_to": "EXCHANGE_AND_RETURN", "split_king_units": "ONE"
      },
      "split_king": {"treatment": "INDEPENDENT"},
      "inspection": {
        "required": false,
        "checklist": ["Clean, no stains", "No damage", "Law tag attached", "Protector was used"],
        "photos_required": false, "failed_behavior": "APPROVAL_REQUIRED"
      },
      "condition": {"stains_void_trial": false},
      "exceptions": {
        "approval_valid_days": 14, "reason_required": true,
        "attachments_allowed": true, "self_approval_note_required": true
      },
      "communication": {
        "policy_text": "", "acknowledgment": "NONE", "show_on_receipt": true
      }
    },
    "fee_schedules": {
      "exchange_default": {"windows": [
        {"from_night": 1, "to_night": null, "outcome": "ALLOWED", "percent_bp": 0, "flat_cents": 0}
      ]},
      "return_default": {"windows": [
        {"from_night": 1, "to_night": null, "outcome": "ALLOWED", "percent_bp": 0, "flat_cents": 0}
      ]}
    },
    "overrides": []
  }
  $def$::jsonb;
  v_summary text;
begin
  if p_use_tbm_values then
    v_definition := jsonb_set(
      jsonb_set(v_definition, '{base,trial,minimum_nights}', '60'),
      '{base,trial,ending_soon_days}', '15');
    v_summary := 'Customers get a 120-night sleep trial starting the day after their mattress is delivered or picked up. They can exchange after 60 nights. One exchange is allowed. There is no exchange fee. Returns are not allowed.';
  else
    v_summary := 'Customers get a 120-night sleep trial starting the day after their mattress is delivered or picked up. They can exchange after 30 nights. One exchange is allowed. There is no exchange fee. Returns are not allowed.';
  end if;

  select id into v_policy_id
  from public.policies
  where company_id = p_company_id and policy_type = 'SLEEP_TRIAL';

  if v_policy_id is null then
    insert into public.policies (company_id, policy_type, name)
    values (p_company_id, 'SLEEP_TRIAL', 'Sleep Trial Policy')
    returning id into v_policy_id;
  end if;

  -- Already seeded (or a real version exists): leave it alone.
  if exists (
    select 1 from public.policy_versions
    where policy_id = v_policy_id and status = 'PUBLISHED'
  ) then
    return;
  end if;

  insert into public.policy_versions (
    policy_id, company_id, version_number, status, definition,
    definition_schema_version, summary_text, effective_from,
    published_at
  ) values (
    v_policy_id, p_company_id, 1, 'PUBLISHED', v_definition, 1,
    v_summary,
    now(), now()
  )
  returning id into v_version_id;

  update public.policies
  set current_version_id = v_version_id
  where id = v_policy_id;
end;
$$;

-- New companies get a published Version 1 alongside their permission grants.
create or replace function public.seed_sleep_trial_policy_on_company_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.seed_sleep_trial_policy(new.id);
  return new;
end;
$$;

drop trigger if exists companies_seed_sleep_trial_policy on public.companies;
create trigger companies_seed_sleep_trial_policy
  after insert on public.companies
  for each row
  execute function public.seed_sleep_trial_policy_on_company_insert();

-- Backfill every existing company with the decided values (Section 35).
select public.seed_sleep_trial_policy(id, true)
from public.companies;

revoke execute on function public.seed_sleep_trial_policy(uuid, boolean) from public, anon, authenticated;
revoke execute on function public.seed_sleep_trial_policy_on_company_insert() from public, anon, authenticated;
revoke execute on function public.policy_versions_guard() from public, anon, authenticated;
