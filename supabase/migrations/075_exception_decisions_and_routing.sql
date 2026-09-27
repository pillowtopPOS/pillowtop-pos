-- 075_exception_decisions_and_routing.sql
--
-- Sleep Trial Engine, ST-6 Phase 3a (docs/sleep-trial-engine.md Sections
-- 15.5-15.8, 31): approval routing, the decide RPC, the staleness/expiry
-- mechanism, and the evaluator cutover to sleep_trial_exceptions.
--
--   1. stv_exception_approvers — the eligible-approver set for a journey.
--      "Scope includes the Journey's store" (15.5) resolves to same-company:
--      store visibility is company-wide in this app (016), there is no
--      narrower scope to check. Owners are always eligible — has_permission
--      hardcodes role 'owner' = true, and the publish guard (067) makes the
--      same assumption. Requester is excluded by the caller.
--
--   2. list_pending_exception_approvals — the My Work APPROVAL feed.
--      Derived at query time, not a stored work-item row: the approver set
--      changes as grants/employees change (E35) and a pending exception is
--      already persisted state — a copied row would just go stale.
--
--   3. stv_validate_trial_item_exception — Section 15.7 consumption-time
--      check, standalone so EXTEND_TRIAL self-consumption and the future
--      Exchange Builder share it. Writes the EXPIRED / STALE transition it
--      reports (060's committed-write expiry pattern).
--
--   4. stv_consume_trial_item_exception — marks an APPROVED row CONSUMED.
--      EXTEND_TRIAL self-consumes (Section 16); 'exchange'/'return'
--      consumed_by values are reserved for the Exchange Builder's records.
--
--   5. decide_trial_item_exception — approve as requested / approve
--      modified / deny. First decision wins via the atomic status
--      predicate (060 pattern). EXTEND_TRIAL approvals self-consume in the
--      same transaction.
--
--   6. stv_eval_one — pending/approved/extension facts now read
--      sleep_trial_exceptions (item-scoped), with a legacy-table fallback
--      only for rows that have no new-table twin. Without this the
--      request RPC's "already pending" UI gate and EXCEPTION_APPLIED
--      would keep reading a table nothing writes anymore.
--
--   7. stv_eval_action — approved exceptions now cover the blocker their
--      TYPE covers, not blindly "any approved exception covers the early-
--      exchange blockers". Required for correctness once the table holds
--      more than EARLY_EXCHANGE rows.
--
--   8. publish_sleep_trial_draft — extends the existing blocking check
--      (Section 31: "exceptions enabled with no approver role") to cover
--      trial.extensions_allowed, which also routes to approvers.
--      fees.waiver_allowed is deliberately NOT included: it defaults on,
--      so including it would block every existing company's next publish.
--
-- Deferred: in-app notification badge (no badge infrastructure exists),
-- cancel/withdraw, re-request prefill after STALE (needs Exchange
-- Builder), NON_ELIGIBLE_ITEM machinery.

-- ============================================================================
-- 1. Eligible approvers for a journey (Section 15.5)
-- ============================================================================

create or replace function public.stv_exception_approvers(
  p_journey_id uuid,
  p_exclude_employee_id uuid default null
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
            and g.permission_key = 'sleep_trial.approve_exceptions')
      )
    order by e.name;
end;
$$;

grant execute on function public.stv_exception_approvers(uuid, uuid)
  to authenticated;

-- ============================================================================
-- 2. My Work APPROVAL feed — pending exceptions the caller can decide
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

  -- Caller must be an approver (has_permission covers the owner shortcut).
  if not public.has_permission('sleep_trial.approve_exceptions') then
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
    ) r
  ), '[]'::jsonb);
end;
$$;

grant execute on function public.list_pending_exception_approvals()
  to authenticated;

-- ============================================================================
-- 3. Staleness / expiry check at consumption (Section 15.7)
--    Returns {usable, reason, detail} and persists EXPIRED / STALE when it
--    flips one. facts_hash covers trial_item_id | action | approved_terms |
--    fee_basis_cents — the same formula the request RPC writes for
--    self-authorized rows (074).
-- ============================================================================

