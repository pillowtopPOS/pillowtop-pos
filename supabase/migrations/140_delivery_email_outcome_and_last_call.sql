-- PillowTop POS m140: "Sent email" confirmation outcome + company
-- last-call reminder time. Idempotent: safe to re-run.
--
--   1. journey_interactions.contact_outcome CHECK gains 'emailed' in
--      the CONFIRMATION namespace (SCHEDULING list unchanged).
--   2. log_delivery_confirmation accepts 'emailed'. Legacy mapping
--      follows left_voicemail exactly: outcome 'no_response',
--      waiting_on 'customer', summary phrase 'emailed customer.'.
--   3. get_delivery_confirmation_list is re-issued verbatim: the
--      status derivation's `else c.last_outcome` branch already maps
--      a last outcome of 'emailed' to status 'emailed', exactly like
--      'left_voicemail' (including an email logged after a Confirmed
--      call, which flips the status back to needing attention).
--   4. companies.delivery_last_call_time (time, nullable): the
--      company-wide "second call" reminder moment. Null = off.
--
-- Grants are re-applied exactly as installed; the verification query
-- is at the bottom of this file.

-- ============================================================================
-- 1. contact_outcome CHECK: add 'emailed' to CONFIRMATION only.
-- ============================================================================

alter table public.journey_interactions
  drop constraint if exists journey_interactions_contact_outcome_check;

alter table public.journey_interactions
  add constraint journey_interactions_contact_outcome_check
  check (
    (purpose = 'CONFIRMATION'
      and contact_outcome in (
        'confirmed', 'left_voicemail', 'no_answer', 'emailed',
        'wrong_number', 'needs_different_day')
      and stop_id is not null)
    or (purpose <> 'CONFIRMATION'
      and (contact_outcome is null
           or (purpose = 'SCHEDULING' and contact_outcome in (
             'spoke', 'voicemail', 'no_answer', 'texted',
             'will_call_back', 'not_ready', 'wrong_number'))))
  ) not valid;

comment on column public.journey_interactions.contact_outcome is
  'Structured delivery-contact outcome. SCHEDULING values: spoke, voicemail, no_answer, texted, will_call_back, not_ready, wrong_number. CONFIRMATION values: confirmed, left_voicemail, no_answer, emailed, wrong_number, needs_different_day (stop_id required).';

-- ============================================================================
-- 2. log_delivery_confirmation - identical to m138 except 'emailed' is a
--    valid outcome, maps to the same legacy outcome/waiting_on as
--    left_voicemail, and gets the summary phrase 'emailed customer.'.
-- ============================================================================

