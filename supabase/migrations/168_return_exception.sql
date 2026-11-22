-- 168_return_exception.sql
--
-- One RETURN_EXCEPTION type that covers every return blocker, decided by
-- a new owner/admin permission.
--
-- Problem: a return that is not offered by policy, past the trial end
-- and needing approval took three separate exception requests and three
-- approvals (RETURN_NOT_ALLOWED covers only RETURNS_NOT_OFFERED,
-- EXPIRED_RETURN covers only TRIAL_EXPIRED, RETURN_APPROVAL covers only
-- RETURN_NEEDS_APPROVAL). A return before the minimum nights had no
-- requestable type at all.
--
-- Rule: the evaluator emits exception_type RETURN_EXCEPTION for all four
-- return blockers (RETURNS_NOT_OFFERED, MINIMUM_NIGHTS_NOT_MET,
-- TRIAL_EXPIRED, RETURN_NEEDS_APPROVAL); one approved RETURN_EXCEPTION
-- clears every blocker it covers, in order, stopping at the first
-- blocker it does not cover. Deciding it requires the new
-- sleep_trial.approve_return_exceptions key (owner, admin; not manager).
-- Older exception types behave exactly as before.
--
-- What changes:
--   1. New enum value RETURN_EXCEPTION (standalone statement below;
--      nothing in this file uses the value as an enum literal, so the
--      file runs safely inside a single transaction).
--   2. is_valid_permission_key: new key registered.
--   3. seed_sleep_trial_permission_defaults: owner + admin rows, then the
--      usual backfill over companies.
--   4. stv_exception_covers_blocker: RETURN_EXCEPTION covers all four
--      return blocker reason codes.
--   5. stv_eval_action: emits RETURN_EXCEPTION on the four return
--      blockers (MINIMUM_NIGHTS_NOT_MET now offers one for RETURN) and
--      drops covered head blockers in a loop, only for that type.
--   6. request_trial_item_exception: maps the type to RETURN and uses
--      the new key for its self-approval check.
--   7. decide_trial_item_exception: the permission check moves after the
--      row load and uses the new key for RETURN_EXCEPTION; the type
--      gains the editable approved_terms keys.
--   8. stv_exception_approvers: dropped and recreated with a
--      p_exception_type argument so it lists only holders of the right
--      approve key for that type.
--   9. list_pending_exception_approvals: pending rows are filtered to
--      what the caller can decide.
--
-- Existing exception rows, committed actions and consumed exceptions
-- are untouched. No data backfill besides the permission seed.

-- 1. New enum value. Must be its own statement and must not be used in
--    this file outside function bodies, so a single-transaction run is
--    safe.
alter type public.sleep_trial_exception_type
  add value if not exists 'RETURN_EXCEPTION';

-- ============================================================================
-- 2. is_valid_permission_key: 164 body verbatim plus the new key, so the
--    admin grant UI and grant RPCs accept it.
-- ============================================================================

create or replace function public.is_valid_permission_key(p_key text)
returns boolean
language sql
immutable
as $$
  select p_key in (
    'sleep_trial.manage_concerns',
    'sleep_trial.start_exchange',
    'sleep_trial.start_return',
    'sleep_trial.request_exceptions',
    'sleep_trial.approve_exceptions',
    'sleep_trial.approve_own_exceptions',
    'sleep_trial.approve_return_exceptions',
    'sleep_trial.override_protector',
    'sleep_trial.correct_dates',
    'sleep_trial.manage_policy',
    'sleep_trial.view_policy_details',
    'inventory.reduce_below_committed',
    'sleep_trial.complete_exchange',
    'inventory.inspect_returns',
    'inventory.manage_inspection_checklist',
    'sleep_trial.void_refund',
    'sleep_trial.reopen_action',
    'units.assign',
    'units.unassign',
    'units.override_set',
    'units.swap',
    'units.void',
    'units.manage_settings',
    'inventory.receive_po',
    'delivery.manage_trucks',
    'delivery.manage_calendar',
    'delivery.book_inside_cutoff',
    'delivery.log_confirmation_calls',
    'delivery.set_windows',
    'orders.mark_fulfilled',
    'orders.backdate_fulfillment',
    'delivery.finalize',
    'orders.pickup_any_location',
    'payments.record_refund',
    'payments.adjust_refund_amount'
  );
$$;

revoke execute on function public.is_valid_permission_key(text) from anon;

-- ============================================================================
-- 3. seed_sleep_trial_permission_defaults: 164 body verbatim plus owner
--    and admin rows for the new key (not manager), then the usual
--    backfill over companies.
-- ============================================================================

