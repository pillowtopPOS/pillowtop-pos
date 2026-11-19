-- 160_auto_close_fully_handed.sql
-- Slice 2a: close an order automatically when editing it leaves nothing
-- left to hand over.
--
-- Problem: an order with some items handed over can be edited (a line
-- deleted, or a quantity lowered down to the handed-over count). The
-- guards from m153 allow that, but nothing then closes the order, so it
-- sits open with "No action needed" and no way to finish it.
--
-- Fix: after a line is deleted or its quantity lowered, if every unit that
-- still exists on the order has been handed over, record the closing
-- delivery_completed event the same way record_journey_fulfillment does.
-- The existing triggers then move the order to Sleep Trial or Completed,
-- finish the delivery stop and settle stock exactly as for a normal close.
--
-- The close date, method and recorder are copied from the order's latest
-- handover, so nothing new is invented.
--
-- Also repairs any order already stuck in this state.
--
-- Rollback: drop trigger trg_zz_auto_close_fully_handed on
-- journey_line_items, then drop functions close_journey_if_fully_handed(uuid)
-- and trg_auto_close_fully_handed().

create or replace function public.close_journey_if_fully_handed(p_journey_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_j       public.sleep_journeys%rowtype;
  v_units   integer;
  v_total   integer;
  v_f       public.journey_fulfillments%rowtype;
begin
  select * into v_j from public.sleep_journeys where id = p_journey_id;
  if not found or v_j.delivered_at is not null or v_j.cancelled_at is not null then
    return false;
  end if;

  select count(*) into v_units
  from public.journey_fulfillment_units jfu
  where jfu.journey_id = p_journey_id;
  if v_units = 0 then
    return false;
  end if;

  select coalesce(sum(li.quantity), 0) into v_total
  from public.journey_line_items li
  where li.journey_id = p_journey_id;

  if v_units <> v_total then
    return false;
  end if;

  select * into v_f
  from public.journey_fulfillments f
  where f.journey_id = p_journey_id
  order by f.recorded_at desc, f.id desc
  limit 1;
  if not found then
    return false;
  end if;

  perform set_config('pillowtop.fulfillment_write', 'on', true);

  insert into public.journey_events (
    journey_id, event_type, event_data, triggered_by
  ) values (
    p_journey_id,
    'delivery_completed',
    jsonb_strip_nulls(jsonb_build_object(
      'delivered_at',     to_char(v_f.completed_on, 'YYYY-MM-DD'),
      'method',           v_f.method,
      'recorded_by',      v_f.recorded_by,
      'recorded_by_name', v_f.recorded_by_name,
      'recorded_at',      now(),
      'backdated',        v_f.backdated,
      'backdate_reason',  case when v_f.backdated then v_f.backdate_reason end,
      'auto_closed',      true
    )),
    coalesce(auth.uid()::text, 'system')
  );

  perform set_config('pillowtop.fulfillment_write', 'off', true);
  return true;
end;
$$;

revoke execute on function public.close_journey_if_fully_handed(uuid)
  from public, anon, authenticated;

create or replace function public.trg_auto_close_fully_handed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'DELETE' then
    perform public.close_journey_if_fully_handed(old.journey_id);
    return old;
  end if;
  perform public.close_journey_if_fully_handed(new.journey_id);
  return new;
end;
$$;

revoke execute on function public.trg_auto_close_fully_handed()
  from public, anon, authenticated;

drop trigger if exists trg_zz_auto_close_fully_handed on public.journey_line_items;
create trigger trg_zz_auto_close_fully_handed
  after delete or update of quantity on public.journey_line_items
  for each row execute function public.trg_auto_close_fully_handed();

-- One-time repair: orders already stuck with nothing left to hand over.
select public.close_journey_if_fully_handed(j.id)
from public.sleep_journeys j
where j.delivered_at is null
  and j.cancelled_at is null
  and exists (
    select 1 from public.journey_fulfillment_units jfu
    where jfu.journey_id = j.id
  );
