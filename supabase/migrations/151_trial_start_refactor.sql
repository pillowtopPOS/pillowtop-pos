-- 151_trial_start_refactor.sql
-- Slice 2 (per-item fulfillment) step 2: behavior-neutral refactor of trial
-- activation.
--
-- What it does:
--   * Extracts the per-item start/correction logic out of
--     stv_on_journey_delivered into a new helper, public.stv_start_trial_item,
--     so the later record_journey_fulfillment RPC can start a single unit's
--     trial on its own handover date.
--   * Rewrites stv_on_journey_delivered to call the helper and to skip any
--     item that already has a journey_fulfillment_units row (matched on
--     sleep_trial_item_id, or on the same line_item_id + unit_index). The
--     skip covers BOTH the PENDING_FULFILLMENT start branch and the ACTIVE
--     correction branch, so a unit started on its own fulfillment date is
--     never re-dated to the closing delivered_at.
--
-- Replaces: stv_on_journey_delivered as defined in
--   supabase/migrations/069_sleep_trial_items.sql lines 799-889
--   (the only and therefore latest definition; verified by grep across all
--   migrations). The per-item body is taken verbatim from m069:826-885.
--   Helper calls (log_audit_event from m066:182, stv_audit_trial_failure from
--   m069:587) are unchanged.
--
-- Behavior: identical while journey_fulfillment_units has no rows (the skip
-- condition can never match). The trigger trg_stv_journey_delivered and its
-- firing condition are untouched and not recreated.
--
-- Rollback: recreate stv_on_journey_delivered from
-- supabase/migrations/069_sleep_trial_items.sql:799-889 and drop
-- public.stv_start_trial_item(uuid, date, text).

create or replace function public.stv_start_trial_item(
  p_item_id uuid,
  p_start_date date,
  p_source text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item record;
  v_actor uuid;
  v_count_starts text;
  v_new_start date;
  v_fee_cents int;
begin
  select sti.*, jli.unit_price, jli.fulfillment_type_override
  into v_item
  from public.sleep_trial_items sti
  left join public.journey_line_items jli on jli.id = sti.line_item_id
  where sti.id = p_item_id;
  if not found then
    return;
  end if;

  select e.id into v_actor
  from public.employees e
  where e.auth_user_id = auth.uid();

  v_count_starts := v_item.resolved_terms #>> '{trial,count_starts}';
  v_new_start := case
    when v_count_starts = 'FULFILLMENT_DATE' then p_start_date
    else p_start_date + 1 end;

  if v_item.status = 'PENDING_FULFILLMENT' then
    -- Section 13.2: until the pricing engine exists, the fee basis is the
    -- line's unit_price.
    v_fee_cents := case when v_item.unit_price is not null
                        then round(v_item.unit_price * 100)::int end;

    update public.sleep_trial_items
    set status = 'ACTIVE',
        started_on = v_new_start,
        start_source = p_source,
        fee_basis_cents = coalesce(fee_basis_cents, v_fee_cents),
        fee_basis_source = coalesce(fee_basis_source,
          case when v_fee_cents is not null then 'UNIT_PRICE' end),
        updated_at = now()
    where id = v_item.id;

    perform public.log_audit_event(
      v_item.company_id,
      'sleep_trial_item', v_item.id, 'SLEEP_TRIAL_STARTED',
      jsonb_build_object('status', 'PENDING_FULFILLMENT'),
      jsonb_build_object('status', 'ACTIVE', 'started_on', v_new_start,
                         'start_source', p_source,
                         'fee_basis_cents', v_fee_cents),
      null, null, v_item.journey_id, 'EMPLOYEE', v_actor);

  elsif v_item.status = 'ACTIVE'
        and v_item.started_on is distinct from v_new_start then
    update public.sleep_trial_items
    set started_on = v_new_start,
        start_source = 'CORRECTION',
        updated_at = now()
    where id = v_item.id;

    perform public.log_audit_event(
      v_item.company_id,
      'sleep_trial_item', v_item.id, 'SLEEP_TRIAL_START_CORRECTED',
      jsonb_build_object('started_on', v_item.started_on),
      jsonb_build_object('started_on', v_new_start),
      null, null, v_item.journey_id, 'EMPLOYEE', v_actor);
  end if;
end;
$$;

revoke execute on function public.stv_start_trial_item(uuid, date, text)
  from public, anon, authenticated;

create or replace function public.stv_on_journey_delivered()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item record;
  v_count_starts text;
  v_new_start date;
  v_start_source text;
begin
  if new.delivered_at is null
     or new.delivered_at is not distinct from old.delivered_at then
    return new;
  end if;

  -- A trial problem must never block a delivery record.
  begin
  for v_item in
    select sti.id, sti.line_item_id, sti.unit_index,
           jli.fulfillment_type_override
    from public.sleep_trial_items sti
    left join public.journey_line_items jli on jli.id = sti.line_item_id
    where sti.journey_id = new.id
      and sti.status in ('PENDING_FULFILLMENT','ACTIVE')
      -- Slice 2: units already handed over carry their own fulfillment
      -- record and their own start date; the closing event must not
      -- re-date them (covers both the start and correction branches).
      and not exists (
        select 1 from public.journey_fulfillment_units jfu
        where jfu.sleep_trial_item_id = sti.id
           or (jfu.line_item_id = sti.line_item_id
               and jfu.unit_index = sti.unit_index)
      )
  loop
    v_start_source := case
      when coalesce(v_item.fulfillment_type_override, new.fulfillment_type) = 'pickup'
        then 'PICKUP' else 'DELIVERY' end;

    perform public.stv_start_trial_item(v_item.id, new.delivered_at, v_start_source);
  end loop;

  exception when others then
    perform public.stv_audit_trial_failure(
      (select s.company_id from public.stores s where s.id = new.store_id),
      new.id, 'SLEEP_TRIAL_START_FAILED', sqlerrm);
  end;

  return new;
end;
$$;

revoke execute on function public.stv_on_journey_delivered() from public, anon, authenticated;