create or replace function public.seed_sleep_trial_permission_defaults(p_company_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.role_permission_grants (company_id, role, permission_key)
  select p_company_id, g.role, g.permission_key
  from (
    values
      -- manage_concerns: all roles
      ('owner',    'sleep_trial.manage_concerns'),
      ('admin',    'sleep_trial.manage_concerns'),
      ('manager',  'sleep_trial.manage_concerns'),
      ('sales',    'sleep_trial.manage_concerns'),
      ('employee', 'sleep_trial.manage_concerns'),
      -- start_exchange: all roles
      ('owner',    'sleep_trial.start_exchange'),
      ('admin',    'sleep_trial.start_exchange'),
      ('manager',  'sleep_trial.start_exchange'),
      ('sales',    'sleep_trial.start_exchange'),
      ('employee', 'sleep_trial.start_exchange'),
      -- start_return: all roles (161)
      ('owner',    'sleep_trial.start_return'),
      ('admin',    'sleep_trial.start_return'),
      ('manager',  'sleep_trial.start_return'),
      ('sales',    'sleep_trial.start_return'),
      ('employee', 'sleep_trial.start_return'),
      -- request_exceptions: all roles
      ('owner',    'sleep_trial.request_exceptions'),
      ('admin',    'sleep_trial.request_exceptions'),
      ('manager',  'sleep_trial.request_exceptions'),
      ('sales',    'sleep_trial.request_exceptions'),
      ('employee', 'sleep_trial.request_exceptions'),
      -- approve_exceptions: owner, admin, manager
      ('owner',    'sleep_trial.approve_exceptions'),
      ('admin',    'sleep_trial.approve_exceptions'),
      ('manager',  'sleep_trial.approve_exceptions'),
      -- approve_own_exceptions: owner, admin
      ('owner',    'sleep_trial.approve_own_exceptions'),
      ('admin',    'sleep_trial.approve_own_exceptions'),
      -- approve_return_exceptions (168): owner, admin
      ('owner',    'sleep_trial.approve_return_exceptions'),
      ('admin',    'sleep_trial.approve_return_exceptions'),
      -- override_protector: owner, admin
      ('owner',    'sleep_trial.override_protector'),
      ('admin',    'sleep_trial.override_protector'),
      -- correct_dates: owner, admin, manager
      ('owner',    'sleep_trial.correct_dates'),
      ('admin',    'sleep_trial.correct_dates'),
      ('manager',  'sleep_trial.correct_dates'),
      -- manage_policy: owner, admin
      ('owner',    'sleep_trial.manage_policy'),
      ('admin',    'sleep_trial.manage_policy'),
      -- view_policy_details: all roles
      ('owner',    'sleep_trial.view_policy_details'),
      ('admin',    'sleep_trial.view_policy_details'),
      ('manager',  'sleep_trial.view_policy_details'),
      ('sales',    'sleep_trial.view_policy_details'),
      ('employee', 'sleep_trial.view_policy_details'),
      -- reduce_below_committed (084 owner/manager, 085 admin):
      -- owner, admin, manager
      ('owner',    'inventory.reduce_below_committed'),
      ('admin',    'inventory.reduce_below_committed'),
      ('manager',  'inventory.reduce_below_committed'),
      -- complete_exchange (087): owner, admin
      ('owner',    'sleep_trial.complete_exchange'),
      ('admin',    'sleep_trial.complete_exchange'),
      -- inspect_returns (087): owner, admin, manager
      ('owner',    'inventory.inspect_returns'),
      ('admin',    'inventory.inspect_returns'),
      ('manager',  'inventory.inspect_returns'),
      -- manage_inspection_checklist (087): owner, admin
      ('owner',    'inventory.manage_inspection_checklist'),
      ('admin',    'inventory.manage_inspection_checklist'),
      -- void_refund (091): owner, admin
      ('owner',    'sleep_trial.void_refund'),
      ('admin',    'sleep_trial.void_refund'),
      -- reopen_action (164): admin, manager (owner implicit)
      ('admin',    'sleep_trial.reopen_action'),
      ('manager',  'sleep_trial.reopen_action'),
      -- record_refund (162): all roles (R1)
      ('owner',    'payments.record_refund'),
      ('admin',    'payments.record_refund'),
      ('manager',  'payments.record_refund'),
      ('sales',    'payments.record_refund'),
      ('employee', 'payments.record_refund'),
      -- adjust_refund_amount (162): admin, manager
      ('admin',    'payments.adjust_refund_amount'),
      ('manager',  'payments.adjust_refund_amount')
  ) as g(role, permission_key)
  on conflict (company_id, role, permission_key) do nothing;
end;
$$;

revoke execute on function public.seed_sleep_trial_permission_defaults(uuid)
  from public, anon, authenticated;

-- Backfill every existing company (new ones get it through the
-- companies-insert trigger installed in 066).
select public.seed_sleep_trial_permission_defaults(id) from public.companies;

-- ============================================================================
-- 4. stv_exception_covers_blocker: 088 body verbatim plus one case arm.
--    RETURN_EXCEPTION covers all four return blockers; the older types
--    keep their single-blocker rows.
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
  -- against it yet - an approved return exception must not silently
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
    when 'RETURN_EXCEPTION' then
      p_action = 'RETURN' and p_reason_code in
        ('RETURNS_NOT_OFFERED','MINIMUM_NIGHTS_NOT_MET','TRIAL_EXPIRED',
         'RETURN_NEEDS_APPROVAL')
    else false end;
$$;

-- Internal helper - reached through stv_eval_one's definer chain.
revoke execute on function public.stv_exception_covers_blocker(text, text, text)
  from public, anon, authenticated;

-- ============================================================================
-- 5. stv_eval_action: 088 body verbatim with five changes.
--    a. All four return blockers emit exception_type RETURN_EXCEPTION.
--    b. MINIMUM_NIGHTS_NOT_MET now offers the exception for RETURN too
--       (gated on return.exception_allowed, like RETURNS_NOT_OFFERED).
--    c. An applied RETURN_EXCEPTION keeps dropping covered head
--       blockers until the first one it does not cover; older types
--       still clear exactly one blocker.
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

  -- 1. Protector (Section 12) - hard-block precedence: a required protector
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
      'exception_type', 'RETURN_EXCEPTION');
  end if;

  -- 3. Exchange count (pair shares the count when PAIRED - counted upstream)
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
        then 'EXPIRED_EXCHANGE' else 'RETURN_EXCEPTION' end,
      'params', jsonb_build_object('end_date', v_end));
  elsif v_today < v_elig then
    v_blockers := v_blockers || jsonb_build_object(
      'status', 'NOT_YET_ELIGIBLE', 'reason_code', 'MINIMUM_NIGHTS_NOT_MET',
      'exception_available', case when p_action = 'EXCHANGE'
        then coalesce((v_x ->> 'early_exception_allowed')::boolean, false)
        else coalesce((v_r ->> 'exception_allowed')::boolean, false) end,
      'exception_type', case when p_action = 'EXCHANGE'
        then 'EARLY_EXCHANGE' else 'RETURN_EXCEPTION' end,
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
      'exception_available', true, 'exception_type', 'RETURN_EXCEPTION');
  end if;
  if v_win_outcome = 'APPROVAL_REQUIRED' then
    v_blockers := v_blockers || jsonb_build_object(
      'status', 'APPROVAL_REQUIRED', 'reason_code', 'FEE_WINDOW_NEEDS_APPROVAL',
      'exception_available', true, 'exception_type', null,
      'params', jsonb_build_object(
        'action_label', v_lbl, 'window_label', v_win_label));
  end if;

  -- 8. Approved exception: unblocks exactly the blocker its type covers
  --    (Section 15.1 "Unblocks" column). FEE_WAIVER covers no blocker - it
  --    modifies fee at consumption - and EXTEND_TRIAL covers none either.
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
      -- 168: RETURN_EXCEPTION covers every return blocker, so keep
      -- dropping heads while it covers their reason_code and stop at
      -- the first blocker it does not cover. Older types cover a
      -- single blocker: their drop above is the only one they get.
      while v_appr_type = 'RETURN_EXCEPTION'
            and jsonb_array_length(v_blockers) > 0
            and public.stv_exception_covers_blocker(
                  v_appr_type, p_action,
                  v_blockers -> 0 ->> 'reason_code') loop
        v_head := v_blockers -> 0;
        select coalesce(jsonb_agg(b.val order by b.idx), '[]'::jsonb)
        into v_blockers
        from jsonb_array_elements(v_blockers) with ordinality as b(val, idx)
        where b.idx > 1;
      end loop;
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
-- 6. request_trial_item_exception: 074 body verbatim with two changes.
--    The type maps to action RETURN, and its self-approval check uses
--    the new approve_return_exceptions key instead of
--    approve_exceptions.
-- ============================================================================

