-- 072_protector_precedence_and_override.sql
--
-- Sleep Trial Engine, ST-5 companion (docs/sleep-trial-engine.md Sections
-- 12, 19, 20):
--
--   1. Protector hard-block precedence. In stv_eval_action the protector
--      check moves ahead of every other check — action-offered, exchange
--      count, trial window, minimum nights, fee window, documentation, and
--      approval gates. When a required protector is missing, PROTECTOR_MISSING
--      is always the headline; every other check still runs and lands in
--      additional_blockers. missing_behavior semantics (BLOCK_WITH_OVERRIDE /
--      APPROVAL_REQUIRED / WARN_ONLY) are unchanged — only the ordering moves.
--
--   2. Direct protector override (locked decision: owner/admin override with
--      a reason — a direct action, not a request/approval workflow).
--      sleep_trial_protector_overrides holds one permanent override per item;
--      override_sleep_trial_protector() is the only write path.
--      stv_eval_protector_coverage treats an overridden item as covered, so a
--      subsequent evaluation reports the protector check satisfied.
--
-- Full Exceptions v2 (approval routing, staleness, other exception types)
-- stays in ST-6. This is deliberately narrow: one item, one override,
-- permanent, no expiry, no approval chain.
--
-- ============================================================================
-- 1. sleep_trial_protector_overrides
-- ============================================================================

create table if not exists public.sleep_trial_protector_overrides (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies (id) on delete cascade,
  journey_id uuid not null references public.sleep_journeys (id) on delete cascade,
  trial_item_id uuid not null references public.sleep_trial_items (id) on delete cascade,
  overridden_by uuid references public.employees (id) on delete set null,
  reason text not null,
  created_at timestamptz not null default now(),
  unique (trial_item_id)
);

comment on table public.sleep_trial_protector_overrides is
  'One permanent protector-requirement override per sleep trial item. Written '
  'only by override_sleep_trial_protector() (security definer); read by '
  'stv_eval_protector_coverage so the evaluator treats the item as covered.';

alter table public.sleep_trial_protector_overrides enable row level security;

drop policy if exists "Protector overrides viewable by journey viewers"
  on public.sleep_trial_protector_overrides;
create policy "Protector overrides viewable by journey viewers"
  on public.sleep_trial_protector_overrides for select
  to authenticated
  using (public.is_journey_visible(journey_id));

grant select on public.sleep_trial_protector_overrides to authenticated;
-- Write lockdown (062/065/069 pattern): inserts happen only inside the
-- security-definer RPC below.
revoke insert, update, delete, truncate on public.sleep_trial_protector_overrides
  from anon, authenticated;