create or replace function public.log_delivery_confirmation(
  p_journey_id uuid,
  p_stop_id uuid,
  p_outcome text,
  p_note text default null,
  p_occurred_at timestamptz default null,
  p_idempotency_key text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_employee_id uuid;
  v_customer_id uuid;
  v_company_id uuid;
  v_stop record;
  v_day_mode text;
  v_occurred timestamptz;
  v_summary text;
  v_legacy_outcome text;
  v_waiting_on text;
  v_snapshot jsonb;
  v_interaction_id uuid;
  v_existing_id uuid;
  v_existing_journey uuid;
  v_existing_employee uuid;
begin
  if not public.has_permission('delivery.log_confirmation_calls') then
    raise exception 'You do not have permission to log confirmation calls.';
  end if;

  select e.id, s.company_id
    into v_employee_id, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid() and e.is_active;
  if v_employee_id is null then
    raise exception 'Employee record not found';
  end if;

  select sj.customer_id into v_customer_id
  from public.sleep_journeys sj
  join public.stores st on st.id = sj.store_id
  where sj.id = p_journey_id
    and st.company_id = v_company_id;
  if v_customer_id is null then
    raise exception 'Order not found';
  end if;

  select ds.id, ds.journey_id, ds.delivery_date, ds.truck_id,
         ds.window_start, ds.window_end
    into v_stop
  from public.delivery_stops ds
  where ds.id = p_stop_id
    and ds.journey_id = p_journey_id
    and ds.company_id = v_company_id
    and ds.status = 'BOOKED';
  if v_stop.id is null then
    raise exception 'That delivery stop does not belong to this order';
  end if;
  if v_stop.delivery_date < public.delivery_company_today() then
    raise exception 'That delivery day has already passed';
  end if;

  if p_outcome is null or p_outcome not in (
    'confirmed', 'left_voicemail', 'no_answer', 'emailed',
    'wrong_number', 'needs_different_day') then
    raise exception 'Choose a valid confirmation outcome';
  end if;

  v_occurred := coalesce(p_occurred_at, now());
  if v_occurred > now() + interval '5 minutes' then
    raise exception 'The contact time cannot be in the future';
  end if;
  if v_occurred < now() - interval '7 days' then
    raise exception 'The contact time cannot be more than 7 days ago';
  end if;

  select c.delivery_day_mode into v_day_mode
  from public.companies c where c.id = v_company_id;

  v_snapshot := jsonb_build_object(
    'delivery_date', v_stop.delivery_date,
    'window_start', case when v_day_mode = 'day_only' then null
                         else v_stop.window_start end,
    'window_end', case when v_day_mode = 'day_only' then null
                       else v_stop.window_end end,
    'truck_id', v_stop.truck_id);

  -- Provisional legacy mapping, same style as the SCHEDULING rows.
  -- 'emailed' falls through the same else branches as 'left_voicemail':
  -- outcome 'no_response', waiting_on 'customer'.
  v_legacy_outcome := case p_outcome
    when 'confirmed' then 'resolved'
    when 'needs_different_day' then 'follow_up_needed'
    else 'no_response' end;
  v_waiting_on := case p_outcome
    when 'confirmed' then 'nothing'
    else 'customer' end;
  v_summary := 'Delivery confirmation call: ' ||
    case p_outcome
      when 'confirmed' then 'customer confirmed.'
      when 'left_voicemail' then 'left voicemail.'
      when 'no_answer' then 'no answer.'
      when 'emailed' then 'emailed customer.'
      when 'wrong_number' then 'wrong number.'
      else 'customer needs a different day.' end;

  if p_note is not null and btrim(p_note) <> '' then
    v_summary := v_summary || ' ' || btrim(p_note);
  end if;

  -- Idempotent retry: same journey and same employee only, exactly
  -- like log_delivery_contact.
  if p_idempotency_key is not null then
    select id, journey_id, created_by_employee_id
      into v_existing_id, v_existing_journey, v_existing_employee
    from public.journey_interactions
    where idempotency_key = p_idempotency_key;
    if v_existing_id is not null then
      if v_existing_journey = p_journey_id
         and v_existing_employee = v_employee_id then
        return jsonb_build_object(
          'interaction_id', v_existing_id, 'deduplicated', true);
      end if;
      raise exception 'That request key was already used for a different order.';
    end if;
  end if;

  insert into public.journey_interactions (
    journey_id, customer_id, interaction_type, channel, direction,
    topic, topic_label, summary, outcome, waiting_on, commitment_made,
    occurred_at, created_by_employee_id, source_domain, is_internal,
    purpose, contact_outcome, callback_after, stop_id, window_snapshot,
    company_id, idempotency_key
  ) values (
    p_journey_id, v_customer_id, 'called_customer', 'phone_outbound',
    'outbound', 'delivery', 'Delivery confirmation', v_summary,
    v_legacy_outcome, v_waiting_on, null,
    v_occurred, v_employee_id, 'manual', false,
    'CONFIRMATION', p_outcome, null, p_stop_id, v_snapshot,
    v_company_id, p_idempotency_key
  )
  on conflict (idempotency_key) where idempotency_key is not null
  do nothing
  returning id into v_interaction_id;

  if v_interaction_id is null then
    select id, journey_id, created_by_employee_id
      into v_existing_id, v_existing_journey, v_existing_employee
    from public.journey_interactions
    where idempotency_key = p_idempotency_key;
    if v_existing_id is not null then
      if v_existing_journey = p_journey_id
         and v_existing_employee = v_employee_id then
        return jsonb_build_object(
          'interaction_id', v_existing_id, 'deduplicated', true);
      end if;
      raise exception 'That request key was already used for a different order.';
    end if;
    raise exception 'Could not log the delivery confirmation. Please try again.';
  end if;

  return jsonb_build_object(
    'interaction_id', v_interaction_id, 'deduplicated', false);
end;
$$;

revoke execute on function public.log_delivery_confirmation(uuid, uuid, text, text, timestamptz, text)
  from public, anon;
grant execute on function public.log_delivery_confirmation(uuid, uuid, text, text, timestamptz, text)
  to authenticated;

-- ============================================================================
-- 3. get_delivery_confirmation_list - re-issued verbatim from m138. The
--    status derivation needs no change: `else c.last_outcome` already
--    yields 'emailed' for a last outcome of 'emailed', behaving exactly
--    like 'left_voicemail' (an email logged after a Confirmed call
--    makes the status 'emailed', i.e. still needing attention).
-- ============================================================================

create or replace function public.get_delivery_confirmation_list(
  p_date date default null,
  p_scope text default 'mine'
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_employee_id uuid;
  v_company_id uuid;
  v_tomorrow date;
  v_date date;
  v_mode text;
  v_day_start time;
  v_day_end time;
  v_dates jsonb;
  v_items jsonb;
begin
  select e.id, s.company_id
    into v_employee_id, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid() and e.is_active;
  if v_company_id is null then
    raise exception 'Only active employees can view the confirmation list.';
  end if;
  if not public.has_permission('delivery.log_confirmation_calls') then
    raise exception 'You do not have permission to view the confirmation list.';
  end if;
  if p_scope is null or p_scope not in ('mine', 'all') then
    raise exception 'Scope must be mine or all.';
  end if;

  select c.delivery_day_mode, c.delivery_day_start, c.delivery_day_end
    into v_mode, v_day_start, v_day_end
  from public.companies c where c.id = v_company_id;

  v_tomorrow := public.delivery_company_today() + 1;

  if p_date is null then
    select min(ds.delivery_date) into v_date
    from public.delivery_stops ds
    where ds.company_id = v_company_id
      and ds.status = 'BOOKED'
      and ds.delivery_date >= v_tomorrow;
  else
    v_date := p_date;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'date', d.delivery_date, 'stop_count', d.n
    ) order by d.delivery_date), '[]'::jsonb)
  into v_dates
  from (
    select ds.delivery_date, count(*) as n
    from public.delivery_stops ds
    where ds.company_id = v_company_id
      and ds.status = 'BOOKED'
      and ds.delivery_date >= v_tomorrow
    group by ds.delivery_date
    order by ds.delivery_date
    limit 7
  ) d;

  if v_date is null then
    return jsonb_build_object(
      'date', null, 'day_mode', v_mode,
      'day_start', v_day_start, 'day_end', v_day_end,
      'available_dates', v_dates, 'scope', p_scope, 'items', '[]'::jsonb);
  end if;

  with stops as (
    select
      ds.id as stop_id,
      ds.journey_id,
      ds.delivery_date,
      ds.truck_id,
      ds.route_position,
      ds.booked_by,
      ds.window_start,
      ds.window_end,
      sj.journey_number,
      sj.assigned_employee_id,
      sj.customer_id,
      cu.first_name || ' ' || cu.last_name as customer_name,
      cu.phone as customer_phone,
      cu.email as customer_email,
      nullif(trim(concat_ws(', ',
        nullif(trim(concat_ws(' ', cu.street_address, cu.street_address_line_2)), ''),
        nullif(trim(concat_ws(' ', cu.city, cu.state, cu.zip_code)), '')
      )), '') as delivery_address,
      t.name as truck_name,
      t.sort_order as truck_sort_order,
      ae.name as assigned_employee_name
    from public.delivery_stops ds
    join public.sleep_journeys sj on sj.id = ds.journey_id
    join public.stores st on st.id = sj.store_id
    join public.customers cu on cu.id = sj.customer_id
    left join public.delivery_trucks t on t.id = ds.truck_id
    left join public.employees ae on ae.id = sj.assigned_employee_id
    where ds.company_id = v_company_id
      and ds.delivery_date = v_date
      and ds.status = 'BOOKED'
      and st.company_id = v_company_id
      and (p_scope = 'all'
           or sj.assigned_employee_id = v_employee_id
           or (sj.assigned_employee_id is null
               and ds.booked_by = v_employee_id))
  ),
  conf as (
    select
      ji.stop_id,
      count(*) as attempts,
      (array_agg(ji.contact_outcome
        order by ji.occurred_at desc, ji.recorded_at desc))[1] as last_outcome,
      (array_agg(ji.occurred_at
        order by ji.occurred_at desc, ji.recorded_at desc))[1] as last_at,
      (array_agg(ji.summary
        order by ji.occurred_at desc, ji.recorded_at desc))[1] as last_note,
      (array_agg(ji.window_snapshot
        order by ji.occurred_at desc, ji.recorded_at desc))[1] as last_snapshot,
      (array_agg(ji.created_by_employee_id
        order by ji.occurred_at desc, ji.recorded_at desc))[1] as last_employee_id
    from public.journey_interactions ji
    where ji.company_id = v_company_id
      and ji.purpose = 'CONFIRMATION'
      and ji.stop_id is not null
      and ji.entered_in_error_at is null
      and ji.stop_id in (select s.stop_id from stops s)
    group by ji.stop_id
  )
  select coalesce(jsonb_agg(x.jb order by
      x.truck_sort_order nulls last, x.truck_name nulls last,
      x.truck_id nulls last,
      x.route_position nulls last, x.customer_name, x.stop_id),
    '[]'::jsonb)
  into v_items
  from (
    select
      jsonb_build_object(
        'stop_id', s.stop_id,
        'journey_id', s.journey_id,
        'journey_number', s.journey_number,
        'customer_name', s.customer_name,
        'customer_phone', s.customer_phone,
        'customer_email', s.customer_email,
        'delivery_address', s.delivery_address,
        'truck_id', s.truck_id,
        'truck_name', s.truck_name,
        'route_position', s.route_position,
        'window_start', case when v_mode = 'day_only' then null else s.window_start end,
        'window_end', case when v_mode = 'day_only' then null else s.window_end end,
        'outside_day_hours',
          case
            when v_mode = 'day_only' or s.window_start is null then false
            else s.window_start < v_day_start or s.window_end > v_day_end
          end,
        'assigned_employee_id', s.assigned_employee_id,
        'assigned_employee_name', s.assigned_employee_name,
        'status',
          case
            when c.stop_id is null then 'not_called'
            when c.last_outcome = 'confirmed'
                 and (c.last_snapshot ->> 'delivery_date') = s.delivery_date::text
                 and (v_mode = 'day_only'
                      or (((c.last_snapshot ->> 'window_start')
                            is not distinct from
                           (case when s.window_start is null then null
                                 else to_char(s.window_start, 'HH24:MI:SS') end))
                          and ((c.last_snapshot ->> 'window_end')
                            is not distinct from
                           (case when s.window_end is null then null
                                 else to_char(s.window_end, 'HH24:MI:SS') end))))
              then 'confirmed'
            when c.last_outcome = 'confirmed' then 'confirmed_window_changed'
            else c.last_outcome
          end,
        'attempts', coalesce(c.attempts, 0),
        'last_call', case when c.stop_id is null then null else jsonb_build_object(
          'outcome', c.last_outcome,
          'occurred_at', c.last_at,
          'by_name', be.name,
          'note', c.last_note,
          'window_snapshot', c.last_snapshot
        ) end
      ) as jb,
      s.truck_id,
      s.truck_sort_order,
      s.truck_name,
      s.route_position,
      s.customer_name,
      s.stop_id
    from stops s
    left join conf c on c.stop_id = s.stop_id
    left join public.employees be on be.id = c.last_employee_id
  ) x;

  return jsonb_build_object(
    'date', v_date,
    'day_mode', v_mode,
    'day_start', v_day_start,
    'day_end', v_day_end,
    'available_dates', v_dates,
    'scope', p_scope,
    'items', v_items);
end;
$$;

revoke execute on function public.get_delivery_confirmation_list(date, text)
  from public, anon;
grant execute on function public.get_delivery_confirmation_list(date, text)
  to authenticated;

-- ============================================================================
-- 4. companies.delivery_last_call_time - company-wide "second call"
--    reminder moment. Null means the feature is OFF.
-- ============================================================================

alter table public.companies
  add column if not exists delivery_last_call_time time;

comment on column public.companies.delivery_last_call_time is
  'Company time-of-day for the last-call confirmation reminder. Null disables the reminder. Company timezone clock.';

-- ============================================================================
-- Grant verification (run after install):
--   select p.proname, r.rolname
--   from pg_proc p
--   join pg_namespace n on n.oid = p.pronamespace
--   cross join lateral aclexplode(p.proacl) a
--   join pg_roles r on r.oid = a.grantee
--   where n.nspname = 'public'
--     and p.proname in ('log_delivery_confirmation',
--                       'get_delivery_confirmation_list')
--   order by p.proname, r.rolname;
-- Expect EXECUTE for authenticated only on both functions.
-- ============================================================================
