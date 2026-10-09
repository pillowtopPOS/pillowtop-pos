-- ============================================================================
-- EB-2: commit the exchange draft and spawn the linked child journey
-- (docs/exchange-builder-spec.md Sections 7.1, 8, 13). One migration.
--
-- Order per spec: evaluator fix, deposit, binding guard, line locks +
-- cancel guard, EB-1 follow-ups, update/commit/cancel/refund/complete,
-- delivered-on sync.
-- ============================================================================

-- ============================================================================
-- 1. Evaluator fix + coverage helper
--
-- stv_eval_one / stv_eval_action are recreated from their latest 075
-- definitions with ONE behavioral change: the approved-exception selection
-- is per action. Previously both EXCHANGE and RETURN read the single newest
-- APPROVED exception row; now each action reads the newest APPROVED row
-- with e.action equal to that action. The type → blocker coverage map is
-- extracted into stv_exception_covers_blocker (pure SQL) so commit and the
-- evaluator share one definition.
-- ============================================================================

create or replace function public.stv_exception_covers_blocker(
  p_exception_type text,
  p_action text,
  p_reason_code text
)
returns boolean
language sql
stable
set search_path = public
as $$
  -- RETURN_APPROVAL covers RETURN_NEEDS_APPROVAL only (spec 15.1):
  -- FEE_WINDOW_NEEDS_APPROVAL offers no typed exception (the evaluator
  -- emits exception_type null), so nothing can be requested or approved
  -- against it yet — an approved return exception must not silently
  -- clear it. PROTECTOR_OVERRIDE is intentionally not mapped.
  select case p_exception_type
    when 'EARLY_EXCHANGE' then
      p_action = 'EXCHANGE' and p_reason_code in
        ('MINIMUM_NIGHTS_NOT_MET','FEE_WINDOW_PROHIBITED')
    when 'EXPIRED_EXCHANGE' then
      p_action = 'EXCHANGE' and p_reason_code = 'TRIAL_EXPIRED'
    when 'EXTRA_EXCHANGE' then
      p_action = 'EXCHANGE' and p_reason_code = 'EXCHANGE_LIMIT_REACHED'
    when 'RETURN_NOT_ALLOWED' then
      p_action = 'RETURN' and p_reason_code = 'RETURNS_NOT_OFFERED'
    when 'RETURN_APPROVAL' then
      p_action = 'RETURN' and p_reason_code = 'RETURN_NEEDS_APPROVAL'
    when 'EXPIRED_RETURN' then
      p_action = 'RETURN' and p_reason_code = 'TRIAL_EXPIRED'
    else false end;
$$;

-- Internal helper — reached through stv_eval_one's definer chain.
revoke execute on function public.stv_exception_covers_blocker(text, text, text)
  from public, anon, authenticated;

