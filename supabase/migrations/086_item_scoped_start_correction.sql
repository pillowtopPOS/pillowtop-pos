-- 086_item_scoped_start_correction.sql
--
-- Move trial-start correction from journey scope to trial-item scope
-- (spec 11.5: "correct_trial_start, moved to item level").
--
-- Before: correct_trial_start(journey, date, reason) rewrote
-- sleep_journeys.delivered_at, and trg_stv_journey_delivered then cascaded
-- the new date onto EVERY PENDING_FULFILLMENT/ACTIVE trial item on the
-- journey — on a two-mattress order, correcting one start moved the other.
--
-- After: a new 4-arg overload takes the trial item id and rewrites only
-- that item's started_on (the evaluator reads started_on per item, so
-- night count, eligibility, end date, and fees all recalculate for that
-- mattress alone). sleep_trial_start_corrections.trial_item_id — added in
-- 069 but never populated — is now written.
--
-- sleep_journeys.delivered_at is still synced when the journey has exactly
-- one trial item (it backs the "Delivered X" label, the trial-completion
-- cron, and the concern/delivered guards). The written value is the
-- implied delivery date under the item's own count_starts rule, so the
-- delivered trigger's recompute lands on the same started_on and skips the
-- item (is-distinct check — no double write, no double audit). With more
-- than one item the journey columns are left alone.
--
-- The original 3-arg signature is kept as a dispatcher: one item → the
-- item path (converting the legacy "delivery date" argument into a start
-- date via the item's count_starts rule, so old callers keep their
-- meaning); zero items → the 057 journey-level behavior verbatim; more
-- than one → a clear rejection instead of a silent journey-wide cascade.
--
-- Status handling mirrors the 069 cascade: ACTIVE items get the corrected
-- started_on + SLEEP_TRIAL_START_CORRECTED audit; PENDING_FULFILLMENT
-- items on a delivered journey are activated the same way the delivered
-- trigger would activate them (the entered date is the asserted Night 1);
-- CLOSED / VOIDED / EXCHANGE_IN_PROGRESS / RETURN_IN_PROGRESS items are
-- rejected — the old trigger skipped them, and recording a correction that
-- changed nothing would be misleading.

-- ============================================================================
-- 1. Item-scoped overload: correct a single trial item's start date
-- ============================================================================

