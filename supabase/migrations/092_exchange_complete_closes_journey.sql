-- ============================================================================
-- Migration 092 — EB-3b follow-up: completing an exchange finishes the
-- original journey's sleep trial when nothing is left to try.
--
-- Hand test T14 showed the original journey staying in Sleep Trial for the
-- rest of the original window after complete_sleep_trial_action closed its
-- last item as EXCHANGED. Spec 5.5 / AC26: when the original item closes at
-- Complete and no other live trial items remain, the journey completes
-- normally.
--
-- Body below is the 088 complete_sleep_trial_action VERBATIM except for the
-- marked close-out block at the end: when no trial item on the original
-- journey remains ACTIVE / EXCHANGE_IN_PROGRESS / RETURN_IN_PROGRESS and the
-- journey is still in 'Sleep Trial' (not cancelled, not already Completed),
-- it inserts the same trial_completed event the automatic timer writes —
-- derive_journey_state (006b/020) maps it to Completed. The block is
-- exception-wrapped: a failure here can never undo a completed exchange.
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

  -- 092 close-out: the item just closed as EXCHANGED. When no live trial
  -- item remains on the original journey, its sleep trial is over — write
  -- the same trial_completed event the automatic timer inserts (empty
  -- event_data, triggered_by 'system'; automation.ts:44-50) and let
  -- derive_journey_state take the journey to Completed. Other live items
  -- (multi-mattress orders) leave the journey alone, as does any state
  -- where trial_completed wouldn't apply. Best-effort: this step can warn
  -- in the log but must never undo a completed exchange.
  begin
    if not exists (
      select 1
      from public.sleep_trial_items sti
      where sti.journey_id = v_action.journey_id
        and sti.status in
          ('ACTIVE','EXCHANGE_IN_PROGRESS','RETURN_IN_PROGRESS')
    ) and exists (
      select 1
      from public.sleep_journeys sj
      where sj.id = v_action.journey_id
        and sj.current_state = 'Sleep Trial'
        and sj.cancelled_at is null
    ) then
      insert into public.journey_events (
        journey_id, event_type, event_data, triggered_by
      ) values (
        v_action.journey_id, 'trial_completed', '{}'::jsonb, 'system'
      );

      insert into public.journey_interactions (
        journey_id, customer_id, interaction_type, channel, direction,
        topic, summary, created_by_employee_id, source_domain,
        source_record_id, is_internal
      ) values (
        v_action.journey_id, v_journey.customer_id,
        'internal_note', 'internal', 'internal', 'return_exchange',
        'Sleep trial completed: the exchange was completed',
        v_employee, 'sleep_trial_action', v_action.id, true
      );
    end if;
  exception
    when others then
      raise warning
        'complete_sleep_trial_action: trial_completed close-out skipped: %',
        sqlerrm;
  end;
end;
$$;

revoke execute on function public.complete_sleep_trial_action(uuid)
  from public, anon;
grant execute on function public.complete_sleep_trial_action(uuid)
  to authenticated;
