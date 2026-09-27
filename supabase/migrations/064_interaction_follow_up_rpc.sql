-- PillowTop POS: schedule a follow-up on an existing interaction.
--
-- follow_ups rows were previously created only as a side effect of
-- record_journey_interaction / append_sleep_concern_entry, so there was
-- no way to attach a follow-up to an interaction after saving it.
-- This RPC does that, with the same is_journey_visible check as
-- record_journey_interaction, server-side employee resolution, and an
-- idempotency key so retries/double-clicks cannot duplicate the task.

create or replace function public.schedule_interaction_follow_up(
  p_interaction_id uuid,
  p_due_at timestamptz,
  p_method text,
  p_notes text,
  p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee_id uuid;
  v_journey_id uuid;
  v_summary text;
  v_error_at timestamptz;
  v_id uuid;
begin
  select journey_id, summary, entered_in_error_at
  into v_journey_id, v_summary, v_error_at
  from public.journey_interactions
  where id = p_interaction_id;

  if v_journey_id is null then
    raise exception 'Interaction not found';
  end if;

  if v_error_at is not null then
    raise exception 'Cannot schedule a follow-up on an entry marked entered in error';
  end if;

  if not public.is_journey_visible(v_journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  if p_due_at is null then
    raise exception 'Follow-up due date is required';
  end if;

  select id into v_employee_id
  from public.employees
  where auth_user_id = auth.uid();

  if v_employee_id is null then
    raise exception 'Employee record not found';
  end if;

  -- Atomic idempotency claim, same pattern as record_journey_interaction.
  insert into public.follow_ups (
    journey_id,
    employee_id,
    type,
    due_at,
    notes,
    method,
    journey_interaction_id,
    idempotency_key
  ) values (
    v_journey_id,
    v_employee_id,
    'interaction',
    p_due_at,
    coalesce(
      nullif(btrim(coalesce(p_notes, '')), ''),
      'Follow up: ' || left(btrim(v_summary), 120)
    ),
    nullif(btrim(coalesce(p_method, '')), ''),
    p_interaction_id,
    p_idempotency_key
  )
  on conflict (idempotency_key) where idempotency_key is not null
  do nothing
  returning id into v_id;

  if v_id is null then
    -- Lost the race (or a double-click retry): return the winner's row.
    select id into v_id
    from public.follow_ups
    where idempotency_key = p_idempotency_key;
  end if;

  return v_id;
end;
$$;

grant execute on function public.schedule_interaction_follow_up(uuid,timestamptz,text,text,text) to authenticated;