create or replace function public.correct_trial_start(
  p_journey_id uuid,
  p_trial_item_id uuid,
  p_new_started_at date,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.sleep_trial_items%rowtype;
  v_journey public.sleep_journeys%rowtype;
  v_employee_id uuid;
  v_correction_id uuid;
  v_summary text;
  v_item_name text;
  v_unit_price numeric;
  v_fee_cents int;
  v_item_count int;
  v_delivered_equiv date;
begin
  select * into v_item
  from public.sleep_trial_items
  where id = p_trial_item_id;

  if v_item.id is null then
    raise exception 'Trial item not found';
  end if;
  if v_item.journey_id is distinct from p_journey_id then
    raise exception 'Trial item does not belong to this journey';
  end if;

  if not public.is_journey_visible(p_journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  -- Same privileged-role check as the 057 version: owner/admin/manager in
  -- the journey's company.
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

  -- Same date rules as before: required, never future, plus the delivery
  -- floor from 061 (not before the journey existed, relaxed one day for
  -- timezone drift).
  if p_new_started_at is null then
    raise exception 'New trial start date is required';
  end if;
  if p_new_started_at > current_date then
    raise exception 'Trial start date cannot be in the future';
  end if;
  if v_journey.created_at is not null
     and p_new_started_at < v_journey.created_at::date - 1 then
    raise exception 'Trial start date cannot be before the journey was created';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required to correct the trial start';
  end if;

  if v_item.status = 'PENDING_FULFILLMENT' then
    -- The 057 guard: nothing to correct until the journey is delivered.
    if v_journey.delivered_at is null then
      raise exception 'Journey has no trial start to correct';
    end if;

    -- Same activation the delivered trigger performs for pending items
    -- (069): the corrected date is the asserted start, not re-derived.
    select jli.unit_price into v_unit_price
    from public.journey_line_items jli
    where jli.id = v_item.line_item_id;
    v_fee_cents := case when v_unit_price is not null
                        then round(v_unit_price * 100)::int end;

    update public.sleep_trial_items
    set status = 'ACTIVE',
        started_on = p_new_started_at,
        start_source = 'CORRECTION',
        fee_basis_cents = coalesce(fee_basis_cents, v_fee_cents),
        fee_basis_source = coalesce(fee_basis_source,
          case when v_fee_cents is not null then 'UNIT_PRICE' end),
        updated_at = now()
    where id = v_item.id;

    perform public.log_audit_event(
      v_item.company_id,
      'sleep_trial_item', v_item.id, 'SLEEP_TRIAL_STARTED',
      jsonb_build_object('status', 'PENDING_FULFILLMENT'),
      jsonb_build_object('status', 'ACTIVE', 'started_on', p_new_started_at,
                         'start_source', 'CORRECTION',
                         'fee_basis_cents', v_fee_cents),
      null, null, v_item.journey_id, 'EMPLOYEE', v_employee_id);

  elsif v_item.status = 'ACTIVE' then
    if v_item.started_on is null then
      raise exception 'This mattress has no trial start to correct';
    end if;
    if p_new_started_at = v_item.started_on then
      raise exception 'New date matches the current trial start';
    end if;

    update public.sleep_trial_items
    set started_on = p_new_started_at,
        start_source = 'CORRECTION',
        updated_at = now()
    where id = v_item.id;

    perform public.log_audit_event(
      v_item.company_id,
      'sleep_trial_item', v_item.id, 'SLEEP_TRIAL_START_CORRECTED',
      jsonb_build_object('started_on', v_item.started_on),
      jsonb_build_object('started_on', p_new_started_at),
      null, null, v_item.journey_id, 'EMPLOYEE', v_employee_id);
  else
    -- CLOSED / VOIDED / EXCHANGE_IN_PROGRESS / RETURN_IN_PROGRESS: the old
    -- cascade never touched these rows, so leave the item alone and reject
    -- instead of writing a correction row that changed nothing.
    raise exception 'This mattress''s trial is not active (status %) — its start date cannot be corrected',
      v_item.status;
  end if;

  -- Correction row: same fields as before plus trial_item_id.
  -- v_item still holds the pre-update row, so previous_started_at is the
  -- item's own old start.
  insert into public.sleep_trial_start_corrections (
    journey_id,
    trial_item_id,
    previous_started_at,
    new_started_at,
    reason,
    corrected_by_employee_id
  ) values (
    p_journey_id,
    v_item.id,
    v_item.started_on,
    p_new_started_at,
    btrim(p_reason),
    v_employee_id
  )
  returning id into v_correction_id;

  -- Journey-level start column: only meaningful while one item defines it.
  select count(*) into v_item_count
  from public.sleep_trial_items
  where journey_id = p_journey_id;

  if v_item_count = 1 then
    v_delivered_equiv := case
      when v_item.resolved_terms #>> '{trial,count_starts}' = 'FULFILLMENT_DATE'
        then p_new_started_at
      else p_new_started_at - 1 end;

    -- Fires trg_stv_journey_delivered, which recomputes this item's
    -- started_on back to p_new_started_at and skips it via the
    -- is-distinct check — one write, one audit.
    update public.sleep_journeys
    set delivered_at = v_delivered_equiv,
        updated_at = now()
    where id = p_journey_id;
  end if;

  -- Journey Activity row, same shape as 057, naming the mattress so a
  -- multi-mattress feed shows which one moved.
  v_item_name := nullif(btrim(
    coalesce(v_item.size_snapshot, '') || ' ' ||
    coalesce(v_item.product_name_snapshot, '')), '');
  v_summary := 'Trial start corrected'
    || case when v_item_name is not null
            then ' (' || v_item_name || ')' else '' end
    || ': ' || coalesce(v_item.started_on::text, 'unset')
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

grant execute on function public.correct_trial_start(uuid, uuid, date, text)
  to authenticated;

-- ============================================================================
-- 2. Original signature, kept as a dispatcher for old callers
-- ============================================================================

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
  v_item_count int;
  v_item_id uuid;
  v_count_starts text;
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

  select count(*) into v_item_count
  from public.sleep_trial_items
  where journey_id = p_journey_id;

  if v_item_count > 1 then
    raise exception 'This journey has % mattresses — pass the trial item id to correct a single mattress start date', v_item_count;
  end if;

  if v_item_count = 1 then
    select id, resolved_terms #>> '{trial,count_starts}'
      into v_item_id, v_count_starts
    from public.sleep_trial_items
    where journey_id = p_journey_id;

    -- Old callers passed a delivery date; the item path takes the trial
    -- start. Convert via the item's count_starts rule (the same +1 the
    -- delivered trigger applies) so the legacy meaning is preserved.
    return public.correct_trial_start(
      p_journey_id,
      v_item_id,
      case when v_count_starts = 'FULFILLMENT_DATE'
           then p_new_started_at
           else p_new_started_at + 1 end,
      p_reason);
  end if;

  -- No trial items on the journey: the 057 journey-level behavior,
  -- unchanged.
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
