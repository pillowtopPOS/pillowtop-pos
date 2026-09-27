-- 061_delivery_date_floor.sql
--
-- set_journey_delivered_at() compared the user-entered delivered_at
-- (a store-local calendar date) against created_at::date, which Postgres
-- evaluates in the session timezone (UTC on hosted Supabase). A journey
-- created in a US evening has a UTC created date of the following day, so
-- a same-day local delivery was rejected with "before the journey was
-- created". The client-side fix alone (localDateISO) can't pass this floor.
--
-- No store timezone column exists, so the floor is relaxed by one calendar
-- day: the maximum real-world UTC offset is 14h, which never spans two
-- calendar dates. Dates more than a day before UTC creation are still
-- rejected.
create or replace function public.set_journey_delivered_at()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_date date;
  v_journey_created date;
  v_store public.stores%rowtype;
begin
  if new.event_type <> 'delivery_completed' then
    return new;
  end if;

  select sj.created_at::date into v_journey_created
  from public.sleep_journeys sj
  where sj.id = new.journey_id;

  select s.* into v_store
  from public.stores s
  join public.sleep_journeys sj on sj.store_id = s.id
  where sj.id = new.journey_id;

  if new.event_data ? 'delivered_at'
     and new.event_data->>'delivered_at' is not null then
    v_date := (new.event_data->>'delivered_at')::date;
    if v_date > current_date then
      raise exception 'Delivery date cannot be in the future';
    end if;
    if v_journey_created is not null and v_date < v_journey_created - 1 then
      raise exception 'Delivery date cannot be before the journey was created';
    end if;
  else
    v_date := new.created_at::date;
  end if;

  update public.sleep_journeys
  set delivered_at = v_date,
      trial_length_nights = coalesce(trial_length_nights, v_store.trial_length_nights),
      minimum_adjustment_nights = coalesce(minimum_adjustment_nights, v_store.minimum_adjustment_nights),
      trial_policy_snapshot = coalesce(trial_policy_snapshot, jsonb_build_object(
        'captured_at', now(),
        'trial_length_nights', v_store.trial_length_nights,
        'minimum_adjustment_nights', v_store.minimum_adjustment_nights,
        'source', 'delivery_completed'
      )),
      updated_at = now()
  where id = new.journey_id;

  return new;
end;
$$;

revoke execute on function public.set_journey_delivered_at() from public, anon, authenticated;
