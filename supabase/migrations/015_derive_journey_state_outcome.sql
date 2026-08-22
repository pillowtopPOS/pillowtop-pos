-- Ensure derive_journey_state only advances to Sold or creates deposit follow-ups
-- for payment events with outcome = 'SUCCEEDED'. UNKNOWN/FAILED payments stay Quoted
-- and do not create follow-ups.

create or replace function public.derive_journey_state()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  target public.journey_state;
  journey_price numeric;
  paid numeric;
  new_price numeric;
  store_rec public.stores%rowtype;
  emp_id uuid;
  follow_up_due timestamptz;
  max_due timestamptz;
  cadence int;
begin
  -- Employee who triggered this event, if any
  select id into emp_id
  from public.employees
  where auth_user_id = auth.uid();

  if new.event_type = 'journey_cancelled' then
    update public.sleep_journeys
    set cancelled_at = now(),
        cancelled_reason = coalesce(new.event_data->>'reason', 'No reason provided'),
        updated_at = now()
    where id = new.journey_id;

    update public.follow_ups
    set completed_at = now()
    where journey_id = new.journey_id
      and completed_at is null;

    return new;
  end if;

  target := public.event_to_state(new.event_type);

  if target is null then
    return new;
  end if;

  -- Payment/deposit events drive Sold only when the event itself succeeded and the running balance >= price
  if new.event_type in ('deposit_received', 'payment_completed') then
    if new.outcome = 'SUCCEEDED' then
      select price into journey_price
      from public.sleep_journeys
      where id = new.journey_id;

      paid := public.total_paid(new.journey_id);

      if journey_price is not null and paid >= journey_price then
        target := 'Sold'::public.journey_state;
      else
        target := 'Quoted'::public.journey_state;
      end if;
    else
      target := 'Quoted'::public.journey_state;
    end if;
  end if;

  if new.event_type in ('quote_created', 'quote_sent')
    and new.event_data->>'amount' ~ '^[0-9]+(\.[0-9]+)?$'
  then
    new_price := (new.event_data->>'amount')::numeric;
  end if;

  update public.sleep_journeys
  set current_state = target,
      price = coalesce(price, new_price),
      updated_at = now()
  where id = new.journey_id;

  -- Sold or cancelled journeys no longer need follow-ups
  if target = 'Sold'::public.journey_state then
    update public.follow_ups
    set completed_at = now()
    where journey_id = new.journey_id
      and completed_at is null;
  end if;

  -- Quote follow-ups: create one for each cadence entry
  if new.event_type = 'quote_sent' then
    select * into store_rec
    from public.stores
    where id = (select store_id from public.sleep_journeys where id = new.journey_id);

    for cadence in
      select jsonb_array_elements_text(coalesce(store_rec.quote_follow_up_cadence, '[1]'::jsonb))::int
    loop
      insert into public.follow_ups (journey_id, employee_id, type, due_at, notes)
      values (
        new.journey_id,
        emp_id,
        'quote',
        new.created_at + (cadence || ' days')::interval,
        'Quote follow-up (day ' || cadence || ')'
      );
    end loop;
  end if;

  -- Deposit follow-up: only for confirmed deposit events, with optional employee override within store policy
  if new.event_type = 'deposit_received' and new.outcome = 'SUCCEEDED' then
    select * into store_rec
    from public.stores
    where id = (select store_id from public.sleep_journeys where id = new.journey_id);

    follow_up_due := new.created_at + (store_rec.deposit_follow_up_default_days || ' days')::interval;
    max_due := new.created_at + (store_rec.deposit_follow_up_max_days || ' days')::interval;

    if new.event_data->>'follow_up_due_at' is not null then
      begin
        follow_up_due := (new.event_data->>'follow_up_due_at')::timestamptz;
      exception when others then
        follow_up_due := new.created_at + (store_rec.deposit_follow_up_default_days || ' days')::interval;
      end;

      if follow_up_due > max_due then
        follow_up_due := max_due;
      end if;
      if follow_up_due < new.created_at then
        follow_up_due := new.created_at;
      end if;
    end if;

    insert into public.follow_ups (journey_id, employee_id, type, due_at, notes)
    values (
      new.journey_id,
      emp_id,
      'deposit',
      follow_up_due,
      'Deposit follow-up: balance due'
    );
  end if;

  return new;
end;
$$;
