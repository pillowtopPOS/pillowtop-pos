-- 074_request_trial_item_exception.sql
--
-- Sleep Trial Engine, ST-6 Phase 2a (docs/sleep-trial-engine.md Sections
-- 15.2, 15.4): the request RPC for sleep_trial_exceptions.
--
-- Deliberate divergences from spec 15.4's flow diagram (approved):
--   * PROTECTOR_OVERRIDE is rejected here. Protector overrides are a
--     direct, self-authorized write through override_sleep_trial_protector
--     (072) — not a request. Keeping them out preserves a single audited
--     write path for that departure.
--   * INSPECTION_OVERRIDE, REPLACEMENT_TRIAL, NON_ELIGIBLE_ITEM are hard-
--     rejected: the evaluator cannot yet confirm those blockers (and
--     NON_ELIGIBLE_ITEM is journey-scoped — the approval creates the
--     item), so a request would have nothing auditable to stand on.
--   * Named request_trial_item_exception rather than overloading the
--     legacy request_sleep_trial_exception (070) — PostgREST overload
--     resolution is unreliable when most parameters are optional, and
--     nothing calls this yet.
--
-- Still Phase-scoped out: approver notification/routing (Phase 3, My
-- Work), decide/cancel RPCs, consumption + staleness enforcement at
-- commit, and rewiring the evaluator's pending/approved fact reads off
-- sleep_trial_exception_requests.

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
  -- override_sleep_trial_protector (072) — a single audited write path.
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
    when 'EXTEND_TRIAL' then 'TRIAL'
    else p_action
  end;

  if p_exception_type = 'FEE_WAIVER' then
    if p_action is null or p_action not in ('EXCHANGE','RETURN') then
      raise exception 'A fee waiver needs an action — EXCHANGE or RETURN';
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
      raise exception 'Customer is now eligible — no exception needed';
    end if;
    -- The evaluator names which exception type the current blocker takes;
    -- anything else is rejected (employees never pick from a list — 15.1).
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
  -- One record, no pending queue — status APPROVED, decision
  -- SELF_AUTHORIZED.
  v_self_auth := public.has_permission('sleep_trial.approve_exceptions')
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
        -- decision time, which is Phase 3 — it can only apply to
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
    || coalesce(' — ' || nullif(btrim(p_reason_note), ''), '');

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
