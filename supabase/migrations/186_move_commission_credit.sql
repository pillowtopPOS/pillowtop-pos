-- ============================================================================
-- 186: move commission credit and adjustment wording (C5 slice 2)
--
--   1. User-facing adjustment labels are computed at read time. Stored
--      flags, internal function names and audit event names do not change.
--   2. move_commission_credit moves the whole order's commission credit
--      after delivery by appending signed ADJUSTMENT rows. SPIFF rows are
--      never touched. Closed pay periods are skipped forward by the 185
--      landing helper.
--   3. get_credit_move_info feeds the modal without exposing cost.
--   4. The unit-earning unique index now protects only earning kinds.
--      Positive move rows are ADJUSTMENT rows with reverses_entry_id null
--      by design, and more than one move over time must be able to credit
--      the same employee on the same unit. Reversal rows remain protected
--      by the 185 source unique index; positive rows get a source unique
--      index keyed by unit and employee.
--
--   Re-runnable: or replace / if exists / if not exists throughout.
-- ============================================================================

-- ============================================================================
-- 1. idx_commission_entries_unit_earning originally covered ADJUSTMENT too.
--    Return adjustments always have reverses_entry_id set, so nothing was
--    lost there, but credit-move positive rows deliberately have it null.
--    Recreate the guard for the earning kinds it was meant to protect.
-- ============================================================================

drop index if exists public.idx_commission_entries_unit_earning;
create unique index if not exists idx_commission_entries_unit_earning
  on public.commission_entries (fulfillment_unit_id, employee_id, kind)
  where fulfillment_unit_id is not null
    and reverses_entry_id is null
    and kind in ('COMMISSION', 'SPIFF');

create unique index if not exists idx_commission_entries_credit_move_source
  on public.commission_entries (
    fulfillment_unit_id, employee_id, clawback_source_id)
  where clawback_source_id is not null
    and reverses_entry_id is null;

-- ============================================================================
-- 2. commission_write_clawback: the shared return, exchange and
--    unlinked-refund writer. Units never involved in a move keep the exact
--    185 arithmetic; moved units use per-employee net positions so returns
--    land on the current holder. Notes are normalized to adjustment wording.
-- ============================================================================

