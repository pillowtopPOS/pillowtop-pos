-- PillowTop POS: real delivery date on sleep journeys.
--
-- sleep_journeys.delivered_at is the authoritative anchor for sleep-trial
-- math (trial end = delivered_at + stores.trial_length_nights). Previously
-- the trial automation used the delivery_completed event's created_at, which
-- is "when the click was recorded" rather than when delivery happened.
--
-- The column is stamped by a trigger on journey_events so every path that
-- records a delivery_completed event -- the manual Mark Delivered transition
-- (which now supplies an explicit delivered_at in event_data), the cron
-- auto-delivery in processAutomaticTransitions, or any direct insert --
-- lands the date in one place.

alter table public.sleep_journeys
  add column if not exists delivered_at date;

-- 1. Backfill: journeys that already have a delivery_completed event get the
--    latest such event's date -- the best available approximation.
update public.sleep_journeys sj
set delivered_at = sub.delivery_date
from (
  select journey_id, max(created_at)::date as delivery_date
  from public.journey_events
  where event_type = 'delivery_completed'
  group by journey_id
) sub
where sj.id = sub.journey_id
  and sj.delivered_at is null;

-- 2. Stamp delivered_at on delivery_completed events. An explicit
--    event_data.delivered_at (date string) wins; otherwise the event's own
--    created_at::date preserves the old behavior. Sanity bounds apply only
--    to explicit dates: not in the future, not before the journey existed.
create or replace function public.set_journey_delivered_at()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_date date;
  v_journey_created date;
begin
  if new.event_type <> 'delivery_completed' then
    return new;
  end if;

  select created_at::date into v_journey_created
  from public.sleep_journeys
  where id = new.journey_id;

  if new.event_data ? 'delivered_at'
     and new.event_data->>'delivered_at' is not null then
    v_date := (new.event_data->>'delivered_at')::date;
    if v_date > current_date then
      raise exception 'Delivery date cannot be in the future';
    end if;
    if v_journey_created is not null and v_date < v_journey_created then
      raise exception 'Delivery date cannot be before the journey was created';
    end if;
  else
    v_date := new.created_at::date;
  end if;

  update public.sleep_journeys
  set delivered_at = v_date, updated_at = now()
  where id = new.journey_id;

  return new;
end;
$$;

drop trigger if exists trg_set_journey_delivered_at on public.journey_events;
create trigger trg_set_journey_delivered_at
  after insert on public.journey_events
  for each row execute function public.set_journey_delivered_at();

-- Trigger-only; no caller should invoke it directly.
revoke execute on function public.set_journey_delivered_at() from public, anon, authenticated;
