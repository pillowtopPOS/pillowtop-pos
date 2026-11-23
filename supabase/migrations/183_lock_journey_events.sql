-- 183_lock_journey_events.sql
--
-- Go-live gate 9: journey_events becomes function-written end to end.
-- Commission, spiffs and bonuses all trust these events
-- (payment_completed, deposit_received, journey_updated_to_sold), and
-- until now any signed-in employee could insert most event types
-- directly through the database API.
--
-- The three event types the client still needs (quote_sent,
-- trial_completed, journey_cancelled) get a security definer path,
-- record_journey_event, which enforces the same checks every other
-- writer enforces. The table then closes to direct authenticated
-- inserts; the existing BEFORE INSERT guards
-- (trg_guard_journey_cancel_fulfillment,
-- trg_exchange_journey_cancel_guard, trg_guard_delivery_event_insert)
-- still fire on every insert including this function's, so nothing is
-- bypassed.
--
-- Security definer owners insert as the function owner, so every
-- existing writer (record_payment_event, record_payment_refund,
-- reevaluate_journey_balance, sync_journey_price,
-- evaluate_journey_inventory, reconcile_committed_shortfall,
-- book/reschedule/cancel_delivery_stop,
-- complete_journey_fulfillment, record_journey_fulfillment,
-- close_journey_if_fully_handed, cancel/complete/reopen
-- sleep_trial_action) keeps working unchanged. Verified: all of them
-- are already security definer, so this migration changes no existing
-- function bodies.
--
-- The service-role cron path (processAutomaticTransitions writing
-- trial_completed) bypasses RLS and is untouched.

-- ----------------------------------------------------------------------------
-- 1. record_journey_event: the only remaining write path for the three
--    client-owned event types. Mirrors today's client inserts exactly:
--    triggered_by is the auth user id as text, outcome is left null
--    (record_payment_event/reconcile_payment are the only outcome
--    writers), event_data defaults to '{}'.
-- ----------------------------------------------------------------------------

create or replace function public.record_journey_event(
  p_journey_id uuid,
  p_event_type public.journey_event_type,
  p_event_data jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee_id uuid;
  v_id uuid;
begin
  select e.id into v_employee_id
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_employee_id is null then
    raise exception 'Not authenticated as an employee';
  end if;

  if not public.is_journey_visible(p_journey_id) then
    raise exception 'You do not have access to this order';
  end if;

  -- The whitelist is enforced inside the function because the table
  -- itself no longer restricts event_type for definer inserts: this
  -- function is the only door, and it only opens for these three.
  if p_event_type not in (
    'quote_sent',
    'trial_completed',
    'journey_cancelled'
  ) then
    raise exception 'This event can only be recorded by the system.';
  end if;

  insert into public.journey_events (
    journey_id,
    event_type,
    event_data,
    triggered_by
  ) values (
    p_journey_id,
    p_event_type,
    coalesce(p_event_data, '{}'::jsonb),
    auth.uid()::text
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function public.record_journey_event(uuid, public.journey_event_type, jsonb)
  from public, anon;
grant execute on function public.record_journey_event(uuid, public.journey_event_type, jsonb)
  to authenticated;

-- ----------------------------------------------------------------------------
-- 2. Close the table. Drop the insert policy and revoke every write
--    privilege from the browser roles. The select policy
--    ("Journey events viewable by authenticated users") is untouched
--    so activity feeds and realtime keep working. service_role and
--    postgres keep their privileges for the cron and owner paths.
-- ----------------------------------------------------------------------------

drop policy if exists "Journey events insertable by authenticated users"
  on public.journey_events;

revoke insert, update, delete, truncate, references, trigger
  on public.journey_events from authenticated;

revoke insert, update, delete, truncate, references, trigger
  on public.journey_events from anon;