create or replace function public.commission_write_clawback(
  p_entry_id uuid,
  p_share_bp integer,
  p_source_id uuid,
  p_flags text[],
  p_earned_date date,
  p_period_start date,
  p_note text
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_orig public.commission_entries%rowtype;
  v_net integer;
  v_room integer;
  v_prop integer;
  v_take integer;
  v_amount integer;
  v_rev integer;
  v_cost integer;
  v_inserted integer;
  v_note text;
  v_has_move boolean;
  v_max_net_revenue integer;
  v_remaining_bp numeric;
  v_take_bp numeric;
  v_emp record;
  v_positive public.commission_entries%rowtype;
  v_written integer := 0;
begin
  select * into v_orig
  from public.commission_entries
  where id = p_entry_id
    and kind = 'COMMISSION'
    and reverses_entry_id is null;
  if not found then
    return 'SKIP_NO_ORIGINAL';
  end if;

  v_note := case
    when p_note is null then null
    else replace(replace(replace(p_note,
      'Unlinked refund clawback', 'Refund adjustment'),
      'Exchange clawback', 'Exchange adjustment'),
      'Return clawback', 'Return adjustment')
  end;

  select exists (
    select 1
    from public.commission_entries ce
    where ce.fulfillment_unit_id = v_orig.fulfillment_unit_id
      and ce.kind = 'ADJUSTMENT'
      and 'CREDIT_MOVED' = any(ce.flags)
  ) into v_has_move;

  -- Units never involved in a credit move keep the exact 185 per-original
  -- arithmetic. Apart from the note normalization above, this branch is the
  -- 185 writer unchanged, including its rounding and cap behaviour.
  if not v_has_move then
    if v_orig.amount_cents is null then
      return 'SKIP_NULL_AMOUNT';
    end if;

    select coalesce(sum(a.amount_cents), 0) into v_net
    from public.commission_entries a
    where a.kind = 'ADJUSTMENT'
      and (a.reverses_entry_id = v_orig.id
           or a.reverses_entry_id in (
             select c.id
             from public.commission_entries c
             where c.reverses_entry_id = v_orig.id));

    v_room := v_orig.amount_cents + v_net;
    if v_room = 0 then
      return 'SKIP_NO_ROOM';
    end if;

    v_prop := floor(
      v_orig.amount_cents::numeric * p_share_bp / 10000 + 0.5)::integer;
    v_take := least(abs(v_prop), abs(v_room));
    if v_take <= 0 then
      return 'SKIP_NO_ROOM';
    end if;
    v_amount := case when v_room > 0 then -v_take else v_take end;

    v_rev := case when v_orig.revenue_cents is null then null
                  else -1 * floor(v_orig.revenue_cents::numeric
                                  * p_share_bp / 10000
                                  * v_take / abs(v_prop) + 0.5)::integer end;
    v_cost := case when v_orig.cost_cents is null then null
                   else -1 * floor(v_orig.cost_cents::numeric
                                   * p_share_bp / 10000
                                   * v_take / abs(v_prop) + 0.5)::integer end;

    insert into public.commission_entries (
      company_id, journey_id, line_item_id, fulfillment_unit_id,
      employee_id, store_id, kind, amount_cents, earned_at, earned_date,
      pay_period_start, revenue_cents, cost_cents, rate_bp,
      credit_share_bp, flags, reverses_entry_id, note,
      clawback_source_id
    ) values (
      v_orig.company_id, v_orig.journey_id, v_orig.line_item_id,
      v_orig.fulfillment_unit_id, v_orig.employee_id, v_orig.store_id,
      'ADJUSTMENT', v_amount, now(), p_earned_date, p_period_start,
      v_rev, v_cost, v_orig.rate_bp, v_orig.credit_share_bp,
      p_flags, v_orig.id, v_note, p_source_id
    )
    on conflict (reverses_entry_id, clawback_source_id)
      where clawback_source_id is not null
    do nothing;

    get diagnostics v_inserted = row_count;
    return case when v_inserted > 0 then 'WRITTEN' else 'DUPLICATE' end;
  end if;

  -- Once a unit has moved credit, the original row's reversal chain no
  -- longer describes who currently holds the commission. Work from the
  -- net position of every employee on the fulfillment unit instead. The
  -- caller loops over split original rows, so rows already written for
  -- this unit and source make the later calls duplicates.
  if v_orig.fulfillment_unit_id is null then
    return 'SKIP_NO_ORIGINAL';
  end if;

  if exists (
    select 1
    from public.commission_entries ce
    where ce.fulfillment_unit_id = v_orig.fulfillment_unit_id
      and ce.kind = 'ADJUSTMENT'
      and ce.clawback_source_id = p_source_id
      and not ('CLAWBACK_VOIDED' = any(ce.flags))
  ) then
    return 'DUPLICATE';
  end if;

  if v_orig.revenue_cents is null or v_orig.revenue_cents <= 0 then
    return 'SKIP_NO_ROOM';
  end if;

  with positions as (
    select ce.employee_id,
           sum(ce.amount_cents)::integer as net_amount,
           sum(ce.revenue_cents)::integer as net_revenue,
           sum(ce.cost_cents)::integer as net_cost
    from public.commission_entries ce
    where ce.fulfillment_unit_id = v_orig.fulfillment_unit_id
      and ce.kind in ('COMMISSION', 'ADJUSTMENT')
    group by ce.employee_id
  )
  select max(p.net_revenue)::integer
    into v_max_net_revenue
  from positions p;

  if v_max_net_revenue is null or v_max_net_revenue <= 0 then
    return 'SKIP_NO_ROOM';
  end if;

  v_remaining_bp := least(
    10000::numeric,
    10000::numeric * v_max_net_revenue / v_orig.revenue_cents);
  if v_remaining_bp <= 0 then
    return 'SKIP_NO_ROOM';
  end if;

  v_take_bp := least(p_share_bp::numeric, v_remaining_bp);
  if v_take_bp <= 0 then
    return 'SKIP_NO_ROOM';
  end if;

  for v_emp in
    select ce.employee_id,
           sum(ce.amount_cents)::integer as net_amount,
           sum(ce.revenue_cents)::integer as net_revenue,
           sum(ce.cost_cents)::integer as net_cost
    from public.commission_entries ce
    where ce.fulfillment_unit_id = v_orig.fulfillment_unit_id
      and ce.kind in ('COMMISSION', 'ADJUSTMENT')
    group by ce.employee_id
    order by ce.employee_id
  loop
    if coalesce(v_emp.net_amount, 0) = 0 then
      continue;
    end if;

    select ce.* into v_positive
    from public.commission_entries ce
    where ce.fulfillment_unit_id = v_orig.fulfillment_unit_id
      and ce.employee_id = v_emp.employee_id
      and ce.reverses_entry_id is null
      and (ce.kind = 'COMMISSION'
           or (ce.kind = 'ADJUSTMENT'
               and 'CREDIT_MOVED' = any(ce.flags)))
      and not exists (
        select 1
        from public.commission_entries mr
        where mr.reverses_entry_id = ce.id
          and mr.kind = 'ADJUSTMENT'
          and 'CREDIT_MOVED' = any(mr.flags)
      )
    order by ce.created_at desc, ce.id desc
    limit 1;

    if v_positive.id is null then
      continue;
    end if;

    v_amount := -1 * round(
      v_emp.net_amount::numeric * v_take_bp / v_remaining_bp)::integer;
    if v_amount = 0 then
      continue;
    end if;

    v_rev := case when v_emp.net_revenue is null then null
                  else -1 * round(v_emp.net_revenue::numeric
                                  * v_take_bp / v_remaining_bp)::integer end;
    v_cost := case when v_emp.net_cost is null then null
                   else -1 * round(v_emp.net_cost::numeric
                                   * v_take_bp / v_remaining_bp)::integer end;

    insert into public.commission_entries (
      company_id, journey_id, line_item_id, fulfillment_unit_id,
      employee_id, store_id, kind, amount_cents, earned_at, earned_date,
      pay_period_start, revenue_cents, cost_cents, rate_bp,
      credit_share_bp, flags, reverses_entry_id, note,
      clawback_source_id
    ) values (
      v_positive.company_id, v_positive.journey_id, v_positive.line_item_id,
      v_orig.fulfillment_unit_id, v_emp.employee_id, v_positive.store_id,
      'ADJUSTMENT', v_amount, now(), p_earned_date, p_period_start,
      v_rev, v_cost, v_positive.rate_bp, v_positive.credit_share_bp,
      p_flags, v_positive.id, v_note, p_source_id
    )
    on conflict (reverses_entry_id, clawback_source_id)
      where clawback_source_id is not null
    do nothing;

    get diagnostics v_inserted = row_count;
    v_written := v_written + v_inserted;
  end loop;

  if v_written > 0 then
    return 'WRITTEN';
  end if;

  if exists (
    select 1
    from public.commission_entries ce
    where ce.fulfillment_unit_id = v_orig.fulfillment_unit_id
      and ce.kind = 'COMMISSION'
      and ce.reverses_entry_id is null
      and ce.amount_cents is null
  ) then
    return 'SKIP_NULL_AMOUNT';
  end if;

  return 'SKIP_NO_ROOM';
end;
$$;

revoke execute on function public.commission_write_clawback(
  uuid, integer, uuid, text[], date, date, text)
  from public, anon, authenticated;

-- ============================================================================
-- 3. commission_void_clawbacks: unchanged reversal math, new note wording.
-- ============================================================================

create or replace function public.commission_void_clawbacks(
  p_source_id uuid
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cb public.commission_entries%rowtype;
  v_landing record;
  v_flags text[];
  v_inserted integer;
  v_written integer := 0;
begin
  for v_cb in
    select ce.*
    from public.commission_entries ce
    where ce.clawback_source_id = p_source_id
      and ce.kind = 'ADJUSTMENT'
      and not ('CLAWBACK_VOIDED' = any(ce.flags))
      and not exists (
        select 1
        from public.commission_entries v
        where v.reverses_entry_id = ce.id
          and v.kind = 'ADJUSTMENT'
      )
  loop
    select * into v_landing
    from public.commission_landing_for(
      v_cb.company_id,
      coalesce(public.business_today(v_cb.store_id), current_date));
    if v_landing.earned_date is null then
      continue;
    end if;

    v_flags := array['CLAWBACK_VOIDED'];
    if v_landing.landed_late then
      v_flags := array_append(v_flags, 'LANDED_IN_LATER_PERIOD'::text);
    end if;

    insert into public.commission_entries (
      company_id, journey_id, line_item_id, fulfillment_unit_id,
      employee_id, store_id, kind, amount_cents, earned_at, earned_date,
      pay_period_start, revenue_cents, cost_cents, rate_bp,
      credit_share_bp, flags, reverses_entry_id, note,
      clawback_source_id
    ) values (
      v_cb.company_id, v_cb.journey_id, v_cb.line_item_id,
      v_cb.fulfillment_unit_id, v_cb.employee_id, v_cb.store_id,
      'ADJUSTMENT', -1 * v_cb.amount_cents, now(),
      v_landing.earned_date, v_landing.pay_period_start,
      case when v_cb.revenue_cents is null then null
           else -1 * v_cb.revenue_cents end,
      case when v_cb.cost_cents is null then null
           else -1 * v_cb.cost_cents end,
      v_cb.rate_bp, v_cb.credit_share_bp, v_flags, v_cb.id,
      'Adjustment reversed', p_source_id
    )
    on conflict (reverses_entry_id, clawback_source_id)
      where clawback_source_id is not null
    do nothing;

    get diagnostics v_inserted = row_count;
    v_written := v_written + v_inserted;
  end loop;

  return v_written;
end;
$$;

revoke execute on function public.commission_void_clawbacks(uuid)
  from public, anon, authenticated;

-- ============================================================================
-- 4. list_commission_entries: read-time labels. Existing rows written by
--    185 pick up the new wording without a data rewrite. Exchange rows are
--    identified through clawback_source_id, either directly when the source
--    is the completed action or through the linked action id on a refund
--    journey event.
-- ============================================================================

create or replace function public.list_commission_entries(
  p_from date,
  p_to date,
  p_employee_id uuid default null
)
returns table(
  entry_id uuid,
  earned_date date,
  pay_period_start date,
  employee_id uuid,
  employee_name text,
  journey_id uuid,
  journey_number text,
  item_name text,
  kind text,
  amount_cents integer,
  revenue_cents integer,
  cost_cents integer,
  rate_bp integer,
  credit_share_bp integer,
  flags text[],
  type_label text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  if not public.has_permission('commission.manage') then
    raise exception 'You do not have permission to view commissions';
  end if;

  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  return query
    select ce.id, ce.earned_date, ce.pay_period_start, ce.employee_id,
           emp.name, ce.journey_id, sj.journey_number, li.item_name,
           ce.kind, ce.amount_cents, ce.revenue_cents, ce.cost_cents,
           ce.rate_bp, ce.credit_share_bp, ce.flags,
           case
             when ce.kind = 'SPIFF' then coalesce(
               sr.name,
               case when ce.review_spiff_id is not null
                    then 'Google review'
                    else 'Spiff' end)
             when ce.kind = 'ADJUSTMENT' then case
               when 'CREDIT_MOVED' = any(ce.flags)
                 then 'Credit moved'
               when 'CLAWBACK_VOIDED' = any(ce.flags)
                 then 'Adjustment reversed'
               when 'UNLINKED_REFUND' = any(ce.flags)
                 then 'Refund adjustment'
               when 'RETURN_CLAWBACK' = any(ce.flags)
                 then case
                   when exists (
                     select 1
                     from public.sleep_trial_actions sta
                     where sta.id = ce.clawback_source_id
                       and sta.action = 'EXCHANGE'
                   ) or exists (
                     select 1
                     from public.journey_events je
                     join public.sleep_trial_actions sta
                       on sta.id = nullif(je.event_data ->> 'action_id', '')::uuid
                     where je.id = ce.clawback_source_id
                       and sta.action = 'EXCHANGE'
                   ) then 'Exchange adjustment'
                   else 'Return adjustment'
                 end
               else 'Adjustment' end
             else 'Commission'
           end
    from public.commission_entries ce
    join public.employees emp on emp.id = ce.employee_id
    join public.sleep_journeys sj on sj.id = ce.journey_id
    left join public.journey_line_items li on li.id = ce.line_item_id
    left join public.spiff_rules sr on sr.id = ce.spiff_rule_id
    where ce.company_id = v_company_id
      and (p_from is null or ce.earned_date >= p_from)
      and (p_to is null or ce.earned_date <= p_to)
      and (p_employee_id is null or ce.employee_id = p_employee_id)
    order by ce.earned_date desc
    limit 2000;
end;
$$;

revoke execute on function public.list_commission_entries(date, date, uuid)
  from public, anon;
grant execute on function public.list_commission_entries(date, date, uuid)
  to authenticated;

-- ============================================================================
-- 5. get_my_earnings: same own-rows read as 185, plus type_label inside each
--    line. No cost visibility rule changes. CREDIT_MOVED rows are not part
--    of returns_cents, so the Returns footer keeps its existing meaning.
-- ============================================================================

create or replace function public.get_my_earnings(p_date date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_emp_id uuid;
  v_company_id uuid;
  v_start date;
  v_end date;
  v_is_closed boolean;
  v_show_revenue boolean;
  v_show_rate boolean;
  v_show_profit boolean;
  v_cost_switch boolean;
  v_show_draw boolean;
  v_cost_basis text;
  v_show_cost boolean;
  v_lines jsonb;
  v_total integer;
  v_pending integer;
  v_draw integer;
  v_returns integer;
begin
  select e.id, s.company_id into v_emp_id, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_emp_id is null or v_company_id is null then
    return null;
  end if;

  select c.earnings_show_revenue, c.earnings_show_rate,
         c.earnings_show_profit, c.earnings_show_cost,
         c.earnings_show_draw_progress, c.commission_cost_basis
    into v_show_revenue, v_show_rate, v_show_profit,
         v_cost_switch, v_show_draw, v_cost_basis
  from public.companies c
  where c.id = v_company_id;

  v_show_cost := coalesce(v_cost_switch, false)
                 and v_cost_basis = 'COMMISSION_COST';

  select p.period_start, p.period_end, p.is_closed
    into v_start, v_end, v_is_closed
  from public.commission_payout_period_for(v_company_id, p_date) p;

  select coalesce(
           jsonb_agg(l.line order by l.earned_date, l.created_at),
           '[]'::jsonb
         ),
         coalesce(sum(l.amount_cents), 0)::integer,
         count(*) filter (where l.pending)::integer,
         coalesce(
           sum(l.amount_cents) filter (where l.is_return), 0)::integer
    into v_lines, v_total, v_pending, v_returns
  from (
    select jsonb_build_object(
             'entry_id', ce.id,
             'earned_date', ce.earned_date,
             'journey_id', ce.journey_id,
             'journey_number', sj.journey_number,
             'item_name', li.item_name,
             'kind', ce.kind,
             'amount_cents', ce.amount_cents,
             'pending', (ce.amount_cents is null),
             'type_label',
               case
                 when ce.kind = 'ADJUSTMENT' then case
                   when 'CREDIT_MOVED' = any(ce.flags)
                     then 'Credit moved'
                   when 'CLAWBACK_VOIDED' = any(ce.flags)
                     then 'Adjustment reversed'
                   when 'UNLINKED_REFUND' = any(ce.flags)
                     then 'Refund adjustment'
                   when 'RETURN_CLAWBACK' = any(ce.flags)
                     then case
                       when exists (
                         select 1
                         from public.sleep_trial_actions sta
                         where sta.id = ce.clawback_source_id
                           and sta.action = 'EXCHANGE'
                       ) or exists (
                         select 1
                         from public.journey_events je
                         join public.sleep_trial_actions sta
                           on sta.id = nullif(je.event_data ->> 'action_id', '')::uuid
                         where je.id = ce.clawback_source_id
                           and sta.action = 'EXCHANGE'
                       ) then 'Exchange adjustment'
                       else 'Return adjustment'
                     end
                   else 'Adjustment' end
                 else 'Commission'
               end
           )
           || case when v_show_revenue then
                jsonb_build_object('revenue_cents', ce.revenue_cents)
                else '{}'::jsonb end
           || case when v_show_rate then
                jsonb_build_object('rate_bp', ce.rate_bp,
                                   'credit_share_bp', ce.credit_share_bp)
                else '{}'::jsonb end
           || case when v_show_profit then
                jsonb_build_object(
                  'profit_cents',
                  case
                    when ce.revenue_cents is not null
                     and ce.cost_cents is not null
                    then ce.revenue_cents - ce.cost_cents
                  end)
                else '{}'::jsonb end
           || case when v_show_cost then
                jsonb_build_object('cost_cents', ce.cost_cents)
                else '{}'::jsonb end
             as line,
           ce.earned_date,
           ce.created_at,
           ce.amount_cents,
           (ce.amount_cents is null) as pending,
           (ce.kind = 'ADJUSTMENT'
            and ce.flags && array[
                  'RETURN_CLAWBACK','UNLINKED_REFUND','CLAWBACK_VOIDED'
                ]::text[]) as is_return
    from public.commission_entries ce
    join public.sleep_journeys sj on sj.id = ce.journey_id
    left join public.journey_line_items li on li.id = ce.line_item_id
    where ce.company_id = v_company_id
      and ce.employee_id = v_emp_id
      and ce.kind in ('COMMISSION', 'ADJUSTMENT')
      and ce.earned_date between v_start and v_end
  ) l;

  select d.amount_cents into v_draw
  from public.employee_draws d
  where d.company_id = v_company_id
    and d.employee_id = v_emp_id
    and d.effective_from <= v_start
  order by d.effective_from desc, d.created_at desc
  limit 1;

  return jsonb_build_object(
    'period_start', v_start,
    'period_end', v_end,
    'is_closed', coalesce(v_is_closed, false),
    'lines', v_lines,
    'total_cents', v_total,
    'pending_count', v_pending,
    'returns_cents', v_returns,
    'draw_progress',
      case when v_show_draw then
        jsonb_build_object(
          'draw_cents', coalesce(v_draw, 0),
          'commission_cents', v_total)
        else null end,
    'pay_date',
      public.commission_pay_date_for_period(v_company_id, v_end),
    'visibility', jsonb_build_object(
      'earnings_show_revenue', coalesce(v_show_revenue, false),
      'earnings_show_rate', coalesce(v_show_rate, false),
      'earnings_show_profit', coalesce(v_show_profit, false),
      'earnings_show_cost', v_show_cost,
      'earnings_show_draw_progress', coalesce(v_show_draw, false))
  );
end;
$$;

revoke execute on function public.get_my_earnings(date)
  from public, anon;
grant execute on function public.get_my_earnings(date)
  to authenticated;


-- ============================================================================
-- 6. commission_earn_for_unit: unchanged earning logic. The conflict
--    inference narrows with the recreated index above so re-earning a unit
--    still cannot duplicate a live COMMISSION row.
-- ============================================================================

create or replace function public.commission_earn_for_unit(p_unit_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_unit          public.journey_fulfillment_units%rowtype;
  v_ful           public.journey_fulfillments%rowtype;
  v_line          public.journey_line_items%rowtype;
  v_j             public.sleep_journeys%rowtype;
  v_company_id    uuid;
  v_earned_on     text;
  v_partial_mode  text;
  v_basis         text;
  v_cost_basis    text;
  v_revenue_cents integer;
  v_cost_cents    integer;
  v_profit_cents  integer;
  v_share         record;
  v_rate_bp       integer;
  v_amount_cents  integer;
  v_entry_flags   text[];
  v_inserted      integer;
  v_written       integer := 0;
begin
  select * into v_unit
  from public.journey_fulfillment_units
  where id = p_unit_id;
  if not found then
    return 0;
  end if;

  select * into v_ful
  from public.journey_fulfillments
  where id = v_unit.fulfillment_id;
  select * into v_line
  from public.journey_line_items
  where id = v_unit.line_item_id;
  select * into v_j
  from public.sleep_journeys
  where id = v_unit.journey_id;

  if v_ful.id is null or v_line.id is null or v_j.id is null then
    return 0;
  end if;

  select s.company_id into v_company_id
  from public.stores s
  where s.id = v_j.store_id;
  if v_company_id is null then
    return 0;
  end if;

  select c.commission_earned_on, c.commission_partial_mode,
         c.commission_basis, c.commission_cost_basis
    into v_earned_on, v_partial_mode, v_basis, v_cost_basis
  from public.companies c
  where c.id = v_company_id;

  -- v1 acts on DELIVERED / PER_ITEM / PROFIT only.
  if v_earned_on is distinct from 'DELIVERED'
     or v_partial_mode is distinct from 'PER_ITEM'
     or v_basis is distinct from 'PROFIT' then
    return 0;
  end if;

  -- Credit, fee and other product-less lines carry no snapshots. On an
  -- exchange child journey this is what keeps the credit and fee lines
  -- out of the ledger while the replacement line earns.
  if v_line.product_id is null then
    return 0;
  end if;

  if v_j.cancelled_at is not null then
    return 0;
  end if;

  -- unit_price and the snapshots are dollars per unit; one fulfillment
  -- unit earns on exactly one unit.
  v_revenue_cents := round(v_line.unit_price * 100)::integer;

  if v_cost_basis = 'WHOLESALE' then
    v_cost_cents := round(v_line.unit_cost_snapshot * 100)::integer;
  else
    v_cost_cents := round(v_line.unit_commission_cost_snapshot * 100)::integer;
  end if;

  -- Missing cost: the entry is still written (amount null, MISSING_COST
  -- flag) so the ledger shows the earning could not be priced.
  if v_cost_cents is not null then
    v_profit_cents := v_revenue_cents - v_cost_cents;
  end if;

  for v_share in
    select cs.employee_id, cs.share_bp
    from public.commission_credit_shares(v_unit.journey_id) cs
    where cs.kind = 'EMPLOYEE'
  loop
    -- STORE credit rows produce no ledger entry; store reporting reads
    -- sale_credits directly later. A null employee cannot be keyed into
    -- the ledger either.
    if v_share.employee_id is null then
      continue;
    end if;

    v_entry_flags := '{}'::text[];
    if v_cost_cents is null then
      v_entry_flags := array_append(v_entry_flags, 'MISSING_COST');
    elsif v_profit_cents < 0 then
      v_entry_flags := array_append(v_entry_flags, 'NEGATIVE_PROFIT');
    end if;

    -- Rate: the employee's own plan first, then the company default plan.
    select cp.rate_bp into v_rate_bp
    from public.employees e
    join public.commission_plans cp on cp.id = e.commission_plan_id
    where e.id = v_share.employee_id;

    if v_rate_bp is null then
      select cp.rate_bp into v_rate_bp
      from public.commission_plans cp
      where cp.company_id = v_company_id
        and cp.is_default
      limit 1;
    end if;

    if v_rate_bp is null then
      v_entry_flags := array_append(v_entry_flags, 'NO_PLAN');
      v_amount_cents := null;
    elsif v_profit_cents is null then
      v_amount_cents := null;
    else
      -- round half up = floor(x + 0.5) over exact numerics. rate_bp and
      -- share_bp are both basis points, so the divisor is 10000 * 10000
      -- = 100000000. Example: profit 60000 cents, rate 1000 bp
      -- (10 percent), share 10000 bp (full credit):
      --   floor(60000 * 1000 * 10000 / 100000000 + 0.5) = 6000 cents.
      v_amount_cents := floor(
        v_profit_cents::numeric * v_rate_bp * v_share.share_bp
        / 100000000 + 0.5
      )::integer;
    end if;

    insert into public.commission_entries (
      company_id, journey_id, line_item_id, fulfillment_unit_id,
      employee_id, store_id, kind, amount_cents, earned_at, earned_date,
      pay_period_start, revenue_cents, cost_cents, rate_bp,
      credit_share_bp, flags
    ) values (
      v_company_id, v_unit.journey_id, v_unit.line_item_id, v_unit.id,
      v_share.employee_id, v_j.store_id, 'COMMISSION', v_amount_cents,
      v_ful.recorded_at, v_ful.completed_on,
      coalesce(
        public.commission_pay_period_start(v_company_id, v_ful.completed_on),
        v_ful.completed_on
      ),
      v_revenue_cents, v_cost_cents, v_rate_bp, v_share.share_bp,
      v_entry_flags
    )
    on conflict (fulfillment_unit_id, employee_id, kind)
      where fulfillment_unit_id is not null
        and reverses_entry_id is null
        and kind in ('COMMISSION', 'SPIFF')
      do nothing;

    get diagnostics v_inserted = row_count;
    v_written := v_written + v_inserted;
  end loop;

  return v_written;
end;
$$;

revoke execute on function public.commission_earn_for_unit(uuid)
  from public, anon, authenticated;

-- ============================================================================
-- 7. move_commission_credit: move a whole order's commission credit. The
--    journey row is locked before the current-share comparison, so a double
--    click or concurrent retry serializes and the second call gets the
--    friendly already-set error. Nothing is edited in the ledger.
-- ============================================================================

create or replace function public.move_commission_credit(
  p_journey_id uuid,
  p_shares jsonb,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_caller_employee_id uuid;
  v_caller_company_id uuid;
  v_journey_company_id uuid;
  v_journey public.sleep_journeys%rowtype;
  v_reason text;
  v_input_count integer;
  v_distinct_count integer;
  v_sum_bp integer;
  v_invalid_count integer;
  v_before_key jsonb;
  v_after_key jsonb;
  v_before_shares jsonb;
  v_after_shares jsonb;
  v_assigned_employee_id uuid;
  v_move_id uuid := gen_random_uuid();
  v_landing record;
  v_flags text[];
  v_note text;
  v_unit record;
  v_emp record;
  v_new record;
  v_pot integer;
  v_unit_net_revenue integer;
  v_unit_net_cost integer;
  v_reverse_entry_id uuid;
  v_reverse_entry public.commission_entries%rowtype;
  v_alloc integer;
  v_allocated integer;
  v_new_ordinal integer;
  v_new_count integer;
  v_moved_units integer := 0;
  v_skipped_units integer := 0;
  v_reversed_cents integer := 0;
  v_credited_cents integer := 0;
begin
  if not public.has_permission('commission.payouts_manage') then
    raise exception 'You do not have permission to manage commission payouts';
  end if;

  v_reason := btrim(coalesce(p_reason, ''));
  if v_reason = '' then
    raise exception 'Enter a reason.';
  end if;
  if char_length(v_reason) > 500 then
    raise exception 'The reason must be 500 characters or fewer.';
  end if;

  if p_shares is null or jsonb_typeof(p_shares) <> 'array' then
    raise exception 'Choose at least one employee.';
  end if;

  select e.id, s.company_id
    into v_caller_employee_id, v_caller_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_caller_company_id is null then
    raise exception 'Not authenticated as an employee';
  end if;

  select * into v_journey
  from public.sleep_journeys
  where id = p_journey_id
  for update;

  if not found then
    raise exception 'Order not found';
  end if;

  select s.company_id into v_journey_company_id
  from public.stores s
  where s.id = v_journey.store_id;

  if v_journey_company_id is distinct from v_caller_company_id then
    raise exception 'Order does not belong to your company';
  end if;

  with input as (
    select (x.value ->> 'employee_id')::uuid as employee_id,
           (x.value ->> 'share_bp')::integer as share_bp
    from jsonb_array_elements(p_shares) with ordinality
      as x(value, ordinality)
  )
  select count(*)::integer,
         count(distinct i.employee_id)::integer,
         coalesce(sum(i.share_bp), 0)::integer,
         count(*) filter (
           where i.employee_id is null
              or i.share_bp is null
              or i.share_bp <= 0
              or not exists (
                select 1
                from public.employees e
                join public.stores s on s.id = e.home_store_id
                where e.id = i.employee_id
                  and e.is_active
                  and s.company_id = v_journey_company_id
              )
         )::integer
    into v_input_count, v_distinct_count, v_sum_bp, v_invalid_count
  from input i;

  if v_input_count = 0 then
    raise exception 'Choose at least one employee.';
  end if;
  if v_input_count <> v_distinct_count then
    raise exception 'Do not choose the same employee twice.';
  end if;
  if v_invalid_count > 0 then
    raise exception 'Every employee must be active in this company with a share above zero.';
  end if;
  if v_sum_bp <> 10000 then
    raise exception 'Shares must total 100 percent.';
  end if;

  with active_credits as (
    select sc.employee_id, sc.share_bp
    from public.sale_credits sc
    where sc.journey_id = p_journey_id
      and sc.kind = 'EMPLOYEE'
      and sc.superseded_at is null
  ), current_shares as (
    select ac.employee_id, ac.share_bp
    from active_credits ac
    union all
    select v_journey.assigned_employee_id, 10000
    where not exists (select 1 from active_credits)
  ), normalized as (
    select cs.employee_id, cs.share_bp
    from current_shares cs
    where cs.employee_id is not null
  )
  select coalesce(
           jsonb_agg(jsonb_build_object(
             'employee_id', n.employee_id,
             'share_bp', n.share_bp) order by n.employee_id),
           '[]'::jsonb)
    into v_before_key
  from normalized n;

  with input as (
    select (x.value ->> 'employee_id')::uuid as employee_id,
           (x.value ->> 'share_bp')::integer as share_bp
    from jsonb_array_elements(p_shares) with ordinality
      as x(value, ordinality)
  )
  select coalesce(
           jsonb_agg(jsonb_build_object(
             'employee_id', i.employee_id,
             'share_bp', i.share_bp) order by i.employee_id),
           '[]'::jsonb)
    into v_after_key
  from input i;

  if v_before_key = v_after_key then
    raise exception 'Credit is already set this way.';
  end if;

  with active_credits as (
    select sc.employee_id, sc.share_bp
    from public.sale_credits sc
    where sc.journey_id = p_journey_id
      and sc.kind = 'EMPLOYEE'
      and sc.superseded_at is null
  ), current_shares as (
    select ac.employee_id, ac.share_bp
    from active_credits ac
    union all
    select v_journey.assigned_employee_id, 10000
    where not exists (select 1 from active_credits)
  ), normalized as (
    select cs.employee_id, cs.share_bp
    from current_shares cs
    where cs.employee_id is not null
  )
  select coalesce(
           jsonb_agg(jsonb_build_object(
             'employee_id', n.employee_id,
             'name', e.name,
             'share_bp', n.share_bp) order by n.employee_id),
           '[]'::jsonb)
    into v_before_shares
  from normalized n
  left join public.employees e on e.id = n.employee_id;

  with input as (
    select (x.value ->> 'employee_id')::uuid as employee_id,
           (x.value ->> 'share_bp')::integer as share_bp
    from jsonb_array_elements(p_shares) with ordinality
      as x(value, ordinality)
  )
  select coalesce(
           jsonb_agg(jsonb_build_object(
             'employee_id', i.employee_id,
             'name', e.name,
             'share_bp', i.share_bp) order by i.employee_id),
           '[]'::jsonb)
    into v_after_shares
  from input i
  left join public.employees e on e.id = i.employee_id;

  select * into v_landing
  from public.commission_landing_for(
    v_journey_company_id,
    coalesce(public.business_today(v_journey.store_id), current_date));
  if v_landing.earned_date is null then
    raise exception 'Could not resolve the open pay period.';
  end if;

  v_flags := array['CREDIT_MOVED'];
  if v_landing.landed_late then
    v_flags := array_append(v_flags, 'LANDED_IN_LATER_PERIOD'::text);
  end if;
  v_note := 'Credit moved: ' || v_reason;

  for v_unit in
    select ce.fulfillment_unit_id,
           (array_agg(ce.line_item_id order by ce.id))[1] as line_item_id,
           (array_agg(ce.store_id order by ce.id))[1] as store_id,
           bool_or(ce.amount_cents is null) as has_null_amount
    from public.commission_entries ce
    where ce.journey_id = p_journey_id
      and ce.kind = 'COMMISSION'
      and ce.fulfillment_unit_id is not null
    group by ce.fulfillment_unit_id
    order by ce.fulfillment_unit_id
  loop
    if v_unit.has_null_amount then
      v_skipped_units := v_skipped_units + 1;
      continue;
    end if;

    with positions as (
      select ce.employee_id,
             sum(ce.amount_cents)::integer as net_amount,
             sum(ce.revenue_cents)::integer as net_revenue,
             sum(ce.cost_cents)::integer as net_cost
      from public.commission_entries ce
      where ce.fulfillment_unit_id = v_unit.fulfillment_unit_id
        and ce.kind in ('COMMISSION', 'ADJUSTMENT')
      group by ce.employee_id
    )
    select coalesce(sum(p.net_amount), 0)::integer,
           max(p.net_revenue)::integer,
           max(p.net_cost)::integer
      into v_pot, v_unit_net_revenue, v_unit_net_cost
    from positions p;

    for v_emp in
      select ce.employee_id,
             sum(ce.amount_cents)::integer as net_amount,
             sum(ce.revenue_cents)::integer as net_revenue,
             sum(ce.cost_cents)::integer as net_cost
      from public.commission_entries ce
      where ce.fulfillment_unit_id = v_unit.fulfillment_unit_id
        and ce.kind in ('COMMISSION', 'ADJUSTMENT')
      group by ce.employee_id
      order by ce.employee_id
    loop
      if coalesce(v_emp.net_amount, 0) = 0
         and coalesce(v_emp.net_revenue, 0) = 0
         and coalesce(v_emp.net_cost, 0) = 0 then
        continue;
      end if;

      select ce.id into v_reverse_entry_id
      from public.commission_entries ce
      where ce.fulfillment_unit_id = v_unit.fulfillment_unit_id
        and ce.employee_id = v_emp.employee_id
        and ce.reverses_entry_id is null
        and (ce.kind = 'COMMISSION'
             or (ce.kind = 'ADJUSTMENT'
                 and 'CREDIT_MOVED' = any(ce.flags)))
        and not exists (
          select 1
          from public.commission_entries mr
          where mr.reverses_entry_id = ce.id
            and mr.kind = 'ADJUSTMENT'
            and 'CREDIT_MOVED' = any(mr.flags)
        )
      order by ce.created_at desc, ce.id desc
      limit 1;

      if v_reverse_entry_id is null then
        raise exception 'Could not find the entry to reverse for this order.';
      end if;

      select * into v_reverse_entry
      from public.commission_entries
      where id = v_reverse_entry_id;

      insert into public.commission_entries (
        company_id, journey_id, line_item_id, fulfillment_unit_id,
        employee_id, store_id, kind, amount_cents, earned_at, earned_date,
        pay_period_start, revenue_cents, cost_cents, rate_bp,
        credit_share_bp, flags, reverses_entry_id, note,
        clawback_source_id
      ) values (
        v_journey_company_id, p_journey_id, v_reverse_entry.line_item_id,
        v_unit.fulfillment_unit_id, v_emp.employee_id,
        v_reverse_entry.store_id, 'ADJUSTMENT',
        -1 * coalesce(v_emp.net_amount, 0), now(),
        v_landing.earned_date, v_landing.pay_period_start,
        case when v_emp.net_revenue is null then null
             else -1 * v_emp.net_revenue end,
        case when v_emp.net_cost is null then null
             else -1 * v_emp.net_cost end,
        v_reverse_entry.rate_bp, v_reverse_entry.credit_share_bp,
        v_flags, v_reverse_entry_id, v_note, v_move_id
      )
      on conflict (reverses_entry_id, clawback_source_id)
        where clawback_source_id is not null
      do nothing;

      v_reversed_cents := v_reversed_cents
        + (-1 * coalesce(v_emp.net_amount, 0));
    end loop;

    select count(*)::integer into v_new_count
    from jsonb_array_elements(p_shares);

    v_allocated := 0;
    v_new_ordinal := 0;
    for v_new in
      select (x.value ->> 'employee_id')::uuid as employee_id,
             (x.value ->> 'share_bp')::integer as share_bp,
             x.ordinality
      from jsonb_array_elements(p_shares) with ordinality
        as x(value, ordinality)
      order by x.ordinality
    loop
      v_new_ordinal := v_new_ordinal + 1;
      if v_new_ordinal = v_new_count then
        v_alloc := v_pot - v_allocated;
      else
        v_alloc := round(
          v_pot::numeric * v_new.share_bp / 10000)::integer;
        v_allocated := v_allocated + v_alloc;
      end if;

      insert into public.commission_entries (
        company_id, journey_id, line_item_id, fulfillment_unit_id,
        employee_id, store_id, kind, amount_cents, earned_at, earned_date,
        pay_period_start, revenue_cents, cost_cents, rate_bp,
        credit_share_bp, flags, reverses_entry_id, note,
        clawback_source_id
      ) values (
        v_journey_company_id, p_journey_id, v_unit.line_item_id,
        v_unit.fulfillment_unit_id, v_new.employee_id, v_unit.store_id,
        'ADJUSTMENT', v_alloc, now(),
        v_landing.earned_date, v_landing.pay_period_start,
        v_unit_net_revenue, v_unit_net_cost, null,
        v_new.share_bp, v_flags, null, v_note, v_move_id
      );
    end loop;

    v_credited_cents := v_credited_cents + v_pot;
    v_moved_units := v_moved_units + 1;
  end loop;

  update public.sale_credits
  set superseded_at = now()
  where journey_id = p_journey_id
    and kind = 'EMPLOYEE'
    and superseded_at is null;

  insert into public.sale_credits (
    company_id, journey_id, kind, employee_id, share_bp, reason, created_by
  )
  select v_journey_company_id, p_journey_id, 'EMPLOYEE',
         (x.value ->> 'employee_id')::uuid,
         (x.value ->> 'share_bp')::integer,
         v_note, v_caller_employee_id
  from jsonb_array_elements(p_shares) with ordinality
    as x(value, ordinality)
  order by x.ordinality;

  with input as (
    select (x.value ->> 'employee_id')::uuid as employee_id,
           (x.value ->> 'share_bp')::integer as share_bp,
           x.ordinality
    from jsonb_array_elements(p_shares) with ordinality
      as x(value, ordinality)
  )
  select i.employee_id into v_assigned_employee_id
  from input i
  order by i.share_bp desc, i.ordinality
  limit 1;

  update public.sleep_journeys
  set assigned_employee_id = v_assigned_employee_id
  where id = p_journey_id;

  perform public.log_audit_event(
    v_journey_company_id,
    'sleep_journey',
    p_journey_id,
    'COMMISSION_CREDIT_MOVED',
    jsonb_build_object('shares', v_before_shares),
    jsonb_build_object(
      'shares', v_after_shares,
      'move_id', v_move_id,
      'reason', v_reason),
    null,
    'Credit moved: ' || v_reason,
    p_journey_id,
    'EMPLOYEE',
    v_caller_employee_id
  );

  return jsonb_build_object(
    'move_id', v_move_id,
    'moved_units', v_moved_units,
    'skipped_units', v_skipped_units,
    'reversed_cents', v_reversed_cents,
    'credited_cents', v_credited_cents,
    'landed_period_start', v_landing.pay_period_start,
    'landed_later', coalesce(v_landing.landed_late, false)
  );
end;
$$;

revoke execute on function public.move_commission_credit(uuid, jsonb, text)
  from public, anon;
grant execute on function public.move_commission_credit(uuid, jsonb, text)
  to authenticated;

-- ============================================================================
-- 8. get_credit_move_info: modal read. It returns shares, counts, net
--    commission and landing dates only. Cost is deliberately absent.
-- ============================================================================

create or replace function public.get_credit_move_info(
  p_journey_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_journey_company_id uuid;
  v_journey public.sleep_journeys%rowtype;
  v_shares jsonb;
  v_net jsonb;
  v_employee_options jsonb;
  v_units integer;
  v_missing integer;
  v_landing record;
  v_period_end date;
begin
  if not public.has_permission('commission.payouts_manage') then
    raise exception 'You do not have permission to manage commission payouts';
  end if;

  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_company_id is null then
    raise exception 'Not authenticated as an employee';
  end if;

  select * into v_journey
  from public.sleep_journeys
  where id = p_journey_id;

  if not found then
    raise exception 'Order not found';
  end if;

  select s.company_id into v_journey_company_id
  from public.stores s
  where s.id = v_journey.store_id;

  if v_journey_company_id is distinct from v_company_id then
    raise exception 'Order does not belong to your company';
  end if;

  with active_credits as (
    select sc.employee_id, sc.share_bp
    from public.sale_credits sc
    where sc.journey_id = p_journey_id
      and sc.kind = 'EMPLOYEE'
      and sc.superseded_at is null
  ), current_shares as (
    select ac.employee_id, ac.share_bp
    from active_credits ac
    union all
    select v_journey.assigned_employee_id, 10000
    where not exists (select 1 from active_credits)
  ), normalized as (
    select cs.employee_id, cs.share_bp
    from current_shares cs
    where cs.employee_id is not null
  )
  select coalesce(
           jsonb_agg(jsonb_build_object(
             'employee_id', n.employee_id,
             'name', e.name,
             'share_bp', n.share_bp) order by n.employee_id),
           '[]'::jsonb)
    into v_shares
  from normalized n
  left join public.employees e on e.id = n.employee_id;

  with active_credits as (
    select sc.employee_id, sc.share_bp
    from public.sale_credits sc
    where sc.journey_id = p_journey_id
      and sc.kind = 'EMPLOYEE'
      and sc.superseded_at is null
  ), current_shares as (
    select ac.employee_id, ac.share_bp
    from active_credits ac
    union all
    select v_journey.assigned_employee_id, 10000
    where not exists (select 1 from active_credits)
  ), normalized as (
    select cs.employee_id
    from current_shares cs
    where cs.employee_id is not null
  ), totals as (
    select ce.employee_id,
           sum(ce.amount_cents)::integer as net_cents
    from public.commission_entries ce
    where ce.journey_id = p_journey_id
      and ce.kind in ('COMMISSION', 'ADJUSTMENT')
    group by ce.employee_id
  )
  select coalesce(
           jsonb_agg(jsonb_build_object(
             'employee_id', n.employee_id,
             'name', e.name,
             'net_cents', coalesce(t.net_cents, 0)) order by e.name),
           '[]'::jsonb)
    into v_net
  from normalized n
  left join public.employees e on e.id = n.employee_id
  left join totals t on t.employee_id = n.employee_id;

  select coalesce(
           jsonb_agg(jsonb_build_object(
             'employee_id', e.id,
             'name', e.name) order by e.name),
           '[]'::jsonb)
    into v_employee_options
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where s.company_id = v_journey_company_id
    and e.is_active;

  select count(*)::integer,
         count(*) filter (where u.has_null_amount)::integer
    into v_units, v_missing
  from (
    select ce.fulfillment_unit_id,
           bool_or(ce.amount_cents is null) as has_null_amount
    from public.commission_entries ce
    where ce.journey_id = p_journey_id
      and ce.kind = 'COMMISSION'
      and ce.fulfillment_unit_id is not null
    group by ce.fulfillment_unit_id
  ) u;

  select * into v_landing
  from public.commission_landing_for(
    v_journey_company_id,
    coalesce(public.business_today(v_journey.store_id), current_date));

  if v_landing.earned_date is not null then
    select p.period_end into v_period_end
    from public.commission_payout_period_for(
      v_journey_company_id, v_landing.earned_date) p;
  end if;

  return jsonb_build_object(
    'journey_id', p_journey_id,
    'journey_number', v_journey.journey_number,
    'shares', v_shares,
    'units_with_earnings', coalesce(v_units, 0),
    'net_commission', v_net,
    'employee_options', v_employee_options,
    'missing_cost_units', coalesce(v_missing, 0),
    'can_move', true,
    'landing_period_start', v_landing.pay_period_start,
    'landing_period_end', v_period_end,
    'landed_later', coalesce(v_landing.landed_late, false)
  );
end;
$$;

revoke execute on function public.get_credit_move_info(uuid)
  from public, anon;
grant execute on function public.get_credit_move_info(uuid)
  to authenticated;
