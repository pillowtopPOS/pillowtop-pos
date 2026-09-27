-- 065_follow_ups_write_lockdown.sql
--
-- follow_ups still carried the 004 direct insert/update RLS policies and the
-- default Supabase write grants, so a logged-in user could bypass the
-- security-definer RPCs — create follow-ups for any employee, edit other
-- people's follow-ups, or skip idempotency keys. All creation already goes
-- through RPCs (record_payment_event, reconcile_payment_event,
-- derive_journey_state, record_journey_interaction,
-- append_sleep_concern_entry, schedule_interaction_follow_up); this adds the
-- missing completion RPC, then makes the RPCs the only write path.

create or replace function public.complete_follow_up(p_follow_up_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_journey_id uuid;
  v_opportunity_id uuid;
begin
  select journey_id, opportunity_id
  into v_journey_id, v_opportunity_id
  from public.follow_ups
  where id = p_follow_up_id;

  if v_journey_id is null and v_opportunity_id is null then
    raise exception 'Follow-up not found';
  end if;

  -- Same visibility rule as the 004 select policy: journey-visible, or the
  -- linked opportunity's store is visible.
  if not (
    (v_journey_id is not null and public.is_journey_visible(v_journey_id))
    or exists (
      select 1 from public.opportunities o
      where o.id = v_opportunity_id
        and public.is_store_visible(o.store_id)
    )
  ) then
    raise exception 'Not authorized for this follow-up';
  end if;

  -- Completing an already-completed follow-up is a no-op, not an error.
  update public.follow_ups
  set completed_at = now()
  where id = p_follow_up_id
    and completed_at is null;

  return p_follow_up_id;
end;
$$;

grant execute on function public.complete_follow_up(uuid) to authenticated;

-- Nothing in the app writes follow_ups directly anymore, so the direct-write
-- policies and default grants go away. Select stays untouched.
drop policy if exists "Follow ups insertable by authenticated users" on public.follow_ups;
drop policy if exists "Follow ups updatable by authenticated users" on public.follow_ups;

revoke insert, update, delete on public.follow_ups from anon, authenticated;