create or replace function public.stv_validate_trial_item_exception(
  p_exception_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exc public.sleep_trial_exceptions%rowtype;
  v_item public.sleep_trial_items%rowtype;
  v_today date;
  v_hash text;
begin
  select * into v_exc
  from public.sleep_trial_exceptions
  where id = p_exception_id;
  if not found then
    return jsonb_build_object(
      'usable', false, 'reason', 'not_found',
      'detail', 'Exception not found');
  end if;

  if not public.is_journey_visible(v_exc.journey_id) then
    return jsonb_build_object(
      'usable', false, 'reason', 'not_authorized',
      'detail', 'Not authorized for this journey');
  end if;

  if v_exc.status <> 'APPROVED' then
    return jsonb_build_object(
      'usable', false,
      'reason', lower(v_exc.status::text),
      'detail', case v_exc.status
        when 'PENDING'  then 'This exception has not been decided yet'
        when 'CONSUMED' then 'This exception was already used'
        else 'This exception is ' || lower(v_exc.status::text) end);
  end if;

  select * into v_item
  from public.sleep_trial_items
  where id = v_exc.trial_item_id;
  if v_item.id is null or v_item.status in ('CLOSED','VOIDED') then
    update public.sleep_trial_exceptions
    set status = 'STALE'
    where id = v_exc.id and status = 'APPROVED';
    return jsonb_build_object(
      'usable', false, 'reason', 'stale',
      'detail', 'The trial item this approval covered is closed');
  end if;

  select public.business_today(sj.store_id) into v_today
  from public.sleep_journeys sj where sj.id = v_exc.journey_id;
  v_today := coalesce(v_today, (now() at time zone 'UTC')::date);

  if v_exc.valid_until is not null and v_today > v_exc.valid_until::date then
    update public.sleep_trial_exceptions
    set status = 'EXPIRED'
    where id = v_exc.id and status = 'APPROVED';
    return jsonb_build_object(
      'usable', false, 'reason', 'expired',
      'detail', 'Approval expired on ' || v_exc.valid_until::date);
  end if;

  -- Section 15.7: the approval covers exactly what the approver saw.
  v_hash := public.stv_sha256(
    coalesce(v_exc.trial_item_id::text, '') || '|'
    || v_exc.action || '|'
    || coalesce(v_exc.approved_terms::text, '{}') || '|'
    || coalesce(v_item.fee_basis_cents::text, ''));
  if v_exc.facts_hash is not null and v_hash <> v_exc.facts_hash then
    update public.sleep_trial_exceptions
    set status = 'STALE'
    where id = v_exc.id and status = 'APPROVED';
    return jsonb_build_object(
      'usable', false, 'reason', 'stale',
      'detail', 'Approval no longer matches (fee basis changed). Request again.');
  end if;

  return jsonb_build_object('usable', true);
end;
$$;

grant execute on function public.stv_validate_trial_item_exception(uuid)
  to authenticated;

-- ============================================================================
-- 4. Consumption. Internal: called by decide_trial_item_exception for
--    EXTEND_TRIAL now; the Exchange Builder will call it with
--    'exchange'/'return' records later. Revalidates first — a stale or
--    expired approval is never consumed (Section 31).
-- ============================================================================

create or replace function public.stv_consume_trial_item_exception(
  p_exception_id uuid,
  p_consumed_by_type text,
  p_consumed_by_id uuid,
  p_actor_employee_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exc public.sleep_trial_exceptions%rowtype;
  v_check jsonb;
  v_nights int;
begin
  select * into v_exc
  from public.sleep_trial_exceptions
  where id = p_exception_id
  for update;
  if not found then
    raise exception 'Exception not found';
  end if;

  -- EXTEND_TRIAL applies itself; every other type is consumed by a real
  -- exchange/return record that does not exist yet.
  if v_exc.exception_type = 'EXTEND_TRIAL' then
    if p_consumed_by_type is distinct from 'extension' then
      raise exception 'Extensions are consumed by the trial itself';
    end if;
  elsif p_consumed_by_type not in ('exchange','return') then
    raise exception
      'This exception type is consumed by an exchange/return record (Exchange Builder is not built yet)';
  end if;

  v_check := public.stv_validate_trial_item_exception(p_exception_id);
  if not coalesce((v_check ->> 'usable')::boolean, false) then
    raise exception 'Cannot consume this exception: %',
      coalesce(v_check ->> 'detail', v_check ->> 'reason');
  end if;

  update public.sleep_trial_exceptions
  set status = 'CONSUMED',
      consumed_at = now(),
      consumed_by_type = p_consumed_by_type,
      consumed_by_id = p_consumed_by_id
  where id = v_exc.id
    and status = 'APPROVED';
  if not found then
    raise exception 'This exception was already consumed or decided';
  end if;

  perform public.log_audit_event(
    p_company_id := v_exc.company_id,
    p_entity_type := 'sleep_trial_exception',
    p_entity_id := v_exc.id,
    p_event_type := 'SLEEP_TRIAL_EXCEPTION_CONSUMED',
    p_after := jsonb_build_object(
      'exception_type', v_exc.exception_type,
      'consumed_by_type', p_consumed_by_type,
      'consumed_by_id', p_consumed_by_id),
    p_journey_id := v_exc.journey_id,
    p_actor_employee_id := p_actor_employee_id
  );

  if v_exc.exception_type = 'EXTEND_TRIAL' then
    v_nights := coalesce(
      (v_exc.approved_terms ->> 'extension_nights')::int, 0);
    insert into public.journey_interactions (
      journey_id, customer_id, interaction_type, channel, direction,
      topic, summary, created_by_employee_id, source_domain,
      source_record_id, is_internal
    )
    select v_exc.journey_id, sj.customer_id,
      'internal_note', 'internal', 'internal', 'return_exchange',
      'Trial extended by ' || v_nights || ' nights'
        || coalesce(' — ' || nullif(btrim(v_exc.decision_note), ''), ''),
      p_actor_employee_id, 'sleep_trial_exception', v_exc.id, true
    from public.sleep_journeys sj
    where sj.id = v_exc.journey_id;
  end if;
end;
$$;

-- Internal helper — callers reach it through decide_trial_item_exception.
revoke execute on function public.stv_consume_trial_item_exception(
  uuid, text, uuid, uuid) from public, anon, authenticated;

-- ============================================================================
-- 5. decide_trial_item_exception (Sections 15.6-15.8)
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

  if not public.has_permission('sleep_trial.approve_exceptions') then
    raise exception 'You do not have permission to decide exceptions';
  end if;

  select * into v_exc
  from public.sleep_trial_exceptions
  where id = p_exception_id
  for update;
  if not found then
    raise exception 'Exception request not found';
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
      when 'EXTEND_TRIAL' then
        array['extension_nights']
      else '{}'::text[] end;

    if p_decision = 'APPROVED_AS_REQUESTED' and p_approved_terms is not null then
      raise exception
        'APPROVED_AS_REQUESTED takes no edited terms — use APPROVED_MODIFIED';
    end if;
    if p_decision = 'APPROVED_MODIFIED' then
      if p_approved_terms is null
         or jsonb_typeof(p_approved_terms) <> 'object' then
        raise exception
          'APPROVED_MODIFIED requires approved_terms (an object of edited fields)';
      end if;
      if p_approved_terms = v_exc.requested_terms then
        raise exception
          'approved_terms is identical to the request — use APPROVED_AS_REQUESTED';
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
    -- too — two pending extensions can both pass the request-time check.
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
        -- Section 15.7 — same formula the request RPC writes for
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

  -- Section 16: an extension applies itself — approve and consume in the
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
    || coalesce(' — ' || nullif(btrim(p_note), ''), '');

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
-- 6. stv_eval_one — identical to 070 except the exception facts now read
--    sleep_trial_exceptions (item-scoped), with a legacy-table fallback
--    for rows that were never migrated, plus a real extension_nights sum
--    (Section 16) and an approved_exception_type fact the coverage map in
--    stv_eval_action needs.
-- ============================================================================

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
  v_appr uuid;
  v_appr_type text;
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

  select e.id, e.exception_type::text into v_appr, v_appr_type
  from public.sleep_trial_exceptions e
  where e.trial_item_id = v_item.id
    and e.status = 'APPROVED'
    and (e.valid_until is null or e.valid_until > now())
  order by e.decided_at desc
  limit 1;

  if v_appr is null then
    select r.id, 'EARLY_EXCHANGE' into v_appr, v_appr_type
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
    'approved_exception_id', v_appr,
    'approved_exception_type', v_appr_type,
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
-- 7. stv_eval_action — identical to 072 except step 8: an approved
--    exception covers only the blocker its TYPE covers (Section 15.1
--    "Unblocks" column). With multiple types in one table, "any approved
--    exception unblocks min-nights" would let e.g. an approved
--    EXPIRED_RETURN silently unblock an exchange's minimum-nights check.
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
  v_appr_type text := p_facts ->> 'approved_exception_type';
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
    v_covers := case v_appr_type
      when 'EARLY_EXCHANGE' then
        p_action = 'EXCHANGE' and v_head ->> 'reason_code' in
          ('MINIMUM_NIGHTS_NOT_MET','FEE_WINDOW_PROHIBITED')
      when 'EXPIRED_EXCHANGE' then
        p_action = 'EXCHANGE' and v_head ->> 'reason_code' = 'TRIAL_EXPIRED'
      when 'EXTRA_EXCHANGE' then
        p_action = 'EXCHANGE' and v_head ->> 'reason_code' = 'EXCHANGE_LIMIT_REACHED'
      when 'RETURN_NOT_ALLOWED' then
        p_action = 'RETURN' and v_head ->> 'reason_code' = 'RETURNS_NOT_OFFERED'
      when 'RETURN_APPROVAL' then
        -- RETURN_NEEDS_APPROVAL only (spec 15.1). FEE_WINDOW_NEEDS_APPROVAL
        -- offers no typed exception (evaluator emits exception_type null),
        -- so nothing can be requested or approved against it yet — an
        -- approved return exception must not silently clear it.
        p_action = 'RETURN' and v_head ->> 'reason_code' = 'RETURN_NEEDS_APPROVAL'
      when 'EXPIRED_RETURN' then
        p_action = 'RETURN' and v_head ->> 'reason_code' = 'TRIAL_EXPIRED'
      else false end;
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
-- 8. publish_sleep_trial_draft — identical to 067 except the "exceptions
--    enabled with no approver role" block (Section 31) also covers
--    trial.extensions_allowed: extension requests route to approvers too.
--    fees.waiver_allowed is excluded deliberately — it defaults on, so
--    blocking on it would freeze every existing company's next publish.
-- ============================================================================

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
    or coalesce((v_draft.definition #>> '{base,trial,extensions_allowed}')::boolean, false)
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

grant execute on function public.publish_sleep_trial_draft(text, text)
  to authenticated;