create or replace function public.stv_eval_one(
  p_item_id uuid,
  p_today date default null
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
  v_appr_x uuid;
  v_appr_x_type text;
  v_appr_r uuid;
  v_appr_r_type text;
  v_ext int;
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

  -- Exceptions: the new table is authoritative and item-scoped. Legacy
  -- journey-scoped requests only fill in when no new-table twin exists —
  -- rows copied by 073 (or written in the gap) must not double-report.
  select e.id into v_pend
  from public.sleep_trial_exceptions e
  where e.trial_item_id = v_item.id
    and e.status = 'PENDING'
  order by e.requested_at desc
  limit 1;

  if v_pend is null then
    select r.id into v_pend
    from public.sleep_trial_exception_requests r
    where r.journey_id = v_item.journey_id
      and r.status = 'pending'
      and (r.expires_at is null or r.expires_at > now())
      and not exists (
        select 1 from public.sleep_trial_exceptions e
        where e.legacy_request_id = r.id)
    order by r.requested_at desc
    limit 1;
  end if;

  -- EB-2 fix: exceptions are scoped per action. EXCHANGE consumes the
  -- newest usable EXCHANGE exception, RETURN the newest usable RETURN
  -- exception — they no longer share one row.
  select e.id, e.exception_type::text into v_appr_x, v_appr_x_type
  from public.sleep_trial_exceptions e
  where e.trial_item_id = v_item.id
    and e.action = 'EXCHANGE'
    and e.status = 'APPROVED'
    and (e.valid_until is null or e.valid_until > now())
  order by e.decided_at desc
  limit 1;

  select e.id, e.exception_type::text into v_appr_r, v_appr_r_type
  from public.sleep_trial_exceptions e
  where e.trial_item_id = v_item.id
    and e.action = 'RETURN'
    and e.status = 'APPROVED'
    and (e.valid_until is null or e.valid_until > now())
  order by e.decided_at desc
  limit 1;

  -- Legacy fallback: approved 073 exception_requests not yet consumed.
  -- 073 requests were exchange-only, so this feeds the EXCHANGE slot.
  if v_appr_x is null then
    select r.id, 'EARLY_EXCHANGE' into v_appr_x, v_appr_x_type
    from public.sleep_trial_exception_requests r
    where r.journey_id = v_item.journey_id
      and r.status = 'approved'
      and (r.expires_at is null or r.expires_at > now())
      and not exists (
        select 1 from public.sleep_trial_exceptions e
        where e.legacy_request_id = r.id)
    order by r.decided_at desc
    limit 1;
  end if;

  -- Extensions are consumed on approval (Section 16); approved-but-not-
  -- yet-consumed rows still count so the window never shrinks mid-flight.
  select coalesce(sum((e.approved_terms ->> 'extension_nights')::int), 0)
    into v_ext
  from public.sleep_trial_exceptions e
  where e.trial_item_id = v_item.id
    and e.exception_type = 'EXTEND_TRIAL'
    and e.status in ('APPROVED','CONSUMED');

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
    'extension_nights', v_ext,
    'exchanges_used', v_used,
    'pair_open_action', v_pair_open,
    'concern_documented', v_oldest is not null,
    'concern_ok', v_oldest is not null and (v_oldest + v_age) <= v_today,
    'has_open_concern', v_open_concern,
    'protector', v_prot,
    'pending_exception_id', v_pend,
    'approved_exception_id_exchange', v_appr_x,
    'approved_exception_type_exchange', v_appr_x_type,
    'approved_exception_id_return', v_appr_r,
    'approved_exception_type_return', v_appr_r_type,
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
  v_appr    uuid := nullif(
    p_facts ->> ('approved_exception_id_' || lower(p_action)), '')::uuid;
  v_appr_type text := p_facts ->>
    ('approved_exception_type_' || lower(p_action));
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
  v_covers boolean;
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

  -- 8. Approved exception: unblocks exactly the blocker its type covers
  --    (Section 15.1 "Unblocks" column). FEE_WAIVER covers no blocker — it
  --    modifies fee at consumption — and EXTEND_TRIAL covers none either.
  v_params := jsonb_build_object(
    'action_label', v_lbl, 'eligible_on', v_elig, 'end_date', v_end,
    'night', v_night, 'minimum_nights', v_min,
    'exchanges_used', v_used, 'exchanges_allowed', v_max);

  if jsonb_array_length(v_blockers) = 0 then
    v_status := 'ELIGIBLE';
    v_reason := 'WITHIN_POLICY';
  else
    v_head := v_blockers -> 0;
    v_covers := public.stv_exception_covers_blocker(
      v_appr_type, p_action, v_head ->> 'reason_code');
    if v_appr is not null and v_covers then
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
-- 2. Deposit: exchange journeys never require a deposit
--
-- Recreated from 021 with a CASE inside the select list (a WHERE clause
-- would return NULL and mis-price). sale_kind = 'EXCHANGE' → 0; every
-- other journey keeps the existing deposit-policy calculation.
-- ============================================================================

create or replace function public.calculate_required_deposit(p_journey_id uuid)
returns numeric
language sql
stable
security invoker
set search_path = public
as $$
  select coalesce(
    case
      when sj.sale_kind = 'EXCHANGE' then 0
      else
        case dp.policy_type
          when 'none' then 0
          when 'fixed_amount' then dp.fixed_amount
          when 'percentage' then (sj.price * dp.percentage / 100)
          when 'greater_of_fixed_or_percentage' then greatest(dp.fixed_amount, sj.price * dp.percentage / 100)
        end
    end,
    0
  )
  from public.sleep_journeys sj
  join public.stores s on s.id = sj.store_id
  left join public.deposit_policies dp on dp.company_id = s.company_id
  where sj.id = p_journey_id;
$$;

-- ============================================================================
-- 3. Binding guard
--
-- stv_bind_trial_items recreated from 069 with one predicate added to the
-- line loop: lines flagged with exchange_action_id (replacement, fee,
-- other fees, credit) never produce trial items through the normal
-- triggers. EB-2b will bind the replacement itself by calling this with
-- p_reason = 'REPLACEMENT' when the policy grants a new trial.
-- ============================================================================

create or replace function public.stv_bind_trial_items(
  p_journey_id uuid,
  p_reason text,
  p_line_item_id uuid default null,    -- null = all lines on the journey
  p_policy_version_id uuid default null -- null = company's current PUBLISHED version
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_journey public.sleep_journeys%rowtype;
  v_company_id uuid;
  v_version_id uuid;
  v_actor uuid;
  v_line record;
  v_eligible boolean;
  v_facts jsonb;
  v_resolved jsonb;
  v_terms jsonb;
  v_sources jsonb;
  v_enabled boolean;
  v_src jsonb;
  v_i int;
  v_item_id uuid;
  v_hash text;
  v_count int := 0;
begin
  select * into v_journey from public.sleep_journeys where id = p_journey_id;
  if not found or v_journey.cancelled_at is not null then
    return 0;
  end if;

  -- sleep_journeys has no company_id; the journey's store carries it.
  select s.company_id into v_company_id
  from public.stores s
  where s.id = v_journey.store_id;
  if v_company_id is null then
    return 0;
  end if;

  if p_policy_version_id is not null then
    v_version_id := p_policy_version_id;
  else
    select p.current_version_id into v_version_id
    from public.policies p
    where p.company_id = v_company_id
      and p.policy_type = 'SLEEP_TRIAL';
  end if;
  if v_version_id is null then
    return 0; -- no published policy yet → nothing to bind
  end if;

  select e.id into v_actor
  from public.employees e
  where e.auth_user_id = auth.uid();

  for v_line in
    select jli.*,
           p.item_name as product_name,
           p.brand,
           p.category_id,
           p.sleep_trial_eligible as prod_eligible,
           pc.name as category_name,
           pc.sleep_trial_eligible as cat_eligible
    from public.journey_line_items jli
    left join public.products p on p.id = jli.product_id
    left join public.product_categories pc on pc.id = p.category_id
    where jli.journey_id = p_journey_id
      and (p_line_item_id is null or jli.id = p_line_item_id)
      -- EB-2: exchange-child lines (replacement, fee, credit) are flagged
      -- with exchange_action_id and never produce trial items via the
      -- normal path. EB-2b binds the replacement itself with
      -- p_reason = 'REPLACEMENT' when the policy grants a new trial.
      and (p_reason = 'REPLACEMENT' or jli.exchange_action_id is null)
  loop
    -- L4: product override wins, else the category flag.
    v_eligible := coalesce(v_line.prod_eligible, v_line.cat_eligible, false);

    if not v_eligible then
      update public.journey_line_items
      set trial_ineligible_reason = 'NOT_CATALOG_ELIGIBLE', updated_at = now()
      where id = v_line.id
        and trial_ineligible_reason is distinct from 'NOT_CATALOG_ELIGIBLE';
      continue;
    end if;

    v_facts := jsonb_build_object(
      'product_id', v_line.product_id,
      'category_id', v_line.category_id,
      'brand', v_line.brand,
      'condition', v_line.sold_condition);
    v_resolved := public.resolve_sleep_trial_terms(v_version_id, v_facts);
    v_terms := v_resolved -> 'resolved_terms';
    v_sources := v_resolved -> 'term_sources';
    v_hash := public.stv_sha256(v_terms::text);

    v_enabled := coalesce((v_terms #>> '{trial,enabled}')::boolean, true);

    if not v_enabled then
      -- Catalog-eligible but a rule disables the trial (Section 9.1 step 4).
      v_src := v_sources -> 'trial.enabled';
      update public.journey_line_items
      set trial_ineligible_reason = case
            when jsonb_typeof(v_src) = 'object' and v_src ->> 'scope' = 'CONDITION'
              then 'CONDITION_RULE'
            else 'TRIAL_DISABLED' end,
          updated_at = now()
      where id = v_line.id;
      continue;
    end if;

    update public.journey_line_items
    set trial_ineligible_reason = null, updated_at = now()
    where id = v_line.id and trial_ineligible_reason is not null;

    for v_i in 1 .. greatest(coalesce(v_line.quantity, 0), 0) loop
      if exists (
        select 1 from public.sleep_trial_items st
        where st.line_item_id = v_line.id
          and st.unit_index = v_i
          and st.status not in ('CLOSED','VOIDED')) then
        continue;
      end if;

      insert into public.sleep_trial_items (
        company_id, journey_id, line_item_id, unit_index, customer_id,
        product_id, product_name_snapshot, brand_snapshot,
        category_id_snapshot, category_name_snapshot, condition_snapshot,
        pair_group_id,
        policy_version_id, resolved_terms, term_sources, terms_hash,
        bound_at, bound_reason, status, lineage_root_id
      ) values (
        v_company_id, v_journey.id, v_line.id, v_i, v_journey.customer_id,
        v_line.product_id, coalesce(v_line.product_name, v_line.item_name), v_line.brand,
        v_line.category_id, v_line.category_name, v_line.sold_condition,
        v_line.pair_group_id,
        v_version_id, v_terms, v_sources, v_hash,
        now(), p_reason, 'PENDING_FULFILLMENT', null
      ) returning id into v_item_id;

      update public.sleep_trial_items
      set lineage_root_id = v_item_id
      where id = v_item_id;

      insert into public.sleep_trial_item_bindings (
        item_id, company_id, policy_version_id, resolved_terms,
        term_sources, terms_hash, reason, actor_employee_id
      ) values (
        v_item_id, v_company_id, v_version_id, v_terms,
        v_sources, v_hash, p_reason, v_actor
      );

      perform public.log_audit_event(
        v_company_id,
        'sleep_trial_item', v_item_id, 'SLEEP_TRIAL_ITEM_BOUND',
        null,
        jsonb_build_object(
          'policy_version_id', v_version_id,
          'bound_reason', p_reason,
          'line_item_id', v_line.id,
          'unit_index', v_i),
        null, null, v_journey.id, 'EMPLOYEE', v_actor);

      v_count := v_count + 1;
    end loop;
  end loop;

  return v_count;
end;
$$;

revoke execute on function public.stv_bind_trial_items(uuid, text, uuid, uuid)
  from public, anon, authenticated;

-- ============================================================================
-- 4. Line locks + replacement-cancellation guard
--
-- The three existing write policies on journey_line_items are replaced so
-- users cannot add, edit, or delete lines flagged with exchange_action_id,
-- and cannot add lines directly to an exchange child journey at all. Only
-- the exchange RPCs (security definer, RLS-bypassing owner) write them.
-- ============================================================================

drop policy if exists "Journey line items insertable by authenticated users" on public.journey_line_items;
create policy "Journey line items insertable by authenticated users"
  on public.journey_line_items for insert
  to authenticated
  with check (
    public.is_journey_visible(journey_id)
    and exchange_action_id is null
    and not exists (
      select 1 from public.sleep_journeys sj
      where sj.id = journey_line_items.journey_id
        and sj.exchange_action_id is not null
    )
  );

drop policy if exists "Journey line items updatable by authenticated users" on public.journey_line_items;
create policy "Journey line items updatable by authenticated users"
  on public.journey_line_items for update
  to authenticated
  using (public.is_journey_visible(journey_id) and exchange_action_id is null)
  with check (public.is_journey_visible(journey_id) and exchange_action_id is null);

drop policy if exists "Journey line items deletable by authenticated users" on public.journey_line_items;
create policy "Journey line items deletable by authenticated users"
  on public.journey_line_items for delete
  to authenticated
  using (public.is_journey_visible(journey_id) and exchange_action_id is null);

-- The child journey must be cancelled through cancel_sleep_trial_action so
-- the original trial item is reopened and the action row is audited. A
-- journey_cancelled event inserted directly (the normal Cancel button)
-- raises unless the transaction-local flag names this action — the RPC
-- sets it right before inserting its own event.
create or replace function public.stv_guard_exchange_journey_cancel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action_id uuid;
begin
  if new.event_type <> 'journey_cancelled' then
    return new;
  end if;

  select sj.exchange_action_id into v_action_id
  from public.sleep_journeys sj
  join public.sleep_trial_actions a on a.id = sj.exchange_action_id
  where sj.id = new.journey_id
    and a.status = 'COMMITTED';

  if v_action_id is not null
     and current_setting('pillowtop.exchange_cancel', true)
         is distinct from v_action_id::text then
    raise exception 'Cancel this replacement from the exchange, not from the journey.';
  end if;

  return new;
end;
$$;

revoke execute on function public.stv_guard_exchange_journey_cancel()
  from public, anon, authenticated;

drop trigger if exists trg_exchange_journey_cancel_guard on public.journey_events;
create trigger trg_exchange_journey_cancel_guard
  before insert on public.journey_events
  for each row
  execute function public.stv_guard_exchange_journey_cancel();

-- ============================================================================
-- 5. EB-1 follow-ups
--
-- a) create_exchange_draft validates that p_replacement_variant_id belongs
--    to the company, and a replayed idempotency key only returns the
--    stored id when it was created for the same trial item + action.
-- b) quote_sleep_trial_action raises when the item's fee_basis_cents is
--    null instead of treating it as a zero credit.
-- ============================================================================

create or replace function public.quote_sleep_trial_action(
  p_trial_item_id uuid,
  p_action text,
  p_replacement_product_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.sleep_trial_items%rowtype;
  v_company uuid;
  v_eval jsonb;
  v_action_result jsonb;
  v_fee_cents int;
  v_credit_cents int;
  v_repl_price_cents int;
  v_net int;
  v_used int;
  v_repl_entry jsonb;
  v_preview jsonb;
  v_exc record;
  v_exc_check jsonb;
  v_applicable jsonb;
begin
  if p_action not in ('EXCHANGE','RETURN') then
    raise exception 'action must be EXCHANGE or RETURN';
  end if;

  select * into v_item
  from public.sleep_trial_items
  where id = p_trial_item_id;
  if not found then
    raise exception 'Trial item not found';
  end if;
  if not public.is_journey_visible(v_item.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select st.company_id into v_company
  from public.sleep_journeys sj
  join public.stores st on st.id = sj.store_id
  where sj.id = v_item.journey_id;

  v_eval := public.stv_eval_one(p_trial_item_id, null);
  v_action_result := case p_action
    when 'EXCHANGE' then v_eval #> '{actions,EXCHANGE}'
    else v_eval #> '{actions,RETURN}' end;

  v_fee_cents := coalesce(
    (v_action_result #>> '{fee,amount_cents}')::int, 0);

  -- A null fee basis must not silently read as a zero credit (EB-1 bug):
  -- the credit is the mattress's recorded sale price and is required.
  if v_item.fee_basis_cents is null then
    raise exception
      'This mattress has no recorded sale price (fee basis), so a credit amount cannot be computed';
  end if;
  v_credit_cents := v_item.fee_basis_cents;

  -- Replacement default price: sale-aware, same rule as the client's
  -- getEffectivePrice — sale_price first, then price (dollars -> cents).
  v_repl_price_cents := null;
  if p_replacement_product_id is not null then
    select round(coalesce(p.sale_price, p.price) * 100)::int
    into v_repl_price_cents
    from public.products p
    where p.id = p_replacement_product_id
      and p.company_id = v_company;
    if not found then
      raise exception 'Replacement product not found in this company';
    end if;
  end if;

  -- net = replacement + fee - credit (other fees / tax are added later on
  -- the record; quote assumes zero). Signed: positive = customer owes.
  v_net := coalesce(v_repl_price_cents, 0)
           + coalesce(v_fee_cents, 0)
           - coalesce(v_credit_cents, 0);

  -- Replacement trial preview (policy rule base.exchange.replacement_trial,
  -- a list of {n, rule, nights?} indexed by exchange number; missing entry
  -- means NONE — docs/sleep-trial-engine.md Section 17).
  v_used := coalesce(
    (v_eval #>> '{display,exchanges_used}')::int, 0);
  v_repl_entry := null;
  if v_item.resolved_terms #> '{exchange,replacement_trial}' is not null then
    select e.val into v_repl_entry
    from jsonb_array_elements(
      v_item.resolved_terms #> '{exchange,replacement_trial}') as e(val)
    where (e.val ->> 'n')::int = v_used + 1
    limit 1;
  end if;
  if v_item.resolved_terms -> 'exchange' is null then
    v_preview := null;
  else
    v_preview := jsonb_build_object(
      'exchange_number', v_used + 1,
      'rule', coalesce(v_repl_entry ->> 'rule', 'NONE'),
      'nights', nullif(v_repl_entry ->> 'nights', '')::int,
      'replacement_minimum',
        v_item.resolved_terms #> '{exchange,replacement_minimum}');
  end if;

  -- Applicable usable approved exception for this item + action: newest
  -- APPROVED row first; validate each (may lazily mark EXPIRED/STALE) and
  -- take the first usable one. Never consumed here — consumption happens
  -- at commit (EB-2).
  v_applicable := null;
  for v_exc in
    select e.id, e.exception_type::text as exception_type, e.approved_terms
    from public.sleep_trial_exceptions e
    where e.trial_item_id = p_trial_item_id
      and e.action = p_action
      and e.status = 'APPROVED'
    order by e.decided_at desc
  loop
    v_exc_check := public.stv_validate_trial_item_exception(v_exc.id);
    if coalesce((v_exc_check ->> 'usable')::boolean, false) then
      v_applicable := jsonb_build_object(
        'exception_id', v_exc.id,
        'exception_type', v_exc.exception_type,
        'approved_terms', v_exc.approved_terms,
        'usable', true);
      exit;
    end if;
  end loop;

  return jsonb_build_object(
    'trial_item_id', p_trial_item_id,
    'journey_id', v_item.journey_id,
    'action', p_action,
    'evaluation', v_eval,
    'action_result', v_action_result,
    'locked_fee_cents', v_fee_cents,
    'original_credit_cents', v_credit_cents,
    'replacement_product_id', p_replacement_product_id,
    'replacement_price_cents', v_repl_price_cents,
    'net_cents', v_net,
    'refund_owed_cents', greatest(-v_net, 0),
    'commission_basis_cents', v_net,
    'replacement_trial_preview', v_preview,
    'applicable_exception', v_applicable,
    'quoted_at', now());
end;
$$;

revoke execute on function public.quote_sleep_trial_action(uuid, text, uuid)
  from public, anon;
grant execute on function public.quote_sleep_trial_action(uuid, text, uuid)
  to authenticated;

create or replace function public.create_exchange_draft(
  p_trial_item_id uuid,
  p_action text,
  p_replacement_product_id uuid,
  p_replacement_variant_id uuid,
  p_fulfillment_method text,
  p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.sleep_trial_items%rowtype;
  v_company uuid;
  v_employee uuid;
  v_existing uuid;
  v_existing_item uuid;
  v_existing_action text;
  v_open record;
  v_quote jsonb;
  v_action_id uuid;
  v_exception_id uuid;
begin
  if p_action not in ('EXCHANGE','RETURN') then
    raise exception 'action must be EXCHANGE or RETURN';
  end if;

  if p_action = 'EXCHANGE'
     and not public.has_permission('sleep_trial.start_exchange') then
    raise exception 'Missing permission: sleep_trial.start_exchange';
  end if;
  if p_action = 'RETURN'
     and not public.has_permission('sleep_trial.start_return') then
    raise exception 'Missing permission: sleep_trial.start_return';
  end if;

  if p_fulfillment_method is not null
     and p_fulfillment_method not in ('delivery','pickup') then
    raise exception 'fulfillment_method must be delivery or pickup';
  end if;

  select e.id into v_employee
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;

  -- Lock the trial item: the ACTIVE check and the open-action check must
  -- serialize against a concurrent draft/commit on the same mattress.
  select * into v_item
  from public.sleep_trial_items
  where id = p_trial_item_id
  for update;
  if not found then
    raise exception 'Trial item not found';
  end if;
  if not public.is_journey_visible(v_item.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select st.company_id into v_company
  from public.sleep_journeys sj
  join public.stores st on st.id = sj.store_id
  where sj.id = v_item.journey_id;

  -- Idempotent retry: the same key returns the stored id, but only when
  -- the replay is for the same trial item and action — a key reused with
  -- different parameters is an error, not a silent hit.
  if p_idempotency_key is not null then
    select a.id, a.trial_item_id, a.action
      into v_existing, v_existing_item, v_existing_action
    from public.sleep_trial_actions a
    where a.company_id = v_company
      and a.idempotency_key = p_idempotency_key;
    if v_existing is not null then
      if v_existing_item is distinct from p_trial_item_id
         or v_existing_action is distinct from p_action then
        raise exception
          'Idempotency key "%" was already used for a different draft',
          p_idempotency_key;
      end if;
      return v_existing;
    end if;
  end if;

  -- The replacement variant must belong to this company (the quote only
  -- validates replacement_product_id).
  if p_replacement_variant_id is not null
     and not exists (
       select 1 from public.products p
       where p.id = p_replacement_variant_id
         and p.company_id = v_company) then
    raise exception 'Replacement variant not found in this company';
  end if;

  if v_item.status <> 'ACTIVE' then
    raise exception 'This mattress''s trial is not active (status %)',
      v_item.status;
  end if;

  -- Friendly pre-check; the partial unique index is the real guarantee.
  select a.id, e.name into v_open
  from public.sleep_trial_actions a
  left join public.employees e on e.id = a.created_by
  where a.trial_item_id = p_trial_item_id
    and a.status in ('DRAFT','COMMITTED')
  limit 1;
  if v_open.id is not null then
    raise exception 'An exchange or return is already in progress for this mattress (started by %)',
      coalesce(v_open.name, 'another employee');
  end if;

  v_quote := public.quote_sleep_trial_action(
    p_trial_item_id, p_action, p_replacement_product_id);

  v_exception_id := nullif(
    v_quote #>> '{applicable_exception,exception_id}', '')::uuid;

  insert into public.sleep_trial_actions (
    company_id,
    journey_id,
    trial_item_id,
    action,
    status,
    locked_evaluation,
    locked_fee_cents,
    exception_id,
    replacement_product_id,
    replacement_variant_id,
    replacement_quantity,
    replacement_price_cents,
    original_credit_cents,
    exchange_fee_cents,
    other_fees_cents,
    net_cents,
    refund_owed_cents,
    commission_basis_cents,
    sale_attribution_employee_id,
    fulfillment_method,
    idempotency_key,
    created_by
  ) values (
    v_company,
    v_item.journey_id,
    p_trial_item_id,
    p_action,
    'DRAFT',
    v_quote -> 'evaluation',
    nullif(v_quote ->> 'locked_fee_cents', '')::int,
    v_exception_id,
    p_replacement_product_id,
    p_replacement_variant_id,
    case when p_action = 'EXCHANGE' then 1 else null end,
    nullif(v_quote ->> 'replacement_price_cents', '')::int,
    nullif(v_quote ->> 'original_credit_cents', '')::int,
    nullif(v_quote ->> 'locked_fee_cents', '')::int,
    0,
    nullif(v_quote ->> 'net_cents', '')::int,
    nullif(v_quote ->> 'refund_owed_cents', '')::int,
    nullif(v_quote ->> 'commission_basis_cents', '')::int,
    v_employee,
    p_fulfillment_method,
    p_idempotency_key,
    v_employee
  )
  returning id into v_action_id;

  perform public.log_audit_event(
    p_company_id := v_company,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action_id,
    p_event_type := 'EXCHANGE_DRAFT_CREATED',
    p_after := jsonb_build_object(
      'action', p_action,
      'status', 'DRAFT',
      'trial_item_id', p_trial_item_id,
      'replacement_product_id', p_replacement_product_id,
      'fulfillment_method', p_fulfillment_method,
      'net_cents', nullif(v_quote ->> 'net_cents', '')::int,
      'exception_id', v_exception_id),
    p_journey_id := v_item.journey_id,
    p_actor_employee_id := v_employee
  );

  return v_action_id;
exception
  when unique_violation then
    -- Race: either the idempotency key or the open-action index tripped.
    if p_idempotency_key is not null then
      select a.id, a.trial_item_id, a.action
        into v_existing, v_existing_item, v_existing_action
      from public.sleep_trial_actions a
      where a.company_id = v_company
        and a.idempotency_key = p_idempotency_key;
      if v_existing is not null then
        if v_existing_item is distinct from p_trial_item_id
           or v_existing_action is distinct from p_action then
          raise exception
            'Idempotency key "%" was already used for a different draft',
            p_idempotency_key;
        end if;
        return v_existing;
      end if;
    end if;
    raise exception 'An exchange or return is already in progress for this mattress';
end;
$$;

revoke execute on function public.create_exchange_draft(
  uuid, text, uuid, uuid, text, text) from public, anon;
grant execute on function public.create_exchange_draft(
  uuid, text, uuid, uuid, text, text) to authenticated;

-- ============================================================================
-- 6. update_exchange_draft
--
-- DRAFT only. The starter (or a sleep_trial.complete_exchange holder) can
-- edit fulfillment, other fees and tax; a complete_exchange holder may
-- also override the replacement price with a mandatory reason. Null
-- parameters leave the stored value unchanged. Changing the product
-- re-checks the company and resets the price to the default, clearing
-- any price-override reason. Money recomputes with the EB-2 credit math.
-- ============================================================================

create or replace function public.update_exchange_draft(
  p_action_id uuid,
  p_replacement_product_id uuid default null,
  p_fulfillment_method text default null,
  p_other_fees_cents integer default null,
  p_tax_cents integer default null,
  p_replacement_price_cents integer default null,
  p_price_reason text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_employee uuid;
  v_can_complete boolean;
  v_default_price int;
  v_old_price int;
  v_pos_total int;
  v_net int;
  v_price_overridden boolean := false;
begin
  select e.id into v_employee
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;

  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id
  for update;
  if not found then
    raise exception 'Exchange action not found';
  end if;
  if not public.is_journey_visible(v_action.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;
  if v_action.status <> 'DRAFT' then
    raise exception 'Only a draft can be edited (status %)', v_action.status;
  end if;

  v_can_complete := public.has_permission('sleep_trial.complete_exchange');
  if v_action.created_by is distinct from v_employee
     and not v_can_complete then
    raise exception 'Only the starter or a manager can edit this draft';
  end if;

  if p_fulfillment_method is not null
     and p_fulfillment_method not in ('delivery','pickup') then
    raise exception 'fulfillment_method must be delivery or pickup';
  end if;
  if (p_other_fees_cents is not null and p_other_fees_cents < 0)
     or (p_tax_cents is not null and p_tax_cents < 0)
     or (p_replacement_price_cents is not null and p_replacement_price_cents < 0) then
    raise exception 'Amounts must be non-negative integer cents';
  end if;

  -- Product change: re-check the company, reset the price to the default
  -- and clear any price-override reason.
  if p_replacement_product_id is not null
     and p_replacement_product_id is distinct from v_action.replacement_product_id then
    select round(coalesce(p.sale_price, p.price) * 100)::int
      into v_default_price
    from public.products p
    where p.id = p_replacement_product_id
      and p.company_id = v_action.company_id;
    if v_default_price is null then
      raise exception 'Replacement product not found in this company';
    end if;
    v_action.replacement_product_id := p_replacement_product_id;
    -- "variant" and "product" are the same row in this schema.
    v_action.replacement_variant_id := p_replacement_product_id;
    v_action.replacement_price_cents := v_default_price;
    v_action.replacement_price_reason := null;
  end if;

  -- Price override, applied after any product reset: manager only and a
  -- non-empty reason is mandatory.
  if p_replacement_price_cents is not null
     and p_replacement_price_cents is distinct from v_action.replacement_price_cents then
    if not v_can_complete then
      raise exception 'Missing permission: sleep_trial.complete_exchange (price override)';
    end if;
    if nullif(btrim(coalesce(p_price_reason, '')), '') is null then
      raise exception 'A reason is required to override the replacement price';
    end if;
    v_old_price := v_action.replacement_price_cents;
    v_action.replacement_price_cents := p_replacement_price_cents;
    v_action.replacement_price_reason := btrim(p_price_reason);
    v_price_overridden := true;
  end if;

  v_action.other_fees_cents := coalesce(
    p_other_fees_cents, v_action.other_fees_cents, 0);
  v_action.tax_cents := coalesce(p_tax_cents, v_action.tax_cents, 0);
  if p_fulfillment_method is not null then
    v_action.fulfillment_method := p_fulfillment_method;
  end if;

  -- Credit math: the credit line is capped at the positive total so the
  -- child price never goes below zero; the remainder is refund_owed.
  v_pos_total := coalesce(v_action.replacement_price_cents, 0)
                 + coalesce(v_action.exchange_fee_cents, 0)
                 + coalesce(v_action.other_fees_cents, 0);
  v_net := v_pos_total - coalesce(v_action.original_credit_cents, 0);

  update public.sleep_trial_actions
  set replacement_product_id = v_action.replacement_product_id,
      replacement_variant_id = v_action.replacement_variant_id,
      replacement_price_cents = v_action.replacement_price_cents,
      replacement_price_reason = v_action.replacement_price_reason,
      other_fees_cents = v_action.other_fees_cents,
      tax_cents = v_action.tax_cents,
      fulfillment_method = v_action.fulfillment_method,
      net_cents = v_net,
      refund_owed_cents = greatest(-v_net, 0),
      commission_basis_cents = v_net
  where id = v_action.id;

  if v_price_overridden then
    perform public.log_audit_event(
      p_company_id := v_action.company_id,
      p_entity_type := 'sleep_trial_action',
      p_entity_id := v_action.id,
      p_event_type := 'EXCHANGE_PRICE_OVERRIDDEN',
      p_after := jsonb_build_object(
        'previous_price_cents', v_old_price,
        'replacement_price_cents', v_action.replacement_price_cents,
        'reason', v_action.replacement_price_reason),
      p_journey_id := v_action.journey_id,
      p_actor_employee_id := v_employee);
  end if;

  return v_action.id;
end;
$$;

revoke execute on function public.update_exchange_draft(
  uuid, uuid, text, integer, integer, integer, text) from public, anon;
grant execute on function public.update_exchange_draft(
  uuid, uuid, text, integer, integer, integer, text) to authenticated;

-- ============================================================================
-- 7. commit_sleep_trial_action
--
-- EXCHANGE only. Evaluates the trial item BEFORE moving it to in-progress;
-- allowed only when actions.EXCHANGE.status = 'ELIGIBLE'. Inserts the
-- child journey at its default Quoted state, then the flagged lines in
-- order: replacement, fee (if > 0), other fees (if > 0), credit last
-- (if > 0). Emits no quote/deposit/sold events — a zero-or-below net
-- flips the child to Sold through the existing balance logic when the
-- credit line lands.
-- ============================================================================

create or replace function public.commit_sleep_trial_action(p_action_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_item public.sleep_trial_items%rowtype;
  v_journey public.sleep_journeys%rowtype;
  v_employee uuid;
  v_employee_name text;
  v_eval jsonb;
  v_x jsonb;
  v_applied_id uuid;
  v_check jsonb;
  v_exc record;
  v_waiver_id uuid;
  v_waiver_fee int;
  v_policy_fee int;
  v_locked_fee int;
  v_used int;
  v_repl_entry jsonb;
  v_repl_rule text;
  v_credit int;
  v_pos_total int;
  v_credit_line int;
  v_net int;
  v_child uuid;
  v_active_store uuid;
  v_child_store uuid;
  v_repl_name text;
  v_fulfillment public.fulfillment_type;
  v_exc_ids uuid[] := '{}'::uuid[];
begin
  -- Lock order: action, trial item, then inserts.
  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id
  for update;
  if not found then
    raise exception 'Exchange action not found';
  end if;
  if not public.is_journey_visible(v_action.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  if v_action.action = 'RETURN' then
    raise exception 'Returns are not enabled yet';
  end if;
  if not public.has_permission('sleep_trial.start_exchange') then
    raise exception 'Missing permission: sleep_trial.start_exchange';
  end if;

  select e.id, e.name into v_employee, v_employee_name
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;

  -- Idempotent retry: a re-commit returns the existing child.
  if v_action.status = 'COMMITTED' then
    return v_action.child_journey_id;
  end if;
  if v_action.status <> 'DRAFT' then
    raise exception 'Only a draft can be committed (status %)', v_action.status;
  end if;

  select * into v_item
  from public.sleep_trial_items
  where id = v_action.trial_item_id
  for update;
  if not found then
    raise exception 'Trial item not found';
  end if;
  if v_item.status <> 'ACTIVE' then
    raise exception 'This mattress''s trial is not active (status %)',
      v_item.status;
  end if;

  select * into v_journey
  from public.sleep_journeys
  where id = v_action.journey_id;

  -- Delivery needs an address BEFORE the child is inserted (the generic
  -- trigger would also block, but with a less helpful message).
  v_fulfillment := coalesce(
    v_action.fulfillment_method, 'delivery')::public.fulfillment_type;
  if v_fulfillment = 'delivery'
     and not exists (
       select 1 from public.customers c
       where c.id = v_journey.customer_id
         and nullif(btrim(coalesce(c.street_address, '')), '') is not null) then
    raise exception 'The customer has no street address — add one or switch the replacement to pickup';
  end if;

  -- The credit is the item's recorded sale price and is required (a null
  -- basis must not read as a zero credit).
  if v_item.fee_basis_cents is null then
    raise exception 'This mattress has no recorded sale price (fee basis), so a credit amount cannot be computed';
  end if;
  v_credit := v_item.fee_basis_cents;

  -- Gate: evaluate before the item moves to in-progress.
  v_eval := public.stv_eval_one(v_action.trial_item_id, null);
  v_x := v_eval #> '{actions,EXCHANGE}';
  if coalesce(v_x ->> 'status', '') <> 'ELIGIBLE' then
    raise exception 'This exchange is not eligible right now: %',
      coalesce(v_x ->> 'explanation', v_x ->> 'reason_code', 'unknown reason');
  end if;

  -- The evaluator's applied exception must still be usable before it is
  -- consumed; a stale or expired approval gets a friendly refusal.
  v_applied_id := nullif(v_x ->> 'applied_exception_id', '')::uuid;
  if v_applied_id is not null then
    v_check := public.stv_validate_trial_item_exception(v_applied_id);
    if not coalesce((v_check ->> 'usable')::boolean, false) then
      raise exception 'The approval covering this exchange is no longer valid (%) — request a new approval',
        coalesce(v_check ->> 'detail', v_check ->> 'reason', 'not usable');
    end if;
  end if;

  -- Fee waiver, separate from the gate: the newest usable APPROVED
  -- FEE_WAIVER for this item + EXCHANGE sets the charged fee (0 by
  -- default, or an approved reduced amount in approved_terms.fee_cents).
  v_policy_fee := coalesce((v_x #>> '{fee,amount_cents}')::int, 0);
  v_locked_fee := v_policy_fee;
  v_waiver_id := null;
  v_waiver_fee := null;
  for v_exc in
    select e.id, e.approved_terms
    from public.sleep_trial_exceptions e
    where e.trial_item_id = v_action.trial_item_id
      and e.action = 'EXCHANGE'
      and e.exception_type::text = 'FEE_WAIVER'
      and e.status = 'APPROVED'
    order by e.decided_at desc
  loop
    v_check := public.stv_validate_trial_item_exception(v_exc.id);
    if coalesce((v_check ->> 'usable')::boolean, false) then
      v_waiver_id := v_exc.id;
      -- Approved fee terms mirror the policy fee-schedule keys: a flat
      -- amount, or percent_bp of the fee basis rounded half-up (070).
      v_waiver_fee := case
        when v_exc.approved_terms ? 'fee_amount_cents' then
          (v_exc.approved_terms ->> 'fee_amount_cents')::int
        when v_exc.approved_terms ? 'fee_flat_cents' then
          (v_exc.approved_terms ->> 'fee_flat_cents')::int
        when v_exc.approved_terms ? 'fee_percent_bp' then
          ((v_credit::bigint
            * coalesce((v_exc.approved_terms ->> 'fee_percent_bp')::int, 0)
            + 5000) / 10000)::int
        else 0 end;
      exit;
    end if;
  end loop;
  if v_waiver_id is not null then
    -- Fee never exceeds the credit, same invariant as the evaluator.
    v_locked_fee := least(greatest(v_waiver_fee, 0), v_credit);
  end if;

  -- Replacement trial: only rule NONE is supported in EB-2. Read the
  -- original item's SNAPSHOTTED resolved_terms (not live policy),
  -- indexed by exchange number; FULL_NEW / REMAINING / FIXED arrive in
  -- EB-2b.
  v_used := coalesce((v_eval #>> '{display,exchanges_used}')::int, 0);
  v_repl_entry := null;
  if v_item.resolved_terms #> '{exchange,replacement_trial}' is not null then
    select e.val into v_repl_entry
    from jsonb_array_elements(
      v_item.resolved_terms #> '{exchange,replacement_trial}') as e(val)
    where (e.val ->> 'n')::int = v_used + 1
    limit 1;
  end if;
  v_repl_rule := coalesce(v_repl_entry ->> 'rule', 'NONE');
  if v_repl_rule <> 'NONE' then
    raise exception 'This mattress''s trial policy gives the replacement a new sleep trial (rule %), which is not supported yet — this exchange cannot be committed',
      v_repl_rule;
  end if;

  -- Money (decision 2): the credit LINE is capped at the positive total
  -- so the child price never goes below zero; the remainder of the
  -- credit is refund_owed_cents.
  v_pos_total := coalesce(v_action.replacement_price_cents, 0)
                 + v_locked_fee
                 + coalesce(v_action.other_fees_cents, 0);
  v_credit_line := least(v_credit, v_pos_total);
  v_net := v_pos_total - v_credit;

  -- Child store (decision 7): the caller's active_store_id JWT claim,
  -- validated against the company; fall back to the employee's home store.
  v_active_store := null;
  begin
    v_active_store :=
      (auth.jwt() -> 'user_metadata' ->> 'active_store_id')::uuid;
  exception when others then
    v_active_store := null;
  end;
  select s.id into v_child_store
  from public.stores s
  where s.id = v_active_store
    and s.company_id = v_action.company_id;
  if v_child_store is null then
    select e.home_store_id into v_child_store
    from public.employees e
    where e.id = v_employee;
  end if;
  if v_child_store is null then
    raise exception 'Could not determine a store for the replacement journey';
  end if;

  select p.item_name into v_repl_name
  from public.products p
  where p.id = coalesce(v_action.replacement_variant_id,
                        v_action.replacement_product_id);
  v_repl_name := coalesce(v_repl_name, 'Replacement item');

  -- Child: default Quoted state; same customer; committer assigned;
  -- exchange kind; parent + action links; fulfillment from the action.
  insert into public.sleep_journeys (
    customer_id,
    store_id,
    assigned_employee_id,
    product_id,
    fulfillment_type,
    parent_journey_id,
    exchange_action_id,
    sale_kind
  ) values (
    v_journey.customer_id,
    v_child_store,
    v_employee,
    coalesce(v_action.replacement_variant_id, v_action.replacement_product_id),
    v_fulfillment,
    v_action.journey_id,
    v_action.id,
    'EXCHANGE'
  ) returning id into v_child;

  -- Flagged lines in the required order. unit_price is cents / 100.0.
  insert into public.journey_line_items (
    journey_id, product_id, item_name, quantity, unit_price,
    trial_ineligible_reason, exchange_action_id
  ) values (
    v_child,
    coalesce(v_action.replacement_variant_id, v_action.replacement_product_id),
    v_repl_name,
    greatest(coalesce(v_action.replacement_quantity, 1), 1),
    coalesce(v_action.replacement_price_cents, 0) / 100.0,
    'EXCHANGE_NO_NEW_TRIAL',
    v_action.id
  );

  if v_locked_fee > 0 then
    insert into public.journey_line_items (
      journey_id, item_name, quantity, unit_price, exchange_action_id
    ) values (
      v_child, 'Exchange fee', 1, v_locked_fee / 100.0, v_action.id);
  end if;

  if coalesce(v_action.other_fees_cents, 0) > 0 then
    insert into public.journey_line_items (
      journey_id, item_name, quantity, unit_price, exchange_action_id
    ) values (
      v_child, 'Other fees', 1, v_action.other_fees_cents / 100.0, v_action.id);
  end if;

  -- Credit LAST: the negative line lands after the positives so a
  -- zero-or-below net flips the child to Sold here.
  if v_credit_line > 0 then
    insert into public.journey_line_items (
      journey_id, item_name, quantity, unit_price, exchange_action_id
    ) values (
      v_child,
      'Exchange credit — ' || coalesce(v_item.product_name_snapshot, 'returned mattress'),
      1,
      -v_credit_line / 100.0,
      v_action.id);
  end if;

  -- Now the original item moves to in-progress (re-locks and re-validates
  -- ACTIVE inside).
  perform public.stv_action_set_item_in_progress(v_item.id, 'EXCHANGE');

  -- Consume exceptions: coverage exception first (financial_impact 0),
  -- then the fee waiver (impact = policy fee - charged fee).
  if v_applied_id is not null then
    perform public.stv_consume_trial_item_exception(
      v_applied_id, 'exchange', v_action.id, v_employee);
    update public.sleep_trial_exceptions
    set financial_impact_cents = 0
    where id = v_applied_id;
    v_exc_ids := array_append(v_exc_ids, v_applied_id);
  end if;
  if v_waiver_id is not null then
    perform public.stv_consume_trial_item_exception(
      v_waiver_id, 'exchange', v_action.id, v_employee);
    update public.sleep_trial_exceptions
    set financial_impact_cents = greatest(v_policy_fee - v_locked_fee, 0)
    where id = v_waiver_id;
    v_exc_ids := array_append(v_exc_ids, v_waiver_id);
  end if;

  update public.sleep_trial_actions
  set status = 'COMMITTED',
      locked_evaluation = v_eval,
      locked_fee_cents = v_locked_fee,
      exception_id = coalesce(v_applied_id, v_waiver_id, exception_id),
      original_credit_cents = v_credit,
      exchange_fee_cents = v_locked_fee,
      net_cents = v_net,
      refund_owed_cents = greatest(-v_net, 0),
      commission_basis_cents = v_net,
      child_journey_id = v_child,
      committed_by = v_employee,
      committed_at = now()
  where id = v_action.id;

  perform public.log_audit_event(
    p_company_id := v_action.company_id,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action.id,
    p_event_type := 'EXCHANGE_COMMITTED',
    p_after := jsonb_build_object(
      'locked_evaluation', v_eval,
      'locked_fee_cents', v_locked_fee,
      'exception_ids', to_jsonb(v_exc_ids),
      'child_journey_id', v_child,
      'net_cents', v_net,
      'refund_owed_cents', greatest(-v_net, 0)),
    p_journey_id := v_action.journey_id,
    p_actor_employee_id := v_employee);

  -- Journey Activity on both journeys (correct_trial_start pattern).
  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain,
    source_record_id, is_internal
  ) values (
    v_action.journey_id, v_journey.customer_id,
    'internal_note', 'internal', 'internal', 'return_exchange',
    'Exchange committed by ' || coalesce(v_employee_name, 'an employee')
      || ': ' || coalesce(v_item.product_name_snapshot, 'original item')
      || ' → ' || v_repl_name,
    v_employee, 'sleep_trial_action', v_action.id, true
  );
  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain,
    source_record_id, is_internal
  ) values (
    v_child, v_journey.customer_id,
    'internal_note', 'internal', 'internal', 'return_exchange',
    'Replacement journey created by exchange (original: '
      || coalesce(v_item.product_name_snapshot, 'trial item') || ')',
    v_employee, 'sleep_trial_action', v_action.id, true
  );

  return v_child;
end;
$$;

revoke execute on function public.commit_sleep_trial_action(uuid)
  from public, anon;
grant execute on function public.commit_sleep_trial_action(uuid)
  to authenticated;

-- ============================================================================
-- 8. cancel_sleep_trial_action
--
-- COMMITTED only. Starter or a sleep_trial.complete_exchange holder.
-- Refuses once the exchange has physically or financially moved on
-- (original received, replacement delivered, any SUCCEEDED payment on
-- the child). Otherwise the child is cancelled through the normal
-- journey_cancelled event — the guard trigger passes because the
-- transaction-local flag names this action — the item reopens, and the
-- action is marked CANCELLED. Consumed exceptions are NOT restored.
-- ============================================================================

create or replace function public.cancel_sleep_trial_action(
  p_action_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_journey public.sleep_journeys%rowtype;
  v_employee uuid;
  v_employee_name text;
  v_can_complete boolean;
begin
  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id
  for update;
  if not found then
    raise exception 'Exchange action not found';
  end if;
  if not public.is_journey_visible(v_action.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select e.id, e.name into v_employee, v_employee_name
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;
  v_can_complete := public.has_permission('sleep_trial.complete_exchange');
  if v_action.created_by is distinct from v_employee
     and not v_can_complete then
    raise exception 'Only the starter or a manager can cancel this exchange';
  end if;

  if v_action.status <> 'COMMITTED' then
    raise exception 'Only a committed exchange can be cancelled (status %)',
      v_action.status;
  end if;

  if v_action.original_received_on is not null then
    raise exception 'The original mattress was already received — this exchange cannot be cancelled';
  end if;
  if exists (
    select 1 from public.sleep_journeys sj
    where sj.id = v_action.child_journey_id
      and sj.delivered_at is not null) then
    raise exception 'The replacement was already delivered — this exchange cannot be cancelled';
  end if;
  if exists (
    select 1 from public.journey_events je
    where je.journey_id = v_action.child_journey_id
      and je.event_type in ('deposit_received','payment_completed')
      and je.outcome = 'SUCCEEDED') then
    raise exception 'The replacement has a payment on record — resolve it before cancelling the exchange';
  end if;

  select * into v_journey
  from public.sleep_journeys
  where id = v_action.journey_id;

  -- Let the BEFORE INSERT guard pass for this action only, then cancel
  -- the child through the standard event (state, follow-ups, written
  -- sale and inventory hooks all hang off journey_cancelled).
  perform set_config('pillowtop.exchange_cancel', v_action.id::text, true);
  if v_action.child_journey_id is not null then
    insert into public.journey_events (
      journey_id, event_type, event_data, triggered_by
    ) values (
      v_action.child_journey_id,
      'journey_cancelled',
      jsonb_build_object(
        'reason', coalesce(nullif(btrim(p_reason), ''), 'Exchange cancelled')),
      auth.uid()::text
    );
  end if;

  perform public.stv_action_reopen_item(v_action.trial_item_id);

  update public.sleep_trial_actions
  set status = 'CANCELLED',
      cancelled_by = v_employee,
      cancelled_at = now(),
      cancel_reason = nullif(btrim(p_reason), '')
  where id = v_action.id;

  perform public.log_audit_event(
    p_company_id := v_action.company_id,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action.id,
    p_event_type := 'EXCHANGE_CANCELLED',
    p_after := jsonb_build_object(
      'status', 'CANCELLED',
      'reason', nullif(btrim(p_reason), ''),
      'child_journey_id', v_action.child_journey_id),
    p_journey_id := v_action.journey_id,
    p_actor_employee_id := v_employee);

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain,
    source_record_id, is_internal
  ) values (
    v_action.journey_id, v_journey.customer_id,
    'internal_note', 'internal', 'internal', 'return_exchange',
    'Exchange cancelled by ' || coalesce(v_employee_name, 'an employee')
      || coalesce(' — ' || nullif(btrim(p_reason), ''), ''),
    v_employee, 'sleep_trial_action', v_action.id, true
  );
  if v_action.child_journey_id is not null then
    insert into public.journey_interactions (
      journey_id, customer_id, interaction_type, channel, direction,
      topic, summary, created_by_employee_id, source_domain,
      source_record_id, is_internal
    ) values (
      v_action.child_journey_id, v_journey.customer_id,
      'internal_note', 'internal', 'internal', 'return_exchange',
      'Replacement journey cancelled with the exchange',
      v_employee, 'sleep_trial_action', v_action.id, true
    );
  end if;
end;
$$;

revoke execute on function public.cancel_sleep_trial_action(uuid, text)
  from public, anon;
grant execute on function public.cancel_sleep_trial_action(uuid, text)
  to authenticated;

-- ============================================================================
-- 9. record_exchange_refund
--
-- complete_exchange holder, COMMITTED only. Documents the money returned
-- to the customer when refund_owed_cents > 0. The amount must equal the
-- owed refund unless the caller is documenting a different settled
-- amount, which requires a non-empty reference.
-- ============================================================================

create or replace function public.record_exchange_refund(
  p_action_id uuid,
  p_method text,
  p_amount_cents integer,
  p_reference text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_employee uuid;
begin
  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id
  for update;
  if not found then
    raise exception 'Exchange action not found';
  end if;
  if not public.is_journey_visible(v_action.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  if not public.has_permission('sleep_trial.complete_exchange') then
    raise exception 'Missing permission: sleep_trial.complete_exchange';
  end if;
  select e.id into v_employee
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;

  if v_action.status <> 'COMMITTED' then
    raise exception 'Only a committed exchange can record a refund (status %)',
      v_action.status;
  end if;
  if coalesce(v_action.refund_owed_cents, 0) <= 0 then
    raise exception 'No refund is owed on this exchange';
  end if;
  if v_action.refund_recorded_at is not null then
    raise exception 'A refund was already recorded on this exchange';
  end if;

  if p_method not in ('card','cash','check','store_credit','none') then
    raise exception 'refund method must be card, cash, check, store_credit or none';
  end if;
  if p_amount_cents is null or p_amount_cents < 0 then
    raise exception 'refund amount must be a non-negative integer cents value';
  end if;
  if p_amount_cents is distinct from v_action.refund_owed_cents
     and nullif(btrim(coalesce(p_reference, '')), '') is null then
    raise exception 'The amount differs from the owed refund — a reference is required to document a different settled amount';
  end if;

  update public.sleep_trial_actions
  set refund_method = p_method,
      refund_amount_cents = p_amount_cents,
      refund_reference = nullif(btrim(p_reference), ''),
      refund_recorded_by = v_employee,
      refund_recorded_at = now()
  where id = v_action.id;

  perform public.log_audit_event(
    p_company_id := v_action.company_id,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action.id,
    p_event_type := 'EXCHANGE_REFUND_RECORDED',
    p_after := jsonb_build_object(
      'refund_method', p_method,
      'refund_amount_cents', p_amount_cents,
      'refund_owed_cents', v_action.refund_owed_cents,
      'refund_reference', nullif(btrim(p_reference), '')),
    p_journey_id := v_action.journey_id,
    p_actor_employee_id := v_employee);
end;
$$;

revoke execute on function public.record_exchange_refund(uuid, text, integer, text)
  from public, anon;
grant execute on function public.record_exchange_refund(uuid, text, integer, text)
  to authenticated;

-- ============================================================================
-- 10. complete_sleep_trial_action
--
-- complete_exchange holder. Milestones checked in order and refused with
-- the first unmet one: replacement delivered, original received, money
-- settled. All green closes the trial item as EXCHANGED and marks the
-- action COMPLETED. "Original received" is EB-4 functionality, so full
-- completion is unreachable until then — expected.
-- ============================================================================

create or replace function public.complete_sleep_trial_action(p_action_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_journey public.sleep_journeys%rowtype;
  v_child public.sleep_journeys%rowtype;
  v_employee uuid;
  v_employee_name text;
begin
  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id
  for update;
  if not found then
    raise exception 'Exchange action not found';
  end if;
  if not public.is_journey_visible(v_action.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  if not public.has_permission('sleep_trial.complete_exchange') then
    raise exception 'Missing permission: sleep_trial.complete_exchange';
  end if;
  select e.id, e.name into v_employee, v_employee_name
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;

  if v_action.status <> 'COMMITTED' then
    raise exception 'Only a committed exchange can be completed (status %)',
      v_action.status;
  end if;
  if v_action.action <> 'EXCHANGE' then
    raise exception 'Returns are not enabled yet';
  end if;

  select * into v_journey
  from public.sleep_journeys
  where id = v_action.journey_id;
  select * into v_child
  from public.sleep_journeys
  where id = v_action.child_journey_id;

  -- Milestones in order; refuse with the first unmet one.
  if v_action.replacement_delivered_on is null then
    raise exception 'The replacement has not been delivered yet';
  end if;
  if v_action.original_received_on is null then
    raise exception 'The original mattress has not been received yet';
  end if;
  if v_child.id is not null
     and coalesce(v_child.price, 0) > 0
     and public.total_paid(v_child.id) < v_child.price then
    raise exception 'The replacement still has an unpaid balance';
  end if;
  if coalesce(v_action.refund_owed_cents, 0) > 0
     and v_action.refund_recorded_at is null then
    raise exception 'The owed refund has not been recorded yet';
  end if;

  perform public.stv_action_close_item(v_action.trial_item_id, 'EXCHANGE');

  update public.sleep_trial_actions
  set status = 'COMPLETED',
      completed_by = v_employee,
      completed_at = now()
  where id = v_action.id;

  perform public.log_audit_event(
    p_company_id := v_action.company_id,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action.id,
    p_event_type := 'EXCHANGE_COMPLETED',
    p_after := jsonb_build_object(
      'status', 'COMPLETED',
      'child_journey_id', v_action.child_journey_id),
    p_journey_id := v_action.journey_id,
    p_actor_employee_id := v_employee);

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain,
    source_record_id, is_internal
  ) values (
    v_action.journey_id, v_journey.customer_id,
    'internal_note', 'internal', 'internal', 'return_exchange',
    'Exchange completed by ' || coalesce(v_employee_name, 'an employee')
      || ' — original closed as EXCHANGED',
    v_employee, 'sleep_trial_action', v_action.id, true
  );
  if v_action.child_journey_id is not null then
    insert into public.journey_interactions (
      journey_id, customer_id, interaction_type, channel, direction,
      topic, summary, created_by_employee_id, source_domain,
      source_record_id, is_internal
    ) values (
      v_action.child_journey_id, v_journey.customer_id,
      'internal_note', 'internal', 'internal', 'return_exchange',
      'Exchange completed — this replacement fulfilled it',
      v_employee, 'sleep_trial_action', v_action.id, true
    );
  end if;
end;
$$;

revoke execute on function public.complete_sleep_trial_action(uuid)
  from public, anon;
grant execute on function public.complete_sleep_trial_action(uuid)
  to authenticated;

-- ============================================================================
-- 11. Replacement delivered-on sync
--
-- The child's delivered_at is the delivery source of truth; the action's
-- replacement_delivered_on mirrors it for the completion milestones.
-- ============================================================================

create or replace function public.stv_exchange_delivered_sync()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company uuid;
  v_employee uuid;
begin
  if new.exchange_action_id is null
     or new.delivered_at is null
     or new.delivered_at is not distinct from old.delivered_at then
    return new;
  end if;

  update public.sleep_trial_actions a
  set replacement_delivered_on = new.delivered_at
  where a.id = new.exchange_action_id
    and a.replacement_delivered_on is distinct from new.delivered_at
  returning a.company_id into v_company;

  if v_company is null then
    return new;
  end if;

  select e.id into v_employee
  from public.employees e
  where e.auth_user_id = auth.uid();

  perform public.log_audit_event(
    p_company_id := v_company,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := new.exchange_action_id,
    p_event_type := 'EXCHANGE_REPLACEMENT_DELIVERED',
    p_after := jsonb_build_object(
      'replacement_delivered_on', new.delivered_at,
      'child_journey_id', new.id),
    p_journey_id := new.id,
    p_actor_employee_id := v_employee);

  return new;
end;
$$;

revoke execute on function public.stv_exchange_delivered_sync()
  from public, anon, authenticated;

drop trigger if exists trg_exchange_delivered_sync on public.sleep_journeys;
create trigger trg_exchange_delivered_sync
  after update of delivered_at on public.sleep_journeys
  for each row
  execute function public.stv_exchange_delivered_sync();
