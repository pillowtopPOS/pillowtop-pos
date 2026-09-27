-- 070_sleep_trial_evaluator.sql
--
-- Sleep Trial Engine, phase ST-4 (docs/sleep-trial-engine.md Sections 10, 11,
-- 12, 13, 26.6, 33). The authoritative eligibility evaluator:
--
--   stv_eval_explain        — reason code + params -> English explanation
--   stv_eval_terminal       — build a terminal action block (PENDING/CLOSED/etc)
--   stv_eval_unknown_result — failure contract: UNKNOWN, never throw
--   stv_eval_protector_coverage — Section 12.2 deterministic allocation
--   stv_eval_action         — Section 10.3 per-action sequence (EXCHANGE/RETURN)
--   stv_eval_inner          — display block + actions + allowed_ui_actions
--   stv_eval_one            — fact gathering (Section 10.2) -> inner
--   evaluate_sleep_trial_item / evaluate_sleep_trial_items — public wrappers
--
-- Then request_concern_exchange and request_sleep_trial_exception are
-- re-pointed at the evaluator and the old trial_status(journey_id) helper is
-- dropped (spec 26.6).
--
-- Money is integer cents, percents integer basis points. All dates are
-- business dates (Section 11.1) — p_as_of null resolves through
-- business_today(store_id) in the item's journey store timezone.

-- ============================================================================
-- 1. Reason-code explanations (Section 10.6)
--    Server returns code + parameters + this default English explanation;
--    lib/sleepTrial/reasons.ts mirrors the same templates for the UI.
-- ============================================================================

create or replace function public.stv_eval_explain(p_code text, p_params jsonb)
returns text
language plpgsql
immutable
as $$
begin
  return case p_code
    when 'TRIAL_NOT_STARTED' then
      'The trial has not started — record the delivery or pickup first.'
    when 'TRIAL_STARTS_TOMORROW' then
      'Delivered today — Night 1 is '
      || coalesce(p_params ->> 'started_on', 'tomorrow') || '.'
    when 'TRIAL_CLOSED_EXCHANGED' then
      'This trial ended — the mattress was exchanged.'
    when 'TRIAL_CLOSED_RETURNED' then
      'This trial ended — the mattress was returned.'
    when 'TRIAL_CLOSED_COMPLETED' then
      'This trial completed its full length and closed.'
    when 'TRIAL_CLOSED_WARRANTY' then
      'This trial ended — the mattress was replaced under warranty.'
    when 'TRIAL_CLOSED_VOIDED' then
      'This trial was voided (the line was removed or the order cancelled).'
    when 'ACTION_IN_PROGRESS' then
      'An exchange or return is already in progress for this mattress.'
    when 'EXCHANGES_NOT_OFFERED' then
      'Exchanges are not part of this customer''s sleep trial policy.'
    when 'RETURNS_NOT_OFFERED' then
      'Returns are not part of this customer''s sleep trial policy.'
    when 'EXCHANGE_LIMIT_REACHED' then
      'The exchange limit was reached ('
      || coalesce(p_params ->> 'exchanges_used', '?') || ' of '
      || coalesce(p_params ->> 'exchanges_allowed', '?') || ' used).'
    when 'TRIAL_EXPIRED' then
      'The sleep trial ended ' || coalesce(p_params ->> 'end_date', '') || '.'
    when 'MINIMUM_NIGHTS_NOT_MET' then
      coalesce(p_params ->> 'action_label', 'Exchange') || ' eligible '
      || coalesce(p_params ->> 'eligible_on', '') || ' (after Night '
      || coalesce(p_params ->> 'minimum_nights', '?') || ')'
      || case when p_params ->> 'days_until' is not null
              then ' · ' || (p_params ->> 'days_until') || ' days'
              else '' end
      || '.'
    when 'FEE_WINDOW_PROHIBITED' then
      coalesce(p_params ->> 'action_label', 'This action')
      || ' is not allowed on Night ' || coalesce(p_params ->> 'night', '?')
      || ' (' || coalesce(p_params ->> 'window_label', 'this fee window') || ').'
    when 'FEE_WINDOW_NEEDS_APPROVAL' then
      coalesce(p_params ->> 'action_label', 'This action')
      || ' in this fee window requires approval.'
    when 'SLEEP_CONCERN_REQUIRED' then
      'A documented sleep concern is required before an exchange — '
      || 'log a sleep concern first.'
    when 'PROTECTOR_MISSING' then
      'No qualifying mattress protector on this order.'
    when 'PROTECTOR_RETURNED' then
      'The qualifying mattress protector was returned or refunded.'
    when 'RETURN_NEEDS_APPROVAL' then
      'Returns under this policy require approval.'
    when 'WITHIN_POLICY' then 'Within policy.'
    when 'EXCEPTION_APPLIED' then
      'An approved exception applies to this action.'
    when 'NO_TRIAL_CONDITION_RULE' then
      'No sleep trial: this item''s condition is excluded by policy.'
    when 'NO_TRIAL_NOT_ELIGIBLE_PRODUCT' then
      'No sleep trial: this product is not trial-eligible.'
    when 'MISSING_FEE_BASIS' then
      'Can''t determine eligibility — the sale price for this unit was not captured.'
    when 'MISSING_START_DATE' then
      'Can''t determine eligibility — the trial start date is missing.'
    when 'MISSING_POLICY_TERMS' then
      'Can''t determine eligibility — the bound policy terms are missing.'
    when 'MISSING_FEE_SCHEDULE' then
      'Can''t determine eligibility — the policy''s fee schedule is missing.'
    when 'MISSING_ITEM' then
      'Can''t determine eligibility — the trial item was not found.'
    when 'EVALUATION_ERROR' then
      'Can''t determine eligibility right now — '
      || coalesce(p_params ->> 'error', 'internal error')
    else coalesce(p_code, 'Unknown')
  end;
end;
$$;

revoke execute on function public.stv_eval_explain(text, jsonb)
  from public, anon, authenticated;

-- Shared terminal action block (PENDING / CLOSED / VOIDED / in-progress /
-- UNKNOWN) — both actions get the same result so the shape never varies.
create or replace function public.stv_eval_terminal(
  p_status text,
  p_code text,
  p_params jsonb default '{}'::jsonb
)
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'status', p_status,
    'reason_code', p_code,
    'explanation', public.stv_eval_explain(p_code, p_params),
    'fee', null,
    'requires_approval', false,
    'exception_available', false,
    'exception_type', null,
    'additional_blockers', '[]'::jsonb,
    'warnings', '[]'::jsonb,
    'applied_exception_id', null
  );
$$;

revoke execute on function public.stv_eval_terminal(text, text, jsonb)
  from public, anon, authenticated;