create or replace function public.request_trial_item_exception(
  p_trial_item_id uuid,
  p_exception_type public.sleep_trial_exception_type,
  p_action text default null,        -- required when p_exception_type = 'FEE_WAIVER'
  p_reason_code_id uuid default null,
  p_reason_note text default null,
  p_requested_terms jsonb default '{}'::jsonb,
  p_customer_circumstances text default null,
  p_notes text default null,
  p_attachments jsonb default '[]'::jsonb,
  p_idempotency_key text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.sleep_trial_items%rowtype;
  v_reason public.sleep_trial_exception_reasons%rowtype;
  v_employee_id uuid;
  v_today date;
  v_eval jsonb;
  v_res jsonb;
  v_action text;
  v_rule_ref text;
  v_reason_required boolean;
  v_self_auth boolean := false;
  v_valid_days int;
  v_req_nights int;
  v_status public.sleep_trial_exception_status := 'PENDING';
  v_decision public.sleep_trial_exception_decision;
  v_id uuid;
  v_cname text;
  v_event text;
  v_summary text;
begin
  -- PROTECTOR_OVERRIDE is not a requestable type here: protector overrides
  -- are a direct, self-authorized write through
  -- override_sleep_trial_protector (072) - a single audited write path.
  -- (Spec 15.4's diagram routes them through this RPC; 072 shipped the
  -- direct path first and it stays.)
  if p_exception_type = 'PROTECTOR_OVERRIDE' then
    raise exception
      'Protector overrides go through override_sleep_trial_protector, not an exception request';
  end if;

  -- Types the evaluator cannot confirm a blocker for yet: a request must
  -- never be self-authorized or queued against an unverifiable blocker.
  if p_exception_type in
     ('INSPECTION_OVERRIDE','REPLACEMENT_TRIAL','NON_ELIGIBLE_ITEM') then
    raise exception 'Not available for this exception type yet';
  end if;

  -- Type -> action. FEE_WAIVER has no fixed action: the caller says which
  -- action's fee is being waived.
  v_action := case p_exception_type
    when 'EARLY_EXCHANGE' then 'EXCHANGE'
    when 'EXPIRED_EXCHANGE' then 'EXCHANGE'
    when 'EXTRA_EXCHANGE' then 'EXCHANGE'
    when 'RETURN_NOT_ALLOWED' then 'RETURN'
    when 'RETURN_APPROVAL' then 'RETURN'
    when 'EXPIRED_RETURN' then 'RETURN'
    when 'RETURN_EXCEPTION' then 'RETURN'
    when 'EXTEND_TRIAL' then 'TRIAL'
    else p_action
  end;

  if p_exception_type = 'FEE_WAIVER' then
    if p_action is null or p_action not in ('EXCHANGE','RETURN') then
      raise exception 'A fee waiver needs an action - EXCHANGE or RETURN';
    end if;
    v_action := p_action;
  elsif p_action is not null and p_action <> v_action then
    raise exception 'action % does not match exception type %',
      p_action, p_exception_type;
  end if;

  select * into v_item from public.sleep_trial_items where id = p_trial_item_id;
  if not found then
    raise exception 'Sleep trial item not found';
  end if;
  if not public.is_journey_visible(v_item.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;
  if v_item.status in ('CLOSED','VOIDED') then
    raise exception 'This trial item is already closed';
  end if;

  if not public.has_permission('sleep_trial.request_exceptions') then
    raise exception 'You do not have permission to request exceptions';
  end if;

  select e.id into v_employee_id
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee_id is null then
    raise exception 'Employee record not found';
  end if;

  -- Idempotent retry (060 pattern): a replayed key returns the row it made.
  if p_idempotency_key is not null then
    select e.id into v_id
    from public.sleep_trial_exceptions e
    where e.idempotency_key = p_idempotency_key;
    if v_id is not null then
      return v_id;
    end if;
  end if;

  select public.business_today(sj.store_id) into v_today
  from public.sleep_journeys sj where sj.id = v_item.journey_id;
  v_today := coalesce(v_today, (now() at time zone 'UTC')::date);

  -- Re-evaluate first (Section 15.4): the request is only meaningful while
  -- the blocker it addresses is still the system's answer.
  v_eval := public.stv_eval_one(v_item.id, v_today);

  if p_exception_type = 'EXTEND_TRIAL' then
    -- No evaluator blocker corresponds to an extension; the bound terms
    -- and item status are the gate.
    if v_item.status <> 'ACTIVE' then
      raise exception 'Extensions can only be requested on an active trial';
    end if;
    if not coalesce(
      (v_item.resolved_terms #>> '{trial,extensions_allowed}')::boolean,
      false) then
      raise exception 'This item''s policy does not allow trial extensions';
    end if;
    v_req_nights := coalesce(
      (p_requested_terms ->> 'extension_nights')::int, 0);
    if v_req_nights <= 0 then
      raise exception 'requested_terms.extension_nights is required';
    end if;
    if v_req_nights > coalesce(
      (v_item.resolved_terms #>> '{trial,max_extension_nights}')::int, 0) then
      raise exception 'Requested extension exceeds the policy maximum';
    end if;
    v_rule_ref := 'trial.extensions';
  elsif p_exception_type = 'FEE_WAIVER' then
    -- A waiver modifies a fee; it unblocks nothing, so "eligible" is the
    -- normal state here. The gate is that a fee actually exists to waive.
    if not coalesce(
      (v_item.resolved_terms #>> '{fees,waiver_allowed}')::boolean,
      true) then
      raise exception 'This item''s policy does not allow fee waivers';
    end if;
    v_res := v_eval -> 'actions' -> v_action;
    if coalesce((v_res #>> '{fee,amount_cents}')::int, 0) <= 0 then
      raise exception 'There is no fee to waive for this action';
    end if;
    v_rule_ref := v_res #>> '{fee,schedule_key}';
  else
    v_res := v_eval -> 'actions' -> v_action;
    if v_res ->> 'status' = 'ELIGIBLE' then
      raise exception 'Customer is now eligible - no exception needed';
    end if;
    -- The evaluator names which exception type the current blocker takes;
    -- anything else is rejected (employees never pick from a list - 15.1).
    if v_res ->> 'exception_type' is distinct from p_exception_type::text
       or not coalesce((v_res ->> 'exception_available')::boolean, false) then
      raise exception '%', coalesce(
        v_res ->> 'explanation',
        'This exception type is not available for the current blocker');
    end if;
    v_rule_ref := v_res ->> 'reason_code';
  end if;

  -- Friendly pre-check; the unique partial index is the real guard, and
  -- the insert below converts a lost race into the same clean error.
  if exists (
    select 1 from public.sleep_trial_exceptions e
    where e.trial_item_id = v_item.id
      and e.exception_type = p_exception_type
      and e.status = 'PENDING') then
    raise exception
      'An exception request of this type is already pending for this item';
  end if;

  -- Reason validation against the bound policy's exceptions.* terms.
  if p_attachments is not null
     and jsonb_typeof(p_attachments) <> 'array' then
    raise exception 'attachments must be a jsonb array of file refs';
  end if;
  if jsonb_array_length(coalesce(p_attachments, '[]'::jsonb)) > 0
     and not coalesce(
       (v_item.resolved_terms #>> '{exceptions,attachments_allowed}')::boolean,
       true) then
    raise exception 'This item''s policy does not allow exception attachments';
  end if;

  if p_reason_code_id is not null then
    select * into v_reason
    from public.sleep_trial_exception_reasons r
    where r.id = p_reason_code_id
      and r.company_id = v_item.company_id
      and r.is_active;
    if v_reason.id is null then
      raise exception 'Unknown or inactive reason code';
    end if;
    if v_reason.requires_note
       and (p_reason_note is null or btrim(p_reason_note) = '') then
      raise exception 'A note is required for reason "%"', v_reason.label;
    end if;
  end if;
  v_reason_required := coalesce(
    (v_item.resolved_terms #>> '{exceptions,reason_required}')::boolean,
    true);
  if v_reason_required and p_reason_code_id is null then
    raise exception 'A reason code is required';
  end if;

  -- Self-authorization (Section 15.4, D10): both permissions required.
  -- One record, no pending queue - status APPROVED, decision
  -- SELF_AUTHORIZED.
  -- 168: RETURN_EXCEPTION self-approval needs approve_return_exceptions
  -- (not approve_exceptions); every other type is unchanged.
  v_self_auth := case when p_exception_type::text = 'RETURN_EXCEPTION'
       then public.has_permission('sleep_trial.approve_return_exceptions')
       else public.has_permission('sleep_trial.approve_exceptions') end
             and public.has_permission('sleep_trial.approve_own_exceptions');
  if v_self_auth then
    if coalesce(
         (v_item.resolved_terms #>> '{exceptions,self_approval_note_required}')::boolean,
         true)
       and (p_reason_note is null or btrim(p_reason_note) = '') then
      raise exception 'Self-authorized exceptions require a written note';
    end if;
    v_status := 'APPROVED';
    v_decision := 'SELF_AUTHORIZED';
  end if;

  v_valid_days := coalesce(
    (v_item.resolved_terms #>> '{exceptions,approval_valid_days}')::int, 14);

  begin
    insert into public.sleep_trial_exceptions (
      company_id, journey_id, trial_item_id,
      exception_type, action, original_evaluation,
      policy_version_id, rule_reference,
      requested_terms, reason_code_id, reason_note,
      customer_circumstances, notes, attachments,
      requester_employee_id, requested_at,
      status, decision, approved_terms,
      approver_employee_id, decided_at, self_authorized,
      valid_until, facts_hash, idempotency_key
    ) values (
      v_item.company_id, v_item.journey_id, v_item.id,
      p_exception_type, v_action, v_eval,
      v_item.policy_version_id, v_rule_ref,
      p_requested_terms, v_reason.id, nullif(btrim(coalesce(p_reason_note,'')), ''),
      p_customer_circumstances, p_notes, coalesce(p_attachments, '[]'::jsonb),
      v_employee_id, now(),
      v_status, v_decision,
      case when v_self_auth then p_requested_terms end,
      case when v_self_auth then v_employee_id end,
      case when v_self_auth then now() end,
      v_self_auth,
      case when v_self_auth
           then now() + make_interval(days => v_valid_days) end,
      case when v_self_auth then
        -- Section 15.7: the approval covers exactly these facts. (The
        -- "limit to this replacement" binding is set by the approver at
        -- decision time, which is Phase 3 - it can only apply to
        -- non-self-authorized flows anyway.)
        public.stv_sha256(
          v_item.id::text || '|' || v_action || '|'
          || coalesce(p_requested_terms::text, '{}') || '|'
          || coalesce(v_item.fee_basis_cents::text, ''))
      end,
      p_idempotency_key
    )
    returning id into v_id;
  exception
    when unique_violation then
      get stacked diagnostics v_cname = constraint_name;
      if v_cname = 'idx_sleep_trial_exceptions_pending' then
        raise exception
          'An exception request of this type is already pending for this item';
      elsif v_cname = 'idx_sleep_trial_exceptions_idempotency' then
        -- Retry raced the first write; return the row that won.
        select e.id into v_id
        from public.sleep_trial_exceptions e
        where e.idempotency_key = p_idempotency_key;
        return v_id;
      end if;
      raise;
  end;

  -- Audit + Journey Activity line (Section 15.8 pattern).
  v_event := case when v_self_auth
    then 'SLEEP_TRIAL_EXCEPTION_SELF_AUTHORIZED'
    else 'SLEEP_TRIAL_EXCEPTION_REQUESTED' end;

  perform public.log_audit_event(
    p_company_id := v_item.company_id,
    p_entity_type := 'sleep_trial_exception',
    p_entity_id := v_id,
    p_event_type := v_event,
    p_after := jsonb_build_object(
      'exception_type', p_exception_type,
      'action', v_action,
      'status', v_status,
      'decision', v_decision,
      'reason_code_id', v_reason.id,
      'reason', v_reason.label,
      'requested_terms', p_requested_terms),
    p_journey_id := v_item.journey_id,
    p_actor_employee_id := v_employee_id
  );

  v_summary := p_exception_type::text || ' exception '
    || case when v_self_auth then 'self-authorized' else 'requested' end
    || ' for ' || coalesce(v_item.product_name_snapshot, 'this mattress')
    || '. Reason: '
    || coalesce(v_reason.label, '(no reason code)')
    || coalesce(' - ' || nullif(btrim(p_reason_note), ''), '');

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain, source_record_id,
    is_internal
  )
  select v_item.journey_id, sj.customer_id,
    'customer_request', 'internal', 'internal', 'return_exchange',
    v_summary, v_employee_id, 'sleep_trial_exception', v_id, true
  from public.sleep_journeys sj
  where sj.id = v_item.journey_id;

  return v_id;
end;
$$;

revoke execute on function public.request_trial_item_exception(
  uuid, public.sleep_trial_exception_type, text, uuid, text, jsonb,
  text, text, jsonb, text)
  from public, anon;
grant execute on function public.request_trial_item_exception(
  uuid, public.sleep_trial_exception_type, text, uuid, text, jsonb,
  text, text, jsonb, text)
  to authenticated;

-- ============================================================================
-- 7. decide_trial_item_exception: 075 body verbatim with two changes.
--    The permission check moves after the exception row is loaded and
--    uses approve_return_exceptions for RETURN_EXCEPTION; other types
--    keep approve_exceptions. The new type gets the union of the old
--    return types' editable keys.
-- ============================================================================

create or replace function public.decide_trial_item_exception(
  p_exception_id uuid,
  p_decision public.sleep_trial_exception_decision,
  p_approved_terms jsonb default null,
  p_denial_reason text default null,
  p_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exc public.sleep_trial_exceptions%rowtype;
  v_item public.sleep_trial_items%rowtype;
  v_approver uuid;
  v_approver_name text;
  v_valid_days int;
  v_approved jsonb;
  v_editable text[];
  v_key text;
  v_max_ext int;
  v_ext_used int;
  v_ext_nights int;
  v_event text;
  v_summary text;
  v_consumed boolean := false;
begin
  if p_decision not in
     ('APPROVED_AS_REQUESTED','APPROVED_MODIFIED','DENIED') then
    raise exception
      'decision must be APPROVED_AS_REQUESTED, APPROVED_MODIFIED, or DENIED';
  end if;

  select e.id, e.name into v_approver, v_approver_name
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_approver is null then
    raise exception 'Employee record not found';
  end if;

  select * into v_exc
  from public.sleep_trial_exceptions
  where id = p_exception_id
  for update;
  if not found then
    raise exception 'Exception request not found';
  end if;
  -- 168: the permission check needs the loaded row's type.
  -- RETURN_EXCEPTION requires approve_return_exceptions (and not also
  -- approve_exceptions); every other type keeps approve_exceptions.
  -- Owner is implicitly allowed either way.
  if (case when v_exc.exception_type::text = 'RETURN_EXCEPTION'
          then not public.has_permission(
            'sleep_trial.approve_return_exceptions')
          else not public.has_permission('sleep_trial.approve_exceptions')
     end) then
    raise exception 'You do not have permission to decide exceptions';
  end if;
  if not public.is_journey_visible(v_exc.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;
  if v_exc.status <> 'PENDING' then
    raise exception 'This request was already decided';
  end if;
  -- Section 15.5: self-decision never goes through this RPC; the
  -- self-authorized path happens at request time (074).
  if v_exc.requester_employee_id = v_approver then
    raise exception 'You cannot decide your own exception request';
  end if;

  if v_exc.trial_item_id is not null then
    select * into v_item
    from public.sleep_trial_items where id = v_exc.trial_item_id;
  end if;

  v_approved := case p_decision
    when 'DENIED' then null
    when 'APPROVED_AS_REQUESTED' then v_exc.requested_terms
    else p_approved_terms end;

  if p_decision in ('APPROVED_AS_REQUESTED','APPROVED_MODIFIED') then
    -- Approved-terms edits are whitelisted per type (Section 15.1) and
    -- rejected outright rather than silently dropped.
    v_editable := case v_exc.exception_type
      when 'EARLY_EXCHANGE' then
        array['fee_percent_bp','fee_flat_cents','fee_amount_cents']
      when 'EXPIRED_EXCHANGE' then
        array['fee_percent_bp','fee_flat_cents','fee_amount_cents',
              'deadline_date']
      when 'EXTRA_EXCHANGE' then
        array['fee_percent_bp','fee_flat_cents','fee_amount_cents']
      when 'FEE_WAIVER' then
        array['fee_percent_bp','fee_flat_cents','fee_amount_cents']
      when 'RETURN_NOT_ALLOWED' then
        array['fee_percent_bp','fee_flat_cents','fee_amount_cents',
              'refund_method','exchange_only']
      when 'RETURN_APPROVAL' then
        array['fee_percent_bp','fee_flat_cents','fee_amount_cents',
              'refund_method']
      when 'EXPIRED_RETURN' then
        -- Spec 15.1 lists a deadline field for EXPIRED_EXCHANGE only;
        -- EXPIRED_RETURN is "fee override" alone.
        array['fee_percent_bp','fee_flat_cents','fee_amount_cents']
      when 'RETURN_EXCEPTION' then
        -- Covers every return blocker, so it takes the union of the old
        -- return types' editable keys.
        array['fee_percent_bp','fee_flat_cents','fee_amount_cents',
              'refund_method','exchange_only']
      when 'EXTEND_TRIAL' then
        array['extension_nights']
      else '{}'::text[] end;

    if p_decision = 'APPROVED_AS_REQUESTED' and p_approved_terms is not null then
      raise exception
        'APPROVED_AS_REQUESTED takes no edited terms - use APPROVED_MODIFIED';
    end if;
    if p_decision = 'APPROVED_MODIFIED' then
      if p_approved_terms is null
         or jsonb_typeof(p_approved_terms) <> 'object' then
        raise exception
          'APPROVED_MODIFIED requires approved_terms (an object of edited fields)';
      end if;
      if p_approved_terms = v_exc.requested_terms then
        raise exception
          'approved_terms is identical to the request - use APPROVED_AS_REQUESTED';
      end if;
      for v_key in select jsonb_object_keys(p_approved_terms) loop
        if not (v_key = any(v_editable)) then
          raise exception
            'approved_terms key "%" is not editable for exception type %',
            v_key, v_exc.exception_type;
        end if;
      end loop;
    end if;

    -- Section 16: the cumulative extension cap is enforced at approval
    -- too - two pending extensions can both pass the request-time check.
    if v_exc.exception_type = 'EXTEND_TRIAL' and v_item.id is not null then
      v_max_ext := coalesce(
        (v_item.resolved_terms #>> '{trial,max_extension_nights}')::int, 0);
      v_ext_nights := coalesce((v_approved ->> 'extension_nights')::int, 0);
      if v_ext_nights <= 0 then
        raise exception 'An approved extension must set extension_nights';
      end if;
      select coalesce(sum((x.approved_terms ->> 'extension_nights')::int), 0)
        into v_ext_used
      from public.sleep_trial_exceptions x
      where x.trial_item_id = v_exc.trial_item_id
        and x.exception_type = 'EXTEND_TRIAL'
        and x.status in ('APPROVED','CONSUMED')
        and x.id <> v_exc.id;
      if v_ext_used + v_ext_nights > v_max_ext then
        raise exception
          'Extension exceeds the remaining allowance (% of % nights left)',
          greatest(v_max_ext - v_ext_used, 0), v_max_ext;
      end if;
    end if;
  else
    if p_denial_reason is null or btrim(p_denial_reason) = '' then
      raise exception 'A reason is required to deny';
    end if;
  end if;

  v_valid_days := coalesce(
    (v_item.resolved_terms #>> '{exceptions,approval_valid_days}')::int, 14);

  -- Atomic decide (060 pattern): the status predicate wins races; first
  -- decision stands.
  update public.sleep_trial_exceptions
  set status = case when p_decision = 'DENIED'
                    then 'DENIED'::public.sleep_trial_exception_status
                    else 'APPROVED'::public.sleep_trial_exception_status end,
      decision = p_decision,
      approved_terms = v_approved,
      approver_employee_id = v_approver,
      decided_at = now(),
      approver_note = nullif(btrim(coalesce(p_note, '')), ''),
      decision_note = case when p_decision = 'DENIED'
        then btrim(p_denial_reason) end,
      valid_until = case when p_decision = 'DENIED' then null
        else now() + make_interval(days => v_valid_days) end,
      facts_hash = case when p_decision = 'DENIED' then null else
        -- Section 15.7 - same formula the request RPC writes for
        -- self-authorized rows.
        public.stv_sha256(
          coalesce(v_exc.trial_item_id::text, '') || '|'
          || v_exc.action || '|'
          || coalesce(v_approved::text, '{}') || '|'
          || coalesce(v_item.fee_basis_cents::text, ''))
      end
  where id = v_exc.id
    and status = 'PENDING';
  if not found then
    raise exception 'This request was already decided';
  end if;

  -- Section 16: an extension applies itself - approve and consume in the
  -- same transaction (revalidates through the Section 15.7 check first).
  if p_decision <> 'DENIED' and v_exc.exception_type = 'EXTEND_TRIAL' then
    perform public.stv_consume_trial_item_exception(
      v_exc.id, 'extension', v_exc.trial_item_id, v_approver);
    v_consumed := true;
  end if;

  v_event := case when p_decision = 'DENIED'
    then 'SLEEP_TRIAL_EXCEPTION_DENIED'
    else 'SLEEP_TRIAL_EXCEPTION_APPROVED' end;

  perform public.log_audit_event(
    p_company_id := v_exc.company_id,
    p_entity_type := 'sleep_trial_exception',
    p_entity_id := v_exc.id,
    p_event_type := v_event,
    p_before := jsonb_build_object('status', 'PENDING'),
    p_after := jsonb_build_object(
      'status', case when p_decision = 'DENIED' then 'DENIED'
                     when v_consumed then 'CONSUMED' else 'APPROVED' end,
      'decision', p_decision,
      'approved_terms', v_approved,
      'decision_note', case when p_decision = 'DENIED'
                            then btrim(p_denial_reason) end,
      'consumed', v_consumed),
    p_journey_id := v_exc.journey_id,
    p_actor_employee_id := v_approver
  );

  -- Journey Activity line (Section 15.8 wording).
  v_summary := v_exc.exception_type::text || ' exception '
    || case p_decision
         when 'DENIED' then 'denied by ' || v_approver_name
           || '. Reason: ' || btrim(p_denial_reason)
         when 'APPROVED_MODIFIED' then 'approved with changes by '
           || v_approver_name
         else 'approved by ' || v_approver_name end
    || '.'
    || coalesce(' - ' || nullif(btrim(p_note), ''), '');

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, summary, created_by_employee_id, source_domain,
    source_record_id, is_internal
  )
  select v_exc.journey_id, sj.customer_id,
    'internal_note', 'internal', 'internal', 'return_exchange',
    v_summary, v_approver, 'sleep_trial_exception', v_exc.id, true
  from public.sleep_journeys sj
  where sj.id = v_exc.journey_id;

  -- Expanded payload so the UI can render "Approved by X · valid until Y"
  -- without a refetch.
  return jsonb_build_object(
    'id', v_exc.id,
    'status', case when p_decision = 'DENIED' then 'DENIED'
                   when v_consumed then 'CONSUMED' else 'APPROVED' end,
    'decision', p_decision,
    'approved_terms', v_approved,
    'valid_until', case when p_decision = 'DENIED' then null
      else now() + make_interval(days => v_valid_days) end,
    'approver_name', v_approver_name,
    'consumed', v_consumed);
end;
$$;

revoke execute on function public.decide_trial_item_exception(
  uuid, public.sleep_trial_exception_decision, jsonb, text, text)
  from public, anon;
grant execute on function public.decide_trial_item_exception(
  uuid, public.sleep_trial_exception_decision, jsonb, text, text)
  to authenticated;

-- ============================================================================
-- 8. stv_exception_approvers: dropped and recreated with
--    p_exception_type so the eligible set holds the right approve key
--    for that type. Callers that pass the old two arguments still work:
--    the new parameter defaults to null and resolves to
--    approve_exceptions, exactly the old behavior.
-- ============================================================================

drop function if exists public.stv_exception_approvers(uuid, uuid);

create or replace function public.stv_exception_approvers(
  p_journey_id uuid,
  p_exclude_employee_id uuid default null,
  p_exception_type text default null
)
returns table (employee_id uuid, employee_name text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company uuid;
begin
  if not public.is_journey_visible(p_journey_id) then
    return;
  end if;

  select s.company_id into v_company
  from public.sleep_journeys sj
  join public.stores s on s.id = sj.store_id
  where sj.id = p_journey_id;
  if v_company is null then
    return;
  end if;

  return query
    select e.id, e.name
    from public.employees e
    join public.stores s on s.id = e.home_store_id
    where s.company_id = v_company
      and e.is_active
      and e.id is distinct from p_exclude_employee_id
      and (
        -- has_permission hardcodes owner = true; mirror it so the owner is
        -- eligible even when no grant row exists for 'owner'.
        e.role::text = 'owner'
        or exists (
          select 1 from public.role_permission_grants g
          where g.company_id = v_company
            and g.role = e.role::text
            and g.permission_key = case
              when p_exception_type = 'RETURN_EXCEPTION'
                then 'sleep_trial.approve_return_exceptions'
              else 'sleep_trial.approve_exceptions' end)
      )
    order by e.name;
end;
$$;

grant execute on function public.stv_exception_approvers(uuid, uuid, text)
  to authenticated;

-- ============================================================================
-- 9. list_pending_exception_approvals: 075 body verbatim with one
--    change: pending rows are filtered to the types the caller can
--    decide, so RETURN_EXCEPTION rows only reach holders of the new key
--    (the gate widens to either approve key).
-- ============================================================================

create or replace function public.list_pending_exception_approvals()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_employee uuid;
begin
  select e.id into v_employee
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    return '[]'::jsonb;
  end if;

  -- Caller must be an approver of something (has_permission covers the
  -- owner shortcut); the row filter below limits them to what they can
  -- actually decide.
  if not (public.has_permission('sleep_trial.approve_exceptions')
          or public.has_permission('sleep_trial.approve_return_exceptions')) then
    return '[]'::jsonb;
  end if;

  return coalesce((
    select jsonb_agg(r.row order by r.requested_at)
    from (
      select
        e.requested_at,
        jsonb_build_object(
          'id', e.id,
          'journey_id', e.journey_id,
          'trial_item_id', e.trial_item_id,
          'exception_type', e.exception_type,
          'action', e.action,
          'rule_reference', e.rule_reference,
          'requested_terms', e.requested_terms,
          'requested_at', e.requested_at,
          'requester_employee_id', e.requester_employee_id,
          'requester_name', req.name,
          'reason_label', rc.label,
          'reason_note', e.reason_note,
          'customer_name', c.first_name || ' ' || c.last_name
        ) as row
      from public.sleep_trial_exceptions e
      join public.sleep_journeys sj on sj.id = e.journey_id
      join public.customers c on c.id = sj.customer_id
      join public.employees req on req.id = e.requester_employee_id
      left join public.sleep_trial_exception_reasons rc
        on rc.id = e.reason_code_id
      where e.status = 'PENDING'
        and public.is_journey_visible(e.journey_id)
        -- Self-decision is never a queue item (Section 15.5).
        and e.requester_employee_id <> v_employee
        -- 168: only rows the caller can decide. RETURN_EXCEPTION needs
        -- the new key; every other type needs approve_exceptions.
        and case when e.exception_type::text = 'RETURN_EXCEPTION'
                 then public.has_permission(
                   'sleep_trial.approve_return_exceptions')
                 else public.has_permission('sleep_trial.approve_exceptions')
            end
    ) r
  ), '[]'::jsonb);
end;
$$;

grant execute on function public.list_pending_exception_approvals()
  to authenticated;
