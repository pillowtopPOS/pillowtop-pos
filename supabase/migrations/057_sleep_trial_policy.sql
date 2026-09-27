-- PillowTop POS: Sleep Trial policy completion.
--
-- Adds on top of the shipped trial countdown (delivered_at + live
-- stores.trial_length_nights):
--   * per-store minimum adjustment period (separate from total length)
--   * per-store "trial ending soon" warning threshold
--   * a per-journey policy snapshot so later policy changes do not
--     silently alter in-flight trials
--   * category/item-level trial eligibility flags
--   * trial-start correction with preserved history
--
-- delivered_at remains the trial-start anchor (actual possession).

-- ============================================================
-- 1. Store-level policy knobs
-- ============================================================

alter table public.stores
  add column if not exists minimum_adjustment_nights integer not null default 60;

alter table public.stores
  add column if not exists trial_ending_warning_days integer not null default 14;

comment on column public.stores.minimum_adjustment_nights is 'Nights a customer must sleep on the mattress before standard comfort-exchange eligibility';
comment on column public.stores.trial_ending_warning_days is 'Days before trial end at which the journey shows an ending-soon status';

-- ============================================================
-- 2. Category / item level trial eligibility (source doc §56)
--    Category default + nullable per-product override.
--    Effective rule (read in app code):
--      product.sleep_trial_eligible ?? category.sleep_trial_eligible
-- ============================================================

alter table public.product_categories
  add column if not exists sleep_trial_eligible boolean not null default false;

alter table public.products
  add column if not exists sleep_trial_eligible boolean;

comment on column public.products.sleep_trial_eligible is 'NULL inherits the category flag; explicit true/false overrides it';

-- ============================================================
-- 3. Per-journey policy snapshot
--    Stamped when delivered_at is set. NULL snapshot = legacy row;
--    readers fall back to the store's current policy.
-- ============================================================

alter table public.sleep_journeys
  add column if not exists trial_length_nights integer;

alter table public.sleep_journeys
  add column if not exists minimum_adjustment_nights integer;

alter table public.sleep_journeys
  add column if not exists trial_policy_snapshot jsonb;

comment on column public.sleep_journeys.trial_policy_snapshot is 'Policy captured at trial start: {captured_at, trial_length_nights, minimum_adjustment_nights, source}';

-- Backfill snapshots for journeys whose trial already started, using
-- the store's current policy (best available approximation).
update public.sleep_journeys sj
set trial_length_nights = s.trial_length_nights,
    minimum_adjustment_nights = s.minimum_adjustment_nights,
    trial_policy_snapshot = jsonb_build_object(
      'captured_at', sj.delivered_at,
      'trial_length_nights', s.trial_length_nights,
      'minimum_adjustment_nights', s.minimum_adjustment_nights,
      'source', 'backfill'
    )
from public.stores s
where s.id = sj.store_id
  and sj.delivered_at is not null
  and sj.trial_length_nights is null;

-- Stamp the policy snapshot at trial start alongside delivered_at.
create or replace function public.set_journey_delivered_at()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_date date;
  v_journey_created date;
  v_store public.stores%rowtype;
begin
  if new.event_type <> 'delivery_completed' then
    return new;
  end if;

  select sj.created_at::date into v_journey_created
  from public.sleep_journeys sj
  where sj.id = new.journey_id;

  select s.* into v_store
  from public.stores s
  join public.sleep_journeys sj on sj.store_id = s.id
  where sj.id = new.journey_id;

  if new.event_data ? 'delivered_at'
     and new.event_data->>'delivered_at' is not null then
    v_date := (new.event_data->>'delivered_at')::date;
    if v_date > current_date then
      raise exception 'Delivery date cannot be in the future';
    end if;
    if v_journey_created is not null and v_date < v_journey_created then
      raise exception 'Delivery date cannot be before the journey was created';
    end if;
  else
    v_date := new.created_at::date;
  end if;

  update public.sleep_journeys
  set delivered_at = v_date,
      trial_length_nights = coalesce(trial_length_nights, v_store.trial_length_nights),
      minimum_adjustment_nights = coalesce(minimum_adjustment_nights, v_store.minimum_adjustment_nights),
      trial_policy_snapshot = coalesce(trial_policy_snapshot, jsonb_build_object(
        'captured_at', now(),
        'trial_length_nights', v_store.trial_length_nights,
        'minimum_adjustment_nights', v_store.minimum_adjustment_nights,
        'source', 'delivery_completed'
      )),
      updated_at = now()
  where id = new.journey_id;

  return new;