-- Failure contract (Section 10.5): UNKNOWN with a reason and only the two
-- always-safe UI actions. Never an uncaught exception, never "eligible".
create or replace function public.stv_eval_unknown_result(
  p_item_id uuid,
  p_journey_id uuid,
  p_code text,
  p_detail text
)
returns jsonb
language sql
stable
set search_path = public
as $$
  select jsonb_build_object(
    'trial_item_id', p_item_id,
    'journey_id', p_journey_id,
    'as_of', null,
    'display', jsonb_build_object(
      'night', null, 'length_nights', null, 'extension_nights', null,
      'started_on', null, 'eligible_on', null, 'end_date', null,
      'minimum_nights', null, 'minimum_met', false, 'ending_soon', false,
      'nights_remaining', null, 'days_until_eligible', null,
      'exchanges_used', null, 'exchanges_allowed', null),
    'item', null,
    'actions', jsonb_build_object(
      'EXCHANGE', public.stv_eval_terminal(
        'UNKNOWN', p_code, jsonb_build_object('error', p_detail)),
      'RETURN', public.stv_eval_terminal(
        'UNKNOWN', p_code, jsonb_build_object('error', p_detail))),
    'headline', jsonb_build_object(
      'status', 'UNKNOWN',
      'reason_code', p_code,
      'explanation', public.stv_eval_explain(
        p_code, jsonb_build_object('error', p_detail))),
    'allowed_ui_actions', '["ADD_NOTE","ADD_SLEEP_CONCERN"]'::jsonb,
    'policy', '{}'::jsonb,
    'evaluated_at', now()
  );
$$;

revoke execute on function public.stv_eval_unknown_result(uuid, uuid, text, text)
  from public, anon, authenticated;

-- ============================================================================
-- 2. Protector coverage (Section 12.2)
--    Deterministic greedy allocation across the journey's live trial items:
--    items sorted by started_on asc, fee_basis_cents desc, unit_index asc;
--    protector units sorted by size match first, then added_at asc. A PAIRED
--    split-king group with split_king_units = ONE consumes one unit total.
--    Products have no size attribute yet, so the size tiebreak compares the
--    item's size_snapshot against the protector's product/line name (no-op
--    until sizes are populated).
-- ============================================================================

