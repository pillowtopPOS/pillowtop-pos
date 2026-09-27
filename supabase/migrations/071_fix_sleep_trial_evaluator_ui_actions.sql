-- 071_fix_sleep_trial_evaluator_ui_actions.sql
--
-- Fix for 070: in stv_eval_inner, `v_ui := v_ui || 'LITERAL'` appends a
-- bare string literal to a text[]. PL/pgSQL resolves `||` there as array
-- concatenation, so the literal is parsed as an array literal and the
-- function fails at runtime with "malformed array literal". Re-create the
-- function with array_append for every element append.
--
-- Identical to the 070 version except the 16 `v_ui := v_ui || 'X'` lines
-- in the allowed_ui_actions block; jsonb `||` concatenation and the
-- ARRAY[...] constructors in the terminal-status branch are unchanged.

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
    elsif coalesce((v_perms ->> 'can_request')::boolean, false)
          or coalesce((v_perms ->> 'can_override_protector')::boolean, false) then
      if v_x_res ->> 'reason_code' in ('MINIMUM_NIGHTS_NOT_MET','FEE_WINDOW_PROHIBITED')
         and coalesce((v_x_res ->> 'exception_available')::boolean, false)
         and coalesce((v_perms ->> 'can_request')::boolean, false) then
        v_ui := array_append(v_ui, 'REQUEST_EARLY_EXCHANGE_EXCEPTION');
      end if;
      if v_x_res ->> 'reason_code' = 'EXCHANGE_LIMIT_REACHED'
         and coalesce((v_perms ->> 'can_request')::boolean, false) then
        v_ui := array_append(v_ui, 'REQUEST_EXTRA_EXCHANGE_EXCEPTION');
      end if;
      if v_x_res ->> 'reason_code' = 'TRIAL_EXPIRED'
         and coalesce((v_x_res ->> 'exception_available')::boolean, false)
         and coalesce((v_perms ->> 'can_request')::boolean, false) then
        v_ui := array_append(v_ui, 'REQUEST_EXPIRED_TRIAL_EXCEPTION');
      end if;
      if v_r_res ->> 'reason_code' = 'RETURNS_NOT_OFFERED'
         and coalesce((v_r_res ->> 'exception_available')::boolean, false)
         and coalesce((v_perms ->> 'can_request')::boolean, false) then
        v_ui := array_append(v_ui, 'REQUEST_RETURN_EXCEPTION');
      end if;
      if v_r_res ->> 'reason_code' = 'TRIAL_EXPIRED'
         and coalesce((v_r_res ->> 'exception_available')::boolean, false)
         and coalesce((v_perms ->> 'can_request')::boolean, false) then
        v_ui := array_append(v_ui, 'REQUEST_EXPIRED_RETURN_EXCEPTION');
      end if;
      if v_r_res ->> 'status' = 'APPROVAL_REQUIRED'
         and coalesce((v_perms ->> 'can_request')::boolean, false) then
        v_ui := array_append(v_ui, 'REQUEST_RETURN_APPROVAL');
      end if;
      v_prot_bhv := coalesce(p_terms #>> '{protector,missing_behavior}',
                             'BLOCK_WITH_OVERRIDE');
      if v_x_res ->> 'reason_code' = 'PROTECTOR_MISSING' then
        if v_prot_bhv = 'BLOCK_WITH_OVERRIDE'
           and coalesce((v_perms ->> 'can_override_protector')::boolean, false) then
          v_ui := array_append(v_ui, 'OVERRIDE_PROTECTOR_REQUIREMENT');
        elsif v_prot_bhv = 'APPROVAL_REQUIRED'
              and coalesce((v_perms ->> 'can_request')::boolean, false) then
          v_ui := array_append(v_ui, 'REQUEST_PROTECTOR_EXCEPTION');
        end if;
      end if;
      if coalesce((v_perms ->> 'can_request')::boolean, false)
         and coalesce((v_x_res #> '{fee,amount_cents}')::text::int, 0) > 0 then
        v_ui := array_append(v_ui, 'REQUEST_FEE_WAIVER');
      end if;
      if coalesce((v_perms ->> 'can_request')::boolean, false)
         and coalesce((v_trial ->> 'extensions_allowed')::boolean, false) then
        v_ui := array_append(v_ui, 'EXTEND_TRIAL_REQUEST');
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
      'term_sources', coalesce(p_facts -> 'term_sources', '{}'::jsonb)),
    'evaluated_at', now());
end;
$$;

revoke execute on function public.stv_eval_inner(jsonb, jsonb)
  from public, anon, authenticated;