-- ============================================================================
-- 2. stv_eval_protector_coverage — identical to 070 except the override
--    short-circuit right after the "required" check.
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

  -- Direct override (ST-5): one permanent row per item satisfies the
  -- requirement for every later evaluation of this item.
  if exists (
    select 1 from public.sleep_trial_protector_overrides o
    where o.trial_item_id = v_item.id
  ) then
    return jsonb_build_object(
      'covered', true, 'label', 'Requirement overridden',
      'required', true, 'overridden', true);
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
-- 3. stv_eval_action — identical to 070 except the protector block (old step
--    7) now runs first, ahead of every other check. A required-and-missing
--    protector is always the headline; all other blockers still populate
--    additional_blockers.
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

  -- 1. Protector (Section 12) — hard-block precedence: a required protector
  --    that is missing always wins the headline, ahead of every other check.
  --    WARN_ONLY still degrades to a warning rather than a blocker.
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

  -- 7. Approval gates
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

  -- 8. Approved exception: unblocks exactly the blocker it covers (existing
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
-- 4. override_sleep_trial_protector — direct owner/admin override (locked
--    decision: no request/approval workflow). One permanent override per
--    item; reason required; audited via audit_events + a Journey Activity
--    line (Section 15.8 pattern).
-- ============================================================================

create or replace function public.override_sleep_trial_protector(
  p_trial_item_id uuid,
  p_reason text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.sleep_trial_items%rowtype;
  v_employee_id uuid;
  v_coverage jsonb;
  v_id uuid;
begin
  if not public.has_permission('sleep_trial.override_protector') then
    raise exception 'You do not have permission to override the protector requirement';
  end if;

  select * into v_item from public.sleep_trial_items where id = p_trial_item_id;
  if not found then
    raise exception 'Sleep trial item not found';
  end if;
  if not public.is_journey_visible(v_item.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select e.id into v_employee_id
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee_id is null then
    raise exception 'Employee record not found';
  end if;

  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'A reason is required';
  end if;

  -- One override per item, permanent. A repeat call returns the existing
  -- row rather than double-writing or double-auditing.
  select o.id into v_id
  from public.sleep_trial_protector_overrides o
  where o.trial_item_id = p_trial_item_id;
  if v_id is not null then
    return v_id;
  end if;

  -- Only meaningful while the bound policy requires a protector and nothing
  -- covers this item yet.
  v_coverage := public.stv_eval_protector_coverage(p_trial_item_id, null);
  if not coalesce((v_coverage ->> 'required')::boolean, false) then
    raise exception 'This item''s policy does not require a protector';
  end if;
  if coalesce((v_coverage ->> 'covered')::boolean, false) then
    raise exception 'A qualifying protector already covers this item';
  end if;

  insert into public.sleep_trial_protector_overrides (
    company_id, journey_id, trial_item_id, overridden_by, reason
  ) values (
    v_item.company_id, v_item.journey_id, p_trial_item_id,
    v_employee_id, btrim(p_reason)
  )
  on conflict (trial_item_id) do nothing
  returning id into v_id;

  if v_id is null then
    -- A concurrent override won the unique slot; return it.
    select o.id into v_id
    from public.sleep_trial_protector_overrides o
    where o.trial_item_id = p_trial_item_id;
    return v_id;
  end if;

  perform public.log_audit_event(
    p_company_id := v_item.company_id,
    p_entity_type := 'sleep_trial_item',
    p_entity_id := p_trial_item_id,
    p_event_type := 'SLEEP_TRIAL_PROTECTOR_OVERRIDDEN',
    p_after := jsonb_build_object(
      'override_id', v_id,
      'reason', btrim(p_reason)),
    p_journey_id := v_item.journey_id,
    p_actor_employee_id := v_employee_id
  );

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain, source_record_id,
    is_internal
  )
  select v_item.journey_id, sj.customer_id,
    'internal_note', 'internal', 'internal', 'return_exchange',
    'Protector requirement overridden for '
      || coalesce(v_item.product_name_snapshot, 'this mattress')
      || '. Reason: ' || btrim(p_reason),
    v_employee_id, 'sleep_trial_protector_override', v_id, true
  from public.sleep_journeys sj
  where sj.id = v_item.journey_id;

  return v_id;
end;
$$;

grant execute on function public.override_sleep_trial_protector(uuid, text)
  to authenticated;

-- ============================================================================
-- 5. stv_eval_inner — identical to 071 except the allowed_ui_actions block.
--    The protector actions (OVERRIDE_PROTECTOR_REQUIREMENT /
--    REQUEST_PROTECTOR_EXCEPTION) move out of the pending-exception gate:
--    the override is a direct, self-authorized action, not an alternate path
--    to a pending request, so an unrelated pending exception must not hide
--    it. They now also fire off either action's result — a RETURN_ONLY
--    protector scope blocks RETURN, not EXCHANGE.
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
      v_ui := array_append(v_ui, 'START_EXCHANGE');
    end if;
    if v_r_res ->> 'status' = 'ELIGIBLE'
       and coalesce((v_perms ->> 'can_return')::boolean, false) then
      v_ui := array_append(v_ui, 'START_RETURN');
    end if;
    if coalesce((v_perms ->> 'can_concern')::boolean, false) then
      v_ui := array_append(v_ui, 'ADD_SLEEP_CONCERN');
    end if;
    v_ui := array_append(v_ui, 'SCHEDULE_FOLLOW_UP');

    if v_pend is not null then
      v_ui := array_append(v_ui, 'VIEW_EXCEPTION_REQUEST');
    elsif coalesce((v_perms ->> 'can_request')::boolean, false) then
      -- Exception requests stay gated on "no pending exception": they are
      -- alternate paths to the same request queue.
      if v_x_res ->> 'reason_code' in ('MINIMUM_NIGHTS_NOT_MET','FEE_WINDOW_PROHIBITED')
         and coalesce((v_x_res ->> 'exception_available')::boolean, false) then
        v_ui := array_append(v_ui, 'REQUEST_EARLY_EXCHANGE_EXCEPTION');
      end if;
      if v_x_res ->> 'reason_code' = 'EXCHANGE_LIMIT_REACHED' then
        v_ui := array_append(v_ui, 'REQUEST_EXTRA_EXCHANGE_EXCEPTION');
      end if;
      if v_x_res ->> 'reason_code' = 'TRIAL_EXPIRED'
         and coalesce((v_x_res ->> 'exception_available')::boolean, false) then
        v_ui := array_append(v_ui, 'REQUEST_EXPIRED_TRIAL_EXCEPTION');
      end if;
      if v_r_res ->> 'reason_code' = 'RETURNS_NOT_OFFERED'
         and coalesce((v_r_res ->> 'exception_available')::boolean, false) then
        v_ui := array_append(v_ui, 'REQUEST_RETURN_EXCEPTION');
      end if;
      if v_r_res ->> 'reason_code' = 'TRIAL_EXPIRED'
         and coalesce((v_r_res ->> 'exception_available')::boolean, false) then
        v_ui := array_append(v_ui, 'REQUEST_EXPIRED_RETURN_EXCEPTION');
      end if;
      if v_r_res ->> 'status' = 'APPROVAL_REQUIRED' then
        v_ui := array_append(v_ui, 'REQUEST_RETURN_APPROVAL');
      end if;
      if coalesce((v_x_res #> '{fee,amount_cents}')::text::int, 0) > 0 then
        v_ui := array_append(v_ui, 'REQUEST_FEE_WAIVER');
      end if;
      if coalesce((v_trial ->> 'extensions_allowed')::boolean, false) then
        v_ui := array_append(v_ui, 'EXTEND_TRIAL_REQUEST');
      end if;
    end if;

    -- Protector actions are NOT gated on the pending-exception check: the
    -- override is a distinct, direct action (self-authorized, not a request),
    -- and a pending exception must not hide it. Applies to either action's
    -- result so a RETURN_ONLY protector scope still surfaces the button.
    v_prot_bhv := coalesce(p_terms #>> '{protector,missing_behavior}',
                           'BLOCK_WITH_OVERRIDE');
    if v_x_res ->> 'reason_code' = 'PROTECTOR_MISSING'
       or v_r_res ->> 'reason_code' = 'PROTECTOR_MISSING' then
      if v_prot_bhv = 'BLOCK_WITH_OVERRIDE'
         and coalesce((v_perms ->> 'can_override_protector')::boolean, false) then
        v_ui := array_append(v_ui, 'OVERRIDE_PROTECTOR_REQUIREMENT');
      elsif v_prot_bhv = 'APPROVAL_REQUIRED'
            and coalesce((v_perms ->> 'can_request')::boolean, false) then
        v_ui := array_append(v_ui, 'REQUEST_PROTECTOR_EXCEPTION');
      end if;
    end if;
    v_ui := array_append(v_ui, 'ADD_NOTE');
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
      'term_sources', coalesce(p_facts -> 'term_sources', '{}'::jsonb),
      -- Bound terms verbatim (p_terms arrives as resolved_terms merged with
      -- fee_schedules; subtracting that key returns exactly the binding).
      -- The "Why?" panel renders these values next to term_sources.
      'resolved_terms', p_terms - 'fee_schedules'),
    'evaluated_at', now());
end;
$$;

revoke execute on function public.stv_eval_inner(jsonb, jsonb)
  from public, anon, authenticated;