end;
$$;

revoke execute on function public.set_journey_delivered_at() from public, anon, authenticated;

-- ============================================================
-- 4. Trial-start corrections (source doc §65)
--    Authorized employees may correct an erroneous trial-start date;
--    old value, new value, reason, employee, and timestamp preserved.
-- ============================================================

create table if not exists public.sleep_trial_start_corrections (
  id uuid primary key default gen_random_uuid(),
  journey_id uuid not null references public.sleep_journeys (id) on delete cascade,
  previous_started_at date,
  new_started_at date not null,
  reason text not null,
  corrected_by_employee_id uuid not null references public.employees (id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists idx_trial_start_corrections_journey
  on public.sleep_trial_start_corrections (journey_id);

alter table public.sleep_trial_start_corrections enable row level security;

drop policy if exists "Trial start corrections viewable by authenticated users" on public.sleep_trial_start_corrections;
create policy "Trial start corrections viewable by authenticated users"
  on public.sleep_trial_start_corrections for select
  to authenticated
  using (public.is_journey_visible(journey_id));

-- No INSERT/UPDATE/DELETE policies: corrections are written only by
-- the security-definer RPC below so authorization is enforced
-- server-side in one place.

grant select on public.sleep_trial_start_corrections to authenticated;

create or replace function public.correct_trial_start(
  p_journey_id uuid,
  p_new_started_at date,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_journey public.sleep_journeys%rowtype;
  v_employee_id uuid;
  v_correction_id uuid;
  v_summary text;
begin
  if not public.is_journey_visible(p_journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  -- Same privileged-role check used by other correction flows
  -- (payment reconciliation, deposit approvals): owner/admin/manager
  -- in the journey's company.
  if not exists (
    select 1
    from public.employees e
    join public.stores es on es.id = e.home_store_id
    join public.sleep_journeys sj on sj.id = p_journey_id
    join public.stores js on js.id = sj.store_id
    where e.auth_user_id = auth.uid()
      and es.company_id = js.company_id
      and e.role::text in ('owner','admin','manager')
  ) then
    raise exception 'Only owner, admin, or manager may correct a trial start date';
  end if;

  select id into v_employee_id
  from public.employees
  where auth_user_id = auth.uid();

  select * into v_journey
  from public.sleep_journeys
  where id = p_journey_id;

  if v_journey.delivered_at is null then
    raise exception 'Journey has no trial start to correct';
  end if;

  if p_new_started_at is null then
    raise exception 'New trial start date is required';
  end if;
  if p_new_started_at > current_date then
    raise exception 'Trial start date cannot be in the future';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required to correct the trial start';
  end if;
  if p_new_started_at = v_journey.delivered_at then
    raise exception 'New date matches the current trial start';
  end if;

  insert into public.sleep_trial_start_corrections (
    journey_id,
    previous_started_at,
    new_started_at,
    reason,
    corrected_by_employee_id
  ) values (
    p_journey_id,
    v_journey.delivered_at,
    p_new_started_at,
    btrim(p_reason),
    v_employee_id
  )
  returning id into v_correction_id;

  update public.sleep_journeys
  set delivered_at = p_new_started_at,
      updated_at = now()
  where id = p_journey_id;

  -- Record the correction in Journey Activity so the feed explains
  -- what changed; domain truth lives on the journey row itself.
  v_summary := 'Trial start corrected: '
    || coalesce(v_journey.delivered_at::text, 'unset')
    || ' → ' || p_new_started_at::text
    || '. Reason: ' || btrim(p_reason);

  insert into public.journey_interactions (
    journey_id,
    customer_id,
    interaction_type,
    channel,
    direction,
    topic,
    summary,
    created_by_employee_id,
    source_domain,
    source_record_id,
    is_internal
  ) values (
    p_journey_id,
    v_journey.customer_id,
    'other',
    'internal',
    'internal',
    'general',
    v_summary,
    v_employee_id,
    'sleep_trial',
    v_correction_id,
    true
  );

  return v_correction_id;
end;
$$;

-- ============================================================
-- 5. SQL eligibility helper — used by the early-exception RPC in 058
--    and mirrored by the client-side calculator in
--    lib/journeys/sleepTrial.ts. Returns one row describing the
--    trial's current eligibility position.
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