create or replace function public.stv_eval_protector_coverage(
  p_item_id uuid,
  p_today date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_item public.sleep_trial_items%rowtype;
  v_prot jsonb;
  v_cats text[];
  v_prods text[];
  v_window int;
  v_pair_share boolean;
  v_ti record;
  v_unit record;
  v_used text[] := '{}';
  v_claimed_pairs uuid[] := '{}';
  v_assigned jsonb := '{}'::jsonb;
  v_entry jsonb;
begin
  select * into v_item from public.sleep_trial_items where id = p_item_id;
  if not found then
    return '{"covered":false,"label":null}'::jsonb;
  end if;

  v_prot := coalesce(v_item.resolved_terms -> 'protector', '{}'::jsonb);
  if not coalesce((v_prot ->> 'required')::boolean, false) then
    return '{"covered":true,"label":null,"required":false}'::jsonb;
  end if;

  select coalesce(array_agg(x), '{}') into v_cats
    from jsonb_array_elements_text(
      coalesce(v_prot -> 'qualifying_category_ids', '[]'::jsonb)) as x;
  select coalesce(array_agg(x), '{}') into v_prods
    from jsonb_array_elements_text(
      coalesce(v_prot -> 'qualifying_product_ids', '[]'::jsonb)) as x;
  v_window := coalesce((v_prot ->> 'purchase_window_days')::int, 0);
  v_pair_share := coalesce(v_item.resolved_terms #>> '{split_king,treatment}',
                           'INDEPENDENT') = 'PAIRED'
                  and coalesce(v_prot ->> 'split_king_units', 'ONE') = 'ONE';

  for v_ti in
    select i.id, i.pair_group_id, i.started_on, i.fee_basis_cents,
           i.unit_index, i.size_snapshot
    from public.sleep_trial_items i
    where i.journey_id = v_item.journey_id
      and i.status not in ('CLOSED','VOIDED')
    order by i.started_on asc nulls last,
             i.fee_basis_cents desc nulls last,
             i.unit_index asc
  loop
    -- PAIRED + split_king_units ONE: the first pair member's unit covers both.
    if v_pair_share
       and v_ti.pair_group_id is not null
       and v_ti.pair_group_id = any(v_claimed_pairs) then
      v_assigned := v_assigned || jsonb_build_object(
        v_ti.id::text,
        jsonb_build_object('covered', true, 'label', 'covered by pair'));
      continue;
    end if;

    select s.unit_key, s.name into v_unit
    from (
      select jli.id::text || ':' || u.n as unit_key,
             coalesce(p.item_name, jli.item_name) as name,
             jli.created_at as added_at
      from public.journey_line_items jli
      left join public.products p on p.id = jli.product_id
      cross join lateral generate_series(1, greatest(jli.quantity, 0)) as u(n)
      where jli.journey_id = v_item.journey_id
        and (p.id::text = any(v_prods) or p.category_id::text = any(v_cats))
        and (v_ti.started_on is null
             or jli.created_at::date <= v_ti.started_on + v_window)
    ) s
    where not (s.unit_key = any(v_used))
    order by case
               when v_ti.size_snapshot is not null
                    and lower(s.name) like '%' || lower(v_ti.size_snapshot) || '%'
                 then 0 else 1
             end,
             s.added_at asc
    limit 1;

    if v_unit.unit_key is null then
      v_assigned := v_assigned || jsonb_build_object(
        v_ti.id::text, jsonb_build_object('covered', false, 'label', null));
    else
      v_used := v_used || v_unit.unit_key;
      v_assigned := v_assigned || jsonb_build_object(
        v_ti.id::text,
        jsonb_build_object('covered', true, 'label', v_unit.name));
      if v_pair_share and v_ti.pair_group_id is not null then
        v_claimed_pairs := v_claimed_pairs || v_ti.pair_group_id;
      end if;
    end if;
  end loop;

  v_entry := v_assigned -> (v_item.id::text);
  return coalesce(v_entry, '{"covered":false,"label":null}'::jsonb)
         || '{"required":true}'::jsonb;
end;
$$;

revoke execute on function public.stv_eval_protector_coverage(uuid, date)
  from public, anon, authenticated;

-- ============================================================================
-- 3. stv_eval_action — Section 10.3 evaluation sequence for one action.
--    p_terms = resolved_terms + {"fee_schedules": {...}} merged by the caller.
--    Collects every blocker in fixed order; the first is the headline and the
--    rest become additional_blockers.
-- ============================================================================

create or replace function public.stv_eval_action(
  p_terms jsonb,
  p_facts jsonb,
  p_action text  -- 'EXCHANGE' | 'RETURN'
)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_today   date := (p_facts ->> 'today')::date;
  v_started date := (p_facts ->> 'started_on')::date;
  v_trial   jsonb := coalesce(p_terms -> 'trial', '{}'::jsonb);
  v_x       jsonb := coalesce(p_terms -> 'exchange', '{}'::jsonb);
  v_r       jsonb := coalesce(p_terms -> 'return', '{}'::jsonb);
  v_fees    jsonb := coalesce(p_terms -> 'fees', '{}'::jsonb);
  v_prot    jsonb := coalesce(p_terms -> 'protector', '{}'::jsonb);
  v_scheds  jsonb := coalesce(p_terms -> 'fee_schedules', '{}'::jsonb);
  v_min_x   int := coalesce((v_trial ->> 'minimum_nights')::int, 0);
  v_min     int;
  v_elig    date;
  v_end     date;
  v_ext     int := coalesce((p_facts ->> 'extension_nights')::int, 0);
  v_len     int := coalesce((v_trial ->> 'length_nights')::int, 0);
  v_night   int := v_today - v_started + 1;
  v_used    int := coalesce((p_facts ->> 'exchanges_used')::int, 0);
  v_max     int := coalesce((v_x ->> 'max_count')::int, 1);
  v_basis   int := nullif(p_facts ->> 'fee_basis_cents', '')::int;
  v_concern_ok  boolean := coalesce((p_facts ->> 'concern_ok')::boolean, false);
  v_concern_any boolean := coalesce((p_facts ->> 'concern_documented')::boolean, false);
  v_prot_cov    boolean := coalesce(p_facts #> '{protector,covered}', 'false'::jsonb)::boolean;
  v_appr    uuid := nullif(p_facts ->> 'approved_exception_id', '')::uuid;
  v_lbl     text := case when p_action = 'EXCHANGE' then 'Exchange' else 'Return' end;
  v_applies text := coalesce(v_prot ->> 'applies_to', 'EXCHANGE_AND_RETURN');
  v_mbid    text := coalesce(v_prot ->> 'missing_behavior', 'BLOCK_WITH_OVERRIDE');
  v_blockers jsonb := '[]'::jsonb;
  v_warnings jsonb := '[]'::jsonb;
  v_fee     jsonb;
  v_key     text;
  v_windows jsonb;
  v_win     jsonb;
  v_widx    int;
  v_next    jsonb;
  v_win_outcome text;
  v_win_label   text;
  v_pct int; v_flat int; v_minc int; v_maxc int;
  v_raw bigint; v_amt bigint;
  v_head  jsonb;
  v_params jsonb;
  v_status text; v_reason text;
  v_exc_avail boolean := false;
  v_exc_type text;
  v_applied uuid;
begin
  -- Return minimum may differ from the exchange minimum (Section 11.4).
  v_min := case
    when p_action = 'RETURN'
         and coalesce(v_r ->> 'minimum_nights', 'SAME_AS_EXCHANGE') ~ '^[0-9]+$'
      then (v_r ->> 'minimum_nights')::int
    else v_min_x end;
  v_elig := v_started + v_min;
  v_end := v_started + v_len + v_ext;

  -- 2. Action enabled by policy
  if p_action = 'EXCHANGE'
     and not coalesce((v_x ->> 'allowed')::boolean, true) then
    v_blockers := v_blockers || jsonb_build_object(
      'status', 'NOT_ELIGIBLE', 'reason_code', 'EXCHANGES_NOT_OFFERED',
      'exception_available', false, 'exception_type', null);
  elsif p_action = 'RETURN'
     and not coalesce((v_r ->> 'allowed')::boolean, false) then
    v_blockers := v_blockers || jsonb_build_object(
      'status', 'NOT_ELIGIBLE', 'reason_code', 'RETURNS_NOT_OFFERED',
      'exception_available',
        coalesce((v_r ->> 'exception_allowed')::boolean, false),
      'exception_type', 'RETURN_NOT_ALLOWED');
  end if;

  -- 3. Exchange count (pair shares the count when PAIRED — counted upstream)
  if p_action = 'EXCHANGE' and v_used >= v_max then
    v_blockers := v_blockers || jsonb_build_object(
      'status', 'NOT_ELIGIBLE', 'reason_code', 'EXCHANGE_LIMIT_REACHED',
      'exception_available', true, 'exception_type', 'EXTRA_EXCHANGE',
      'params', jsonb_build_object(
        'exchanges_used', v_used, 'exchanges_allowed', v_max));
  end if;

  -- 4. Trial window
  if v_today > v_end then
    v_blockers := v_blockers || jsonb_build_object(
      'status', 'EXPIRED', 'reason_code', 'TRIAL_EXPIRED',
      'exception_available', case when p_action = 'EXCHANGE'
        then coalesce((v_x ->> 'expired_exception_allowed')::boolean, false)
        else coalesce((v_r ->> 'exception_allowed')::boolean, false) end,
      'exception_type', case when p_action = 'EXCHANGE'
        then 'EXPIRED_EXCHANGE' else 'EXPIRED_RETURN' end,
      'params', jsonb_build_object('end_date', v_end));
  elsif v_today < v_elig then
    v_blockers := v_blockers || jsonb_build_object(
      'status', 'NOT_YET_ELIGIBLE', 'reason_code', 'MINIMUM_NIGHTS_NOT_MET',
      'exception_available', p_action = 'EXCHANGE'
        and coalesce((v_x ->> 'early_exception_allowed')::boolean, false),
      'exception_type', case when p_action = 'EXCHANGE'
        then 'EARLY_EXCHANGE' end,
      'params', jsonb_build_object(
        'action_label', v_lbl, 'eligible_on', v_elig,
        'minimum_nights', v_min, 'days_until', v_elig - v_today));
  end if;

  -- 5. Fee window (Section 13). PROHIBITED blocks here; APPROVAL_REQUIRED is
  --    deferred to the approval-gate step (Section 10.3 ordering).
  v_key := case when p_action = 'EXCHANGE'
                then v_fees ->> 'exchange_schedule'
                else v_fees ->> 'return_schedule' end;
  if v_basis is null then
    v_blockers := v_blockers || jsonb_build_object(
      'status', 'UNKNOWN', 'reason_code', 'MISSING_FEE_BASIS',
      'exception_available', false, 'exception_type', null);
  else
    v_windows := v_scheds -> v_key -> 'windows';
    if v_key is null or jsonb_typeof(v_windows) <> 'array'
       or jsonb_array_length(v_windows) = 0 then
      v_blockers := v_blockers || jsonb_build_object(
        'status', 'UNKNOWN', 'reason_code', 'MISSING_FEE_SCHEDULE',
        'exception_available', false, 'exception_type', null);
    else
      select w.val, w.idx into v_win, v_widx
      from jsonb_array_elements(v_windows) with ordinality as w(val, idx)
      where v_night >= (w.val ->> 'from_night')::int
        and (w.val ->> 'to_night' is null
             or v_night <= (w.val ->> 'to_night')::int)
      order by w.idx
      limit 1;
      if v_win is null then
        -- Nights beyond length_nights use the last (open-ended) window.
        select w.val, w.idx into v_win, v_widx
        from jsonb_array_elements(v_windows) with ordinality as w(val, idx)
        order by w.idx desc
        limit 1;
      end if;
      select w.val into v_next
      from jsonb_array_elements(v_windows) with ordinality as w(val, idx)
      where w.idx = v_widx + 1;

      v_win_outcome := coalesce(v_win ->> 'outcome', 'ALLOWED');
      v_win_label := 'Nights ' || (v_win ->> 'from_night') || ' to '
                     || coalesce(v_win ->> 'to_night', 'end');

      if v_win_outcome = 'PROHIBITED' then
        v_blockers := v_blockers || jsonb_build_object(
          'status', 'NOT_ELIGIBLE', 'reason_code', 'FEE_WINDOW_PROHIBITED',
          'exception_available', p_action = 'EXCHANGE'
            and coalesce((v_x ->> 'early_exception_allowed')::boolean, false),
          'exception_type', case when p_action = 'EXCHANGE'
            then 'EARLY_EXCHANGE' end,
          'params', jsonb_build_object(
            'action_label', v_lbl, 'night', v_night,
            'window_label', v_win_label));
      else
        v_pct  := coalesce((v_win ->> 'percent_bp')::int, 0);
        v_flat := coalesce((v_win ->> 'flat_cents')::int, 0);
        v_minc := nullif(v_win ->> 'min_cents', '')::int;
        v_maxc := nullif(v_win ->> 'max_cents', '')::int;
        -- round_half_up(basis * bp / 10000) + flat; all-integer math.
        v_raw := (v_basis::bigint * v_pct + 5000) / 10000 + v_flat;
        if v_minc is not null then v_raw := greatest(v_raw, v_minc); end if;
        if v_maxc is not null then v_raw := least(v_raw, v_maxc); end if;
        v_amt := least(v_raw, v_basis);  -- fee never exceeds the credit
        v_fee := jsonb_build_object(
          'window', jsonb_build_object(
            'from_night', (v_win ->> 'from_night')::int,
            'to_night', (v_win ->> 'to_night')::int,
            'label', v_win_label,
            'outcome', v_win_outcome),
          'percent_bp', v_pct,
          'flat_cents', v_flat,
          'basis_cents', v_basis,
          'basis_label', 'Returned mattress price',
          'amount_cents', v_amt,
          'min_cents', v_minc,
          'max_cents', v_maxc,
          'schedule_key', v_key,
          'next_change', case when v_next is null then null
            else jsonb_build_object(
              'on', v_started + (v_next ->> 'from_night')::int - 1,
              'to_percent_bp', coalesce((v_next ->> 'percent_bp')::int, 0),
              'to_flat_cents', coalesce((v_next ->> 'flat_cents')::int, 0))
            end);
      end if;
    end if;
  end if;

  -- 6. Documentation requirement (exchange only)
  if p_action = 'EXCHANGE'
     and coalesce((v_x ->> 'require_concern')::boolean, false)
     and not v_concern_ok then
    v_blockers := v_blockers || jsonb_build_object(
      'status', 'BLOCKED', 'reason_code', 'SLEEP_CONCERN_REQUIRED',
      'exception_available', false, 'exception_type', null,
      'params', jsonb_build_object('has_concern', v_concern_any));
  end if;

  -- 7. Protector (Section 12)
  if coalesce((v_prot ->> 'required')::boolean, false)
     and (v_applies = 'EXCHANGE_AND_RETURN'
          or (v_applies = 'EXCHANGE_ONLY' and p_action = 'EXCHANGE')
          or (v_applies = 'RETURN_ONLY' and p_action = 'RETURN'))
     and not v_prot_cov then
    if v_mbid = 'WARN_ONLY' then
      v_warnings := v_warnings || '"PROTECTOR_MISSING"'::jsonb;
    else
      v_blockers := v_blockers || jsonb_build_object(
        'status', case when v_mbid = 'APPROVAL_REQUIRED'
                       then 'APPROVAL_REQUIRED' else 'BLOCKED' end,
        'reason_code', 'PROTECTOR_MISSING',
        'exception_available', true,
        'exception_type', 'PROTECTOR_OVERRIDE');
    end if;
  end if;

  -- 8. Approval gates
  if p_action = 'RETURN'
     and coalesce((v_r ->> 'approval_required')::boolean, false) then
    v_blockers := v_blockers || jsonb_build_object(
      'status', 'APPROVAL_REQUIRED', 'reason_code', 'RETURN_NEEDS_APPROVAL',
      'exception_available', true, 'exception_type', 'RETURN_APPROVAL');
  end if;
  if v_win_outcome = 'APPROVAL_REQUIRED' then
    v_blockers := v_blockers || jsonb_build_object(
      'status', 'APPROVAL_REQUIRED', 'reason_code', 'FEE_WINDOW_NEEDS_APPROVAL',
      'exception_available', true, 'exception_type', null,
      'params', jsonb_build_object(
        'action_label', v_lbl, 'window_label', v_win_label));
  end if;

  -- 9. Approved exception: unblocks exactly the blocker it covers (existing
  --    sleep_trial_exception_requests are journey-scoped 'early_exchange'
  --    approvals — they cover EXCHANGE's minimum/prohibited-window blocks).
  v_params := jsonb_build_object(
    'action_label', v_lbl, 'eligible_on', v_elig, 'end_date', v_end,
    'night', v_night, 'minimum_nights', v_min,
    'exchanges_used', v_used, 'exchanges_allowed', v_max);

  if jsonb_array_length(v_blockers) = 0 then
    v_status := 'ELIGIBLE';
    v_reason := 'WITHIN_POLICY';
  else
    v_head := v_blockers -> 0;
    if v_appr is not null
       and p_action = 'EXCHANGE'
       and v_head ->> 'reason_code' in (
         'MINIMUM_NIGHTS_NOT_MET', 'FEE_WINDOW_PROHIBITED') then
      -- Exception consumed its blocker; whatever is next takes over.
      v_applied := v_appr;
      v_warnings := v_warnings || '"EXCEPTION_APPLIED"'::jsonb;
      select coalesce(jsonb_agg(b.val order by b.idx), '[]'::jsonb)
      into v_blockers
      from jsonb_array_elements(v_blockers) with ordinality as b(val, idx)
      where b.idx > 1;
      if jsonb_array_length(v_blockers) = 0 then
        v_status := 'ELIGIBLE';
        v_reason := 'EXCEPTION_APPLIED';
      else
        v_head := v_blockers -> 0;
        v_status := v_head ->> 'status';
        v_reason := v_head ->> 'reason_code';
        v_exc_avail := coalesce((v_head ->> 'exception_available')::boolean, false);
        v_exc_type := v_head ->> 'exception_type';
      end if;
    else
      v_status := v_head ->> 'status';
      v_reason := v_head ->> 'reason_code';
      v_exc_avail := coalesce((v_head ->> 'exception_available')::boolean, false);
      v_exc_type := v_head ->> 'exception_type';
    end if;
  end if;

  return jsonb_build_object(
    'status', v_status,
    'reason_code', v_reason,
    'explanation',
      public.stv_eval_explain(v_reason, v_params || coalesce(v_head -> 'params', '{}'::jsonb))
      || case
           when v_status = 'ELIGIBLE' and v_fee is not null
                and coalesce((v_fee ->> 'amount_cents')::int, 0) > 0
             then ' ' || to_char((v_fee ->> 'percent_bp')::numeric / 100, 'FM99990.##')
                  || '% fee applies (' || (v_fee #>> '{window,label}') || ').'
           else '' end,
    'fee', v_fee,
    'requires_approval', v_status = 'APPROVAL_REQUIRED',
    'exception_available', v_exc_avail,
    'exception_type', v_exc_type,
    'additional_blockers', (
      select coalesce(jsonb_agg(jsonb_build_object(
          'status', b.val ->> 'status',
          'reason_code', b.val ->> 'reason_code',
          'explanation', public.stv_eval_explain(
            b.val ->> 'reason_code',
            v_params || coalesce(b.val -> 'params', '{}'::jsonb)))
          order by b.idx), '[]'::jsonb)
      from jsonb_array_elements(v_blockers) with ordinality as b(val, idx)
      where b.idx > 1),
    'warnings', v_warnings,
    'applied_exception_id', v_applied,
    'applied_for_reason', case when v_reason = 'EXCEPTION_APPLIED'
                               then v_head ->> 'reason_code' end);
end;
$$;

revoke execute on function public.stv_eval_action(jsonb, jsonb, text)
  from public, anon, authenticated;

-- ============================================================================
-- 4. stv_eval_inner — shared inner function (Section 10.1). Pure over
--    (resolved_terms + fee_schedules, facts); called by every wrapper so
--    production and any future simulator can never drift.
-- ============================================================================

create or replace function public.stv_eval_inner(
  p_terms jsonb,
  p_facts jsonb
)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_status  text := p_facts ->> 'item_status';
  v_close   text := p_facts ->> 'close_reason';
  v_today   date := (p_facts ->> 'today')::date;
  v_started date := nullif(p_facts ->> 'started_on', '')::date;
  v_trial   jsonb := coalesce(p_terms -> 'trial', '{}'::jsonb);
  v_x_t     jsonb := coalesce(p_terms -> 'exchange', '{}'::jsonb);
  v_ext     int := coalesce((p_facts ->> 'extension_nights')::int, 0);
  v_len     int := coalesce((v_trial ->> 'length_nights')::int, 0);
  v_min     int := coalesce((v_trial ->> 'minimum_nights')::int, 0);
  v_max     int := coalesce((v_x_t ->> 'max_count')::int, 1);
  v_esd     int := coalesce((v_trial ->> 'ending_soon_days')::int, 14);
  v_used    int := coalesce((p_facts ->> 'exchanges_used')::int, 0);
  v_elig    date;
  v_end     date;
  v_night   int;
  v_display jsonb;
  v_shared  jsonb;
  v_shared_code text;
  v_x_res   jsonb;
  v_r_res   jsonb;
  v_head    jsonb;
  v_ui      text[] := '{}';
  v_perms   jsonb := coalesce(p_facts -> 'perms', '{}'::jsonb);
  v_pend    uuid := nullif(p_facts ->> 'pending_exception_id', '')::uuid;
  v_prot_bhv text;
begin
  -- Display facts, always (Section 10.3 step 0 / 11.1).
  if v_started is not null then
    v_night := v_today - v_started + 1;
    v_elig := v_started + v_min;
    v_end := v_started + v_len + v_ext;
    v_display := jsonb_build_object(
      'night', v_night,
      'length_nights', v_len,
      'extension_nights', v_ext,
      'started_on', v_started,
      'eligible_on', v_elig,
      'end_date', v_end,
      'minimum_nights', v_min,
      'minimum_met', v_today >= v_elig,
      'ending_soon', v_today <= v_end and (v_end - v_today) <= v_esd,
      'nights_remaining', greatest(v_end - v_today, 0),
      'days_until_eligible', greatest(v_elig - v_today, 0),
      'exchanges_used', v_used,
      'exchanges_allowed', v_max);
  else
    v_display := jsonb_build_object(
      'night', null, 'length_nights', v_len, 'extension_nights', v_ext,
      'started_on', null, 'eligible_on', null, 'end_date', null,
      'minimum_nights', v_min, 'minimum_met', false, 'ending_soon', false,
      'nights_remaining', null, 'days_until_eligible', null,
      'exchanges_used', v_used, 'exchanges_allowed', v_max);
  end if;

  -- Terminal / short-circuit states (Section 10.3 step 1).
  if v_status = 'PENDING_FULFILLMENT' then
    v_shared_code := 'TRIAL_NOT_STARTED';
    v_shared := public.stv_eval_terminal('PENDING', v_shared_code);
  elsif v_status = 'VOIDED' then
    v_shared_code := 'TRIAL_CLOSED_VOIDED';
    v_shared := public.stv_eval_terminal('NOT_ELIGIBLE', v_shared_code);
  elsif v_status = 'CLOSED' then
    v_shared_code := 'TRIAL_CLOSED_' || coalesce(v_close, 'COMPLETED');
    v_shared := public.stv_eval_terminal('NOT_ELIGIBLE', v_shared_code);
  elsif v_status in ('EXCHANGE_IN_PROGRESS', 'RETURN_IN_PROGRESS')
        or coalesce((p_facts ->> 'pair_open_action')::boolean, false) then
    v_shared_code := 'ACTION_IN_PROGRESS';
    v_shared := public.stv_eval_terminal('BLOCKED', v_shared_code);
  elsif p_terms is null or p_terms -> 'trial' is null then
    v_shared_code := 'MISSING_POLICY_TERMS';
    v_shared := public.stv_eval_terminal('UNKNOWN', v_shared_code);
  elsif v_started is null then
    v_shared_code := 'MISSING_START_DATE';
    v_shared := public.stv_eval_terminal('UNKNOWN', v_shared_code);
  elsif v_started > v_today then
    -- Delivered today with DAY_AFTER_FULFILLMENT counting (Section 11.1).
    v_shared_code := 'TRIAL_STARTS_TOMORROW';
    v_shared := public.stv_eval_terminal(
      'PENDING', v_shared_code, jsonb_build_object('started_on', v_started));
  end if;

  if v_shared is not null then
    v_x_res := v_shared;
    v_r_res := v_shared;
    v_ui := case v_shared_code
      when 'TRIAL_NOT_STARTED' then array['ADD_NOTE']
      when 'TRIAL_STARTS_TOMORROW' then array['ADD_NOTE']
      when 'ACTION_IN_PROGRESS' then array[
        case when v_status = 'RETURN_IN_PROGRESS'
             then 'VIEW_RETURN' else 'VIEW_EXCHANGE' end,
        'ADD_NOTE']
      when 'MISSING_POLICY_TERMS' then array['ADD_NOTE','ADD_SLEEP_CONCERN']
      when 'MISSING_START_DATE' then array['ADD_NOTE','ADD_SLEEP_CONCERN']
      else array['VIEW_HISTORY','ADD_NOTE']
    end;
  else
    v_x_res := public.stv_eval_action(p_terms, p_facts, 'EXCHANGE');
    v_r_res := public.stv_eval_action(p_terms, p_facts, 'RETURN');

    -- allowed_ui_actions (Section 20): policy AND the caller's permissions.
    if v_x_res ->> 'status' = 'ELIGIBLE'
       and coalesce((v_perms ->> 'can_exchange')::boolean, false) then
      v_ui := v_ui || 'START_EXCHANGE';
    end if;
    if v_r_res ->> 'status' = 'ELIGIBLE'
       and coalesce((v_perms ->> 'can_return')::boolean, false) then
      v_ui := v_ui || 'START_RETURN';
    end if;
    if coalesce((v_perms ->> 'can_concern')::boolean, false) then
      v_ui := v_ui || 'ADD_SLEEP_CONCERN';
    end if;
    v_ui := v_ui || 'SCHEDULE_FOLLOW_UP';

    if v_pend is not null then
      v_ui := v_ui || 'VIEW_EXCEPTION_REQUEST';
    elsif coalesce((v_perms ->> 'can_request')::boolean, false)
          or coalesce((v_perms ->> 'can_override_protector')::boolean, false) then
      if v_x_res ->> 'reason_code' in ('MINIMUM_NIGHTS_NOT_MET','FEE_WINDOW_PROHIBITED')
         and coalesce((v_x_res ->> 'exception_available')::boolean, false)
         and coalesce((v_perms ->> 'can_request')::boolean, false) then
        v_ui := v_ui || 'REQUEST_EARLY_EXCHANGE_EXCEPTION';
      end if;
      if v_x_res ->> 'reason_code' = 'EXCHANGE_LIMIT_REACHED'
         and coalesce((v_perms ->> 'can_request')::boolean, false) then
        v_ui := v_ui || 'REQUEST_EXTRA_EXCHANGE_EXCEPTION';
      end if;
      if v_x_res ->> 'reason_code' = 'TRIAL_EXPIRED'
         and coalesce((v_x_res ->> 'exception_available')::boolean, false)
         and coalesce((v_perms ->> 'can_request')::boolean, false) then
        v_ui := v_ui || 'REQUEST_EXPIRED_TRIAL_EXCEPTION';
      end if;
      if v_r_res ->> 'reason_code' = 'RETURNS_NOT_OFFERED'
         and coalesce((v_r_res ->> 'exception_available')::boolean, false)
         and coalesce((v_perms ->> 'can_request')::boolean, false) then
        v_ui := v_ui || 'REQUEST_RETURN_EXCEPTION';
      end if;
      if v_r_res ->> 'reason_code' = 'TRIAL_EXPIRED'
         and coalesce((v_r_res ->> 'exception_available')::boolean, false)
         and coalesce((v_perms ->> 'can_request')::boolean, false) then
        v_ui := v_ui || 'REQUEST_EXPIRED_RETURN_EXCEPTION';
      end if;
      if v_r_res ->> 'status' = 'APPROVAL_REQUIRED'
         and coalesce((v_perms ->> 'can_request')::boolean, false) then
        v_ui := v_ui || 'REQUEST_RETURN_APPROVAL';
      end if;
      v_prot_bhv := coalesce(p_terms #>> '{protector,missing_behavior}',
                             'BLOCK_WITH_OVERRIDE');
      if v_x_res ->> 'reason_code' = 'PROTECTOR_MISSING' then
        if v_prot_bhv = 'BLOCK_WITH_OVERRIDE'
           and coalesce((v_perms ->> 'can_override_protector')::boolean, false) then
          v_ui := v_ui || 'OVERRIDE_PROTECTOR_REQUIREMENT';
        elsif v_prot_bhv = 'APPROVAL_REQUIRED'
              and coalesce((v_perms ->> 'can_request')::boolean, false) then
          v_ui := v_ui || 'REQUEST_PROTECTOR_EXCEPTION';
        end if;
      end if;
      if coalesce((v_perms ->> 'can_request')::boolean, false)
         and coalesce((v_x_res #> '{fee,amount_cents}')::text::int, 0) > 0 then
        v_ui := v_ui || 'REQUEST_FEE_WAIVER';
      end if;
      if coalesce((v_perms ->> 'can_request')::boolean, false)
         and coalesce((v_trial ->> 'extensions_allowed')::boolean, false) then
        v_ui := v_ui || 'EXTEND_TRIAL_REQUEST';
      end if;
    end if;
    v_ui := v_ui || 'ADD_NOTE';
  end if;

  -- Headline: the exchange result when the policy offers exchanges, else
  -- the return result (Section 10.3 — first blocker is the headline).
  if coalesce((v_x_t ->> 'allowed')::boolean, true) then
    v_head := v_x_res;
  else
    v_head := v_r_res;
  end if;

  return jsonb_build_object(
    'trial_item_id', p_facts ->> 'item_id',
    'journey_id', p_facts ->> 'journey_id',
    'as_of', v_today,
    'display', v_display,
    'item', jsonb_build_object(
      'status', v_status,
      'product_name', p_facts ->> 'product_name',
      'brand', p_facts ->> 'brand',
      'size', p_facts ->> 'size',
      'unit_index', p_facts ->> 'unit_index',
      'bound_reason', p_facts ->> 'bound_reason',
      'fee_basis_cents', p_facts ->> 'fee_basis_cents',
      'has_open_concern', coalesce((p_facts ->> 'has_open_concern')::boolean, false),
      'pending_exception_id', p_facts ->> 'pending_exception_id'),
    'actions', jsonb_build_object('EXCHANGE', v_x_res, 'RETURN', v_r_res),
    'headline', jsonb_build_object(
      'status', v_head ->> 'status',
      'reason_code', v_head ->> 'reason_code',
      'explanation', v_head ->> 'explanation'),
    'allowed_ui_actions', to_jsonb(v_ui),
    'policy', jsonb_build_object(
      'policy_version_id', p_facts ->> 'policy_version_id',
      'version_label', p_facts ->> 'version_label',
      'term_sources', coalesce(p_facts -> 'term_sources', '{}'::jsonb)),
    'evaluated_at', now());
end;
$$;

revoke execute on function public.stv_eval_inner(jsonb, jsonb)
  from public, anon, authenticated;

-- ============================================================================
-- 5. stv_eval_one — gather Section 10.2 facts for one stored item and run the
--    shared inner function. Internal; the public wrappers add the tenant
--    check and the UNKNOWN failure contract.
-- ============================================================================

create or replace function public.stv_eval_one(
  p_item_id uuid,
  p_today date
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_item public.sleep_trial_items%rowtype;
  v_store uuid;
  v_today date;
  v_pv record;
  v_terms jsonb;
  v_paired boolean;
  v_used int;
  v_pair_open boolean := false;
  v_pend uuid;
  v_appr uuid;
  v_age int;
  v_oldest date;
  v_open_concern boolean;
  v_prot jsonb;
  v_perms jsonb;
  v_label text;
  v_facts jsonb;
begin
  select * into v_item from public.sleep_trial_items where id = p_item_id;
  if not found then
    return public.stv_eval_unknown_result(
      p_item_id, null, 'MISSING_ITEM', 'trial item not found');
  end if;

  select sj.store_id into v_store
  from public.sleep_journeys sj
  where sj.id = v_item.journey_id;

  v_today := coalesce(
    p_today,
    public.business_today(v_store),
    (now() at time zone 'UTC')::date);

  select pv.id, pv.version_number, pv.published_at, pv.definition
  into v_pv
  from public.policy_versions pv
  where pv.id = v_item.policy_version_id;

  -- resolved_terms holds only `base`; the fee schedule windows live next to
  -- it in the same immutable definition, so merge them in for the inner fn.
  v_terms := coalesce(v_item.resolved_terms, '{}'::jsonb)
    || jsonb_build_object(
         'fee_schedules',
         coalesce(v_pv.definition -> 'fee_schedules', '{}'::jsonb));

  v_paired := v_item.pair_group_id is not null
    and coalesce(v_terms #>> '{split_king,treatment}', 'INDEPENDENT') = 'PAIRED';

  -- Exchange count: closed-as-EXCHANGED ancestors in this lineage (plus the
  -- pair's lineages when PAIRED — Section 9.2).
  select count(*) into v_used
  from public.sleep_trial_items si
  where si.close_reason = 'EXCHANGED'
    and (si.lineage_root_id = v_item.lineage_root_id
         or (v_paired and si.pair_group_id = v_item.pair_group_id));

  if v_paired then
    v_pair_open := exists (
      select 1 from public.sleep_trial_items si
      where si.pair_group_id = v_item.pair_group_id
        and si.id <> v_item.id
        and si.status in ('EXCHANGE_IN_PROGRESS','RETURN_IN_PROGRESS'));
  end if;

  -- Existing exception table, read as-is (ST-6 replaces it): journey-scoped
  -- 'early_exchange' requests only.
  select r.id into v_pend
  from public.sleep_trial_exception_requests r
  where r.journey_id = v_item.journey_id
    and r.status = 'pending'
    and (r.expires_at is null or r.expires_at > now())
  order by r.requested_at desc
  limit 1;

  select r.id into v_appr
  from public.sleep_trial_exception_requests r
  where r.journey_id = v_item.journey_id
    and r.status = 'approved'
    and (r.expires_at is null or r.expires_at > now())
  order by r.decided_at desc
  limit 1;

  -- Documentation requirement: any concern linked to this item, plus
  -- unlinked journey-level concerns (they predate item linking).
  v_age := coalesce(
    (v_terms #>> '{exchange,require_concern_age_days}')::int, 0);
  select min(sc.opened_at)::date into v_oldest
  from public.sleep_concerns sc
  where sc.journey_id = v_item.journey_id
    and (sc.trial_item_id = v_item.id or sc.trial_item_id is null);
  v_open_concern := exists (
    select 1 from public.sleep_concerns sc
    where sc.journey_id = v_item.journey_id
      and (sc.trial_item_id = v_item.id or sc.trial_item_id is null)
      and sc.status in ('open','monitoring','escalated'));

  v_prot := public.stv_eval_protector_coverage(v_item.id, v_today);

  v_perms := jsonb_build_object(
    'can_exchange', public.has_permission('sleep_trial.start_exchange'),
    'can_return', public.has_permission('sleep_trial.start_return'),
    'can_request', public.has_permission('sleep_trial.request_exceptions'),
    'can_override_protector',
      public.has_permission('sleep_trial.override_protector'),
    'can_concern', public.has_permission('sleep_trial.manage_concerns'));

  v_label := case
    when v_pv.id is null then 'Unbound'
    when v_pv.version_number = 0 then 'Version 0 (Legacy)'
    else 'Version ' || v_pv.version_number
         || coalesce(' (' || to_char(v_pv.published_at, 'Mon DD, YYYY') || ')', '')
  end;

  v_facts := jsonb_build_object(
    'item_id', v_item.id,
    'journey_id', v_item.journey_id,
    'item_status', v_item.status,
    'close_reason', v_item.close_reason,
    'started_on', v_item.started_on,
    'today', v_today,
    'fee_basis_cents', v_item.fee_basis_cents,
    'extension_nights', 0,
    'exchanges_used', v_used,
    'pair_open_action', v_pair_open,
    'concern_documented', v_oldest is not null,
    'concern_ok', v_oldest is not null and (v_oldest + v_age) <= v_today,
    'has_open_concern', v_open_concern,
    'protector', v_prot,
    'pending_exception_id', v_pend,
    'approved_exception_id', v_appr,
    'perms', v_perms,
    'policy_version_id', v_item.policy_version_id,
    'version_label', v_label,
    'term_sources', coalesce(v_item.term_sources, '{}'::jsonb),
    'product_name', v_item.product_name_snapshot,
    'brand', v_item.brand_snapshot,
    'size', v_item.size_snapshot,
    'unit_index', v_item.unit_index,
    'bound_reason', v_item.bound_reason);

  return public.stv_eval_inner(v_terms, v_facts);
end;
$$;

revoke execute on function public.stv_eval_one(uuid, date)
  from public, anon, authenticated;

-- ============================================================================
-- 6. Public wrappers (Section 10.1) — security definer, stable, tenant-scoped
--    via is_journey_visible. Any internal error returns UNKNOWN, never an
--    uncaught exception and never "eligible".
-- ============================================================================

create or replace function public.evaluate_sleep_trial_item(
  p_trial_item_id uuid,
  p_as_of date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_journey uuid;
begin
  select i.journey_id into v_journey
  from public.sleep_trial_items i
  where i.id = p_trial_item_id;

  if v_journey is null then
    return public.stv_eval_unknown_result(
      p_trial_item_id, null, 'MISSING_ITEM', 'trial item not found');
  end if;
  if not public.is_journey_visible(v_journey) then
    return public.stv_eval_unknown_result(
      p_trial_item_id, v_journey, 'EVALUATION_ERROR',
      'not authorized for this journey');
  end if;

  return public.stv_eval_one(p_trial_item_id, p_as_of);
exception when others then
  return public.stv_eval_unknown_result(
    p_trial_item_id, v_journey, 'EVALUATION_ERROR', sqlerrm);
end;
$$;

grant execute on function public.evaluate_sleep_trial_item(uuid, date)
  to authenticated;

create or replace function public.evaluate_sleep_trial_items(
  p_journey_ids uuid[],
  p_as_of date default null
)
returns setof jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_item record;
begin
  for v_item in
    select i.id, i.journey_id
    from public.sleep_trial_items i
    where i.journey_id = any(p_journey_ids)
      and public.is_journey_visible(i.journey_id)
    order by i.journey_id, i.unit_index
  loop
    begin
      return next public.stv_eval_one(v_item.id, p_as_of);
    exception when others then
      return next public.stv_eval_unknown_result(
        v_item.id, v_item.journey_id, 'EVALUATION_ERROR', sqlerrm);
    end;
  end loop;
end;
$$;

grant execute on function public.evaluate_sleep_trial_items(uuid[], date)
  to authenticated;

-- ============================================================================
-- 7. Switch existing exception RPCs to the evaluator (spec 26.6)
-- ============================================================================

-- request_concern_exchange: "customer wants an exchange" is allowed when the
-- evaluator says EXCHANGE is ELIGIBLE — an approved exception already flips
-- the result to ELIGIBLE inside the evaluator, so the separate exception
-- check disappears.
create or replace function public.request_concern_exchange(p_concern_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_concern public.sleep_concerns%rowtype;
  v_employee_id uuid;
  v_item_id uuid;
  v_eval jsonb;
  v_x jsonb;
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

  -- The concern's linked item, else the journey's earliest-started live item.
  v_item_id := v_concern.trial_item_id;
  if v_item_id is null then
    select i.id into v_item_id
    from public.sleep_trial_items i
    where i.journey_id = v_concern.journey_id
      and i.status not in ('CLOSED','VOIDED')
    order by i.started_on asc nulls last, i.unit_index asc
    limit 1;
  end if;
  if v_item_id is null then
    raise exception 'This order has no sleep trial item to exchange';
  end if;

  v_eval := public.stv_eval_one(v_item_id, null);
  v_x := v_eval #> '{actions,EXCHANGE}';
  if coalesce(v_x ->> 'status', 'UNKNOWN') <> 'ELIGIBLE' then
    raise exception '%', coalesce(
      v_x ->> 'explanation',
      'This trial is not eligible for exchange.');
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

-- request_sleep_trial_exception (early exchange): pick the item the request
-- belongs to — the concern's linked item first — and take the evaluator's
-- word for whether an exception is actually needed.
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
  v_request_id uuid;
  v_item record;
  v_eval jsonb;
  v_x jsonb;
  v_first_x jsonb;
  v_any boolean := false;
  v_target uuid;
  v_night int;
  v_elig date;
  v_today date;
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

  -- Persisted lazy expiry (unchanged from 060).
  update public.sleep_trial_exception_requests
  set status = 'expired'
  where journey_id = p_journey_id
    and status = 'pending'
    and expires_at is not null
    and expires_at <= now();

  select public.business_today(sj.store_id) into v_today
  from public.sleep_journeys sj where sj.id = p_journey_id;
  v_today := coalesce(v_today, (now() at time zone 'UTC')::date);

  -- Evaluate each live item, the concern's item first. An exception request
  -- is only meaningful for an EXCHANGE result that names an offerable
  -- exception type (early exchange or prohibited fee window).
  for v_item in
    select i.id
    from public.sleep_trial_items i
    where i.journey_id = p_journey_id
      and i.status not in ('CLOSED','VOIDED')
    order by case
               when p_sleep_concern_id is not null
                    and i.id = (select sc.trial_item_id
                                from public.sleep_concerns sc
                                where sc.id = p_sleep_concern_id)
                 then 0 else 1
             end,
             i.started_on asc nulls last,
             i.unit_index asc
  loop
    v_eval := public.stv_eval_one(v_item.id, v_today);
    v_x := v_eval #> '{actions,EXCHANGE}';
    v_any := true;
    if v_first_x is null then
      v_first_x := v_x;
    end if;
    if v_x ->> 'reason_code' in ('MINIMUM_NIGHTS_NOT_MET','FEE_WINDOW_PROHIBITED')
       and coalesce((v_x ->> 'exception_available')::boolean, false) then
      v_target := v_item.id;
      v_night := nullif(v_eval #>> '{display,night}', '')::int;
      v_elig := nullif(v_eval #>> '{display,eligible_on}', '')::date;
      exit;
    end if;
  end loop;

  if v_target is null then
    if not v_any then
      raise exception 'This order has no sleep trial';
    end if;
    if v_first_x ->> 'status' = 'ELIGIBLE' then
      raise exception 'Journey is already exchange-eligible — no exception needed';
    end if;
    if v_first_x ->> 'status' = 'EXPIRED' then
      raise exception 'The sleep trial has already ended';
    end if;
    raise exception '%', coalesce(
      v_first_x ->> 'explanation',
      'No exception can be requested for this trial');
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
    v_night, v_elig,
    -- Early-exchange approvals lapse once normal eligibility arrives
    -- (old semantic). For prohibited-window requests the eligibility date
    -- is already past, so fall back to the standard 14-day approval window.
    case when v_elig is not null and v_elig > v_today
         then (v_elig + 1)::timestamptz
         else (v_today + 14)::timestamptz end
  )
  returning id into v_request_id;

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain, source_record_id, is_internal
  )
  select p_journey_id, sj.customer_id, 'customer_request', 'internal', 'internal',
    'return_exchange',
    'Early exchange exception requested (night ' || v_night
      || ' of ' || coalesce(v_eval #>> '{display,minimum_nights}', '?')
      || ' minimum). Reason: ' || btrim(p_reason),
    v_employee_id, 'sleep_trial_exception', v_request_id, true
  from public.sleep_journeys sj where sj.id = p_journey_id;

  return v_request_id;
exception
  when unique_violation then
    raise exception 'An early exchange exception request is already pending for this journey';
end;
$$;

grant execute on function public.request_sleep_trial_exception(uuid, uuid, text)
  to authenticated;

-- ============================================================================
-- 8. Retire the old journey-level helper (spec 26.6). Both callers were
--    switched above; nothing else references it.
-- ============================================================================

drop function if exists public.trial_status(uuid);
