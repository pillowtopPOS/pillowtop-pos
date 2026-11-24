-- ============================================================================
-- 185: return clawbacks (C5 slice 1)
--
--   1. commission_entries.clawback_source_id: the refund event id or the
--      sleep trial action id that produced an ADJUSTMENT row. The partial
--      unique index on (reverses_entry_id, clawback_source_id) makes every
--      clawback and clawback-void write idempotent.
--   2. companies.spiff_return_mode: 'NEVER' (default, existing companies
--      unchanged) or 'FULL_RETURN' (a fully returned or exchanged unit also
--      reverses its SPIFF entries).
--   3. commission_landing_for: where an adjustment recorded on a given day
--      lands. Record date wins; when that pay period is already closed the
--      entry lands in the first open period after it and is flagged
--      LANDED_IN_LATER_PERIOD. Closed periods are never touched.
--   4. commission_write_clawback: one ADJUSTMENT row against one original
--      COMMISSION entry. Negative amount, negative proportional revenue
--      and cost, original employee / credit share / store / journey / line /
--      unit preserved. Capped so total clawbacks against an original can
--      never exceed its amount.
--   5. commission_clawback_for_unit: trial item -> fulfillment unit ->
--      original COMMISSION entries (same join as 151).
--   6. commission_clawback_for_refund: refund event dispatch. A refund
--      linked to a RETURN action claws back that action's unit by
--      refund / unit sale price; a refund linked to an EXCHANGE action is
--      skipped (the action-completion clawback covers it); an unlinked
--      refund on a fulfilled order spreads across the journey's earning
--      entries by refund / sum(revenue_cents), flag UNLINKED_REFUND.
--   7. commission_clawback_for_exchange: at action completion, one
--      clawback for the returned unit, share =
--      (original_credit_cents - exchange_fee_cents) / fee_basis_cents.
--   8. commission_void_clawbacks: opposite positive ADJUSTMENT rows
--      (CLAWBACK_VOIDED) reversing every clawback a source produced,
--      idempotent via the same unique index.
--   9. spiff_reverse_for_action: under FULL_RETURN only, reverses the
--      SPIFF entries on the action's line using the Google-review-void
--      pattern (negative SPIFF row, reverses_entry_id, same employee /
--      store / share, current month).
--  10. Triggers, each with the 175-style exception handler so a failure
--      warns + audits and never blocks the refund, void or action:
--        trg_zz_clawback_refund      journey_events AFTER INSERT
--                                    (payment_refunded / SUCCEEDED)
--        trg_zz_clawback_refund_void journey_events AFTER UPDATE OF outcome
--                                    (-> VOIDED)
--        trg_zz_action_completed_cb  sleep_trial_actions AFTER UPDATE OF
--                                    status (-> COMPLETED): exchange
--      clawback and the FULL_RETURN spiff reversal. Triggers are used
--      instead of editing complete_sleep_trial_action / void_payment_
--      refund because completions and refund voids also happen through
--      stv_try_complete_sleep_trial_action and reopen_sleep_trial_action;
--      the row transition catches every path.
--  11. commission_earn_for_unit: the sale_kind EXCHANGE skip is removed so
--      exchange replacement lines earn commission like any other line
--      (own price, own cost, own credit shares; credit and fee lines have
--      no product_id and stay unearned).
--  12. list_commission_entries: new trailing type_label column - reason
--      label for ADJUSTMENT rows and the spiff rule name for SPIFF rows.
--  13. get_my_earnings: new returns_cents key = net signed total of the
--      rep's return-adjustment rows for the period.
--  14. get_bonus_preview: under the COMMISSION_COST cost basis the margin
--      test recomputes cost from unit_cost_snapshot, which returned a
--      positive cost for negative clawback rows. Adjustment rows now
--      scale the snapshot by their share of the reversed original so the
--      return is seen under both bases.
--  15. guard_journey_line_item_mutation: a line with any fulfilled unit
--      that earned COMMISSION can no longer have unit_price or quantity
--      changed on any journey state (a partially fulfilled order has no
--      delivered_at and was previously unlocked). The metadata carve-out
--      is preserved.
--  16. get_spiff_return_mode / set_spiff_return_mode: same permission
--      behaviour as get/set_spiff_settings.
--  17. Exchange replacement-sale credit (design change): the exchange
--      child's commission credit defaults to the ORIGINAL journey's
--      seller(s) instead of the exchange committer. The existing
--      sleep_trial_actions.sale_attribution_employee_id column becomes
--      the chosen-credit override: drafts now store null, a non-null
--      value names the one employee who takes 100 percent. create_
--      exchange_draft is replaced (088 body verbatim, attribution null);
--      two sleep_journeys insert triggers assign the child and copy the
--      credit rows at commit; set_exchange_credit_employee flips the
--      choice while the action is a DRAFT; get_exchange_credit_info
--      feeds the builder select.
--
--   Re-runnable: or replace / if not exists / drop if exists throughout.
-- ============================================================================

-- ============================================================================
-- 1-2. Columns.
-- ============================================================================

alter table public.commission_entries
  add column if not exists clawback_source_id uuid;

comment on column public.commission_entries.clawback_source_id is
  'Set on ADJUSTMENT rows written by the 185 clawback hooks: the '
  'payment_refunded journey_event id or the sleep_trial_actions id that '
  'caused the entry. Together with reverses_entry_id it makes every '
  'clawback and clawback-void write idempotent.';

create unique index if not exists idx_commission_entries_clawback_source
  on public.commission_entries (reverses_entry_id, clawback_source_id)
  where clawback_source_id is not null;

alter table public.companies
  add column if not exists spiff_return_mode text not null default 'NEVER'
    check (spiff_return_mode in ('NEVER', 'FULL_RETURN'));

comment on column public.companies.spiff_return_mode is
  'NEVER (default): spiffs earned on a returned or exchanged unit stay '
  'payable. FULL_RETURN: a fully returned or exchanged unit reverses its '
  'SPIFF entries in the current month. Partial refunds never touch spiffs.';

-- Browser roles never write these columns directly; all writes come from
-- security definer functions. (Table-level write grants are already
-- revoked; the column-level revokes keep that explicit.)
revoke update (clawback_source_id) on public.commission_entries
  from anon, authenticated;
revoke update (spiff_return_mode) on public.companies
  from anon, authenticated;

-- ============================================================================
-- 3. commission_landing_for: the pay-period placement for an adjustment
--    recorded on p_date. Closed windows are skipped forward; the flag
--    tells the caller to add LANDED_IN_LATER_PERIOD. Internal only.
-- ============================================================================

create or replace function public.commission_landing_for(
  p_company_id uuid,
  p_date date
)
returns table(
  earned_date date,
  pay_period_start date,
  landed_late boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_d date := p_date;
  v_per record;
begin
  if p_company_id is null or p_date is null then
    return;
  end if;

  -- Skip consecutive closed windows; closes are finite so a bound of 60
  -- is far past any real chain but can never hang.
  for i in 1..60 loop
    select p.period_start, p.period_end, p.is_closed
      into v_per
    from public.commission_payout_period_for(p_company_id, v_d) p;

    if v_per.period_start is null then
      -- Company has no resolvable period settings: land on the day.
      return query select v_d, v_d, false;
      return;
    end if;

    if not v_per.is_closed then
      return query
        select greatest(v_d, v_per.period_start),
               coalesce(
                 public.commission_pay_period_start(
                   p_company_id, greatest(v_d, v_per.period_start)),
                 v_per.period_start),
               (v_d > p_date);
      return;
    end if;

    v_d := v_per.period_end + 1;
  end loop;

  return query select p_date, p_date, false;
end;
$$;

revoke execute on function public.commission_landing_for(uuid, date)
  from public, anon, authenticated;

-- ============================================================================
-- 4. commission_write_clawback: one ADJUSTMENT against one original
--    COMMISSION entry. Returns a status string:
--      WRITTEN            a clawback row was inserted
--      DUPLICATE          the unique index swallowed a retry
--      SKIP_NO_ORIGINAL   no live COMMISSION entry with that id
--      SKIP_NULL_AMOUNT   original amount is null (MISSING_COST)
--      SKIP_NO_ROOM       the cap left nothing to claw back
--    Net room = original amount plus every signed adjustment in its
--    reversal chain (clawbacks reverse the original, clawback-voids
--    reverse the clawbacks), so a voided clawback frees its capacity
--    again and negative-amount originals get a symmetric restore.
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
begin
  select * into v_orig
  from public.commission_entries
  where id = p_entry_id
    and kind = 'COMMISSION'
    and reverses_entry_id is null;
  if not found then
    return 'SKIP_NO_ORIGINAL';
  end if;

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

  -- Round half up on exact numerics, same rule as the earn path. The
  -- sign of the result is forced opposite the remaining room so a
  -- negative-profit original restores instead of clawing further.
  v_prop := floor(
    v_orig.amount_cents::numeric * p_share_bp / 10000 + 0.5)::integer;
  v_take := least(abs(v_prop), abs(v_room));
  if v_take <= 0 then
    return 'SKIP_NO_ROOM';
  end if;
  v_amount := case when v_room > 0 then -v_take else v_take end;

  -- Revenue and cost get the same cap the amount did: when prior
  -- clawbacks leave less room than the proportional take, the revenue
  -- and cost deltas scale down by v_take / abs(v_prop) so an over-refund
  -- cannot overstate the return. abs(v_prop) > 0 whenever we get here.
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
    p_flags, v_orig.id, p_note, p_source_id
  )
  on conflict (reverses_entry_id, clawback_source_id)
    where clawback_source_id is not null
  do nothing;

  get diagnostics v_inserted = row_count;
  return case when v_inserted > 0 then 'WRITTEN' else 'DUPLICATE' end;
end;
$$;

revoke execute on function public.commission_write_clawback(
  uuid, integer, uuid, text[], date, date, text)
  from public, anon, authenticated;

-- ============================================================================
-- 5. commission_clawback_for_unit: trial item -> fulfillment unit ->
--    original COMMISSION entries. The item-to-unit join is the same one
--    151 uses: direct sleep_trial_item_id first, line_item_id +
--    unit_index as fallback. Entries with no computed amount are skipped
--    and reported in one audit_events row. Returns rows written.
-- ============================================================================

create or replace function public.commission_clawback_for_unit(
  p_trial_item_id uuid,
  p_share_bp integer,
  p_source_id uuid,
  p_flags text[],
  p_note text
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item record;
  v_j record;
  v_unit_id uuid;
  v_landing record;
  v_flags text[] := p_flags;
  v_orig record;
  v_status text;
  v_written integer := 0;
  v_skipped uuid[] := '{}';
begin
  select sti.id, sti.journey_id, sti.line_item_id, sti.unit_index
    into v_item
  from public.sleep_trial_items sti
  where sti.id = p_trial_item_id;
  if not found then
    return 0;
  end if;

  select j.store_id, s.company_id
    into v_j
  from public.sleep_journeys j
  join public.stores s on s.id = j.store_id
  where j.id = v_item.journey_id;
  if v_j.store_id is null then
    return 0;
  end if;

  select jfu.id into v_unit_id
  from public.journey_fulfillment_units jfu
  where jfu.journey_id = v_item.journey_id
    and (jfu.sleep_trial_item_id = v_item.id
         or (jfu.line_item_id = v_item.line_item_id
             and jfu.unit_index = v_item.unit_index))
  order by (jfu.sleep_trial_item_id = v_item.id) desc
  limit 1;
  if v_unit_id is null then
    return 0;
  end if;

  select * into v_landing
  from public.commission_landing_for(
    v_j.company_id,
    coalesce(public.business_today(v_j.store_id), current_date));
  if v_landing.earned_date is null then
    return 0;
  end if;
  if v_landing.landed_late then
    v_flags := array_append(v_flags, 'LANDED_IN_LATER_PERIOD'::text);
  end if;

  for v_orig in
    select ce.id
    from public.commission_entries ce
    where ce.fulfillment_unit_id = v_unit_id
      and ce.kind = 'COMMISSION'
      and ce.reverses_entry_id is null
  loop
    v_status := public.commission_write_clawback(
      v_orig.id, p_share_bp, p_source_id, v_flags,
      v_landing.earned_date, v_landing.pay_period_start, p_note);
    if v_status = 'WRITTEN' then
      v_written := v_written + 1;
    elsif v_status = 'SKIP_NULL_AMOUNT' then
      v_skipped := array_append(v_skipped, v_orig.id);
    end if;
  end loop;

  if array_length(v_skipped, 1) is not null then
    perform public.log_audit_event(
      v_j.company_id,
      'sleep_trial_item',
      p_trial_item_id,
      'COMMISSION_CLAWBACK_SKIPPED',
      null,
      jsonb_build_object(
        'source_id', p_source_id,
        'skipped_entry_ids', to_jsonb(v_skipped),
        'reason', 'original entry has no computed amount'),
      null,
      'Clawback skipped: original commission could not be calculated',
      v_item.journey_id,
      'SYSTEM');
  end if;

  return v_written;
end;
$$;

revoke execute on function public.commission_clawback_for_unit(
  uuid, integer, uuid, text[], text)
  from public, anon, authenticated;

-- ============================================================================
-- 6. commission_clawback_for_refund: dispatch on a payment_refunded
--    journey event. RETURN-linked refunds claw back that action's unit at
--    refund / unit sale price; EXCHANGE-linked refunds return without
--    writing (the completion clawback owns the exchange); unlinked
--    refunds spread over the journey's earning entries.
-- ============================================================================

create or replace function public.commission_clawback_for_refund(
  p_refund_event_id uuid
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ev public.journey_events%rowtype;
  v_action public.sleep_trial_actions%rowtype;
  v_j record;
  v_refund_cents integer;
  v_sale_cents integer;
  v_total_rev bigint;
  v_share_bp integer;
  v_landing record;
  v_flags text[];
  v_orig record;
  v_status text;
  v_written integer := 0;
  v_skipped uuid[] := '{}';
begin
  select * into v_ev
  from public.journey_events
  where id = p_refund_event_id;
  if not found
     or v_ev.event_type <> 'payment_refunded'
     or v_ev.outcome <> 'SUCCEEDED' then
    return 0;
  end if;

  v_refund_cents :=
    round((v_ev.event_data ->> 'amount')::numeric * 100)::int;
  if v_refund_cents is null or v_refund_cents <= 0 then
    return 0;
  end if;

  select j.store_id, s.company_id
    into v_j
  from public.sleep_journeys j
  join public.stores s on s.id = j.store_id
  where j.id = v_ev.journey_id;
  if v_j.store_id is null then
    return 0;
  end if;

  -- Linked refund: RETURN claws back the action's returned unit,
  -- EXCHANGE is owned by the action-completion clawback so a cash
  -- refund on the same exchange is never counted twice.
  if v_ev.event_data ? 'action_id' then
    select * into v_action
    from public.sleep_trial_actions
    where id = (v_ev.event_data ->> 'action_id')::uuid;
    if not found or v_action.action = 'EXCHANGE' then
      return 0;
    end if;

    -- Sale price of the returned unit = the revenue the unit's
    -- COMMISSION entries recorded at earn time.
    select max(ce.revenue_cents) into v_sale_cents
    from public.sleep_trial_items sti
    join public.journey_fulfillment_units jfu
      on jfu.journey_id = sti.journey_id
     and (jfu.sleep_trial_item_id = sti.id
          or (jfu.line_item_id = sti.line_item_id
              and jfu.unit_index = sti.unit_index))
    join public.commission_entries ce
      on ce.fulfillment_unit_id = jfu.id
     and ce.kind = 'COMMISSION'
     and ce.reverses_entry_id is null
    where sti.id = v_action.trial_item_id;

    if v_sale_cents is null or v_sale_cents <= 0 then
      return 0;
    end if;
    v_share_bp := least(
      10000,
      round(10000.0 * v_refund_cents / v_sale_cents))::int;
    if v_share_bp <= 0 then
      return 0;
    end if;

    return public.commission_clawback_for_unit(
      v_action.trial_item_id, v_share_bp, p_refund_event_id,
      array['RETURN_CLAWBACK'], 'Return clawback');
  end if;

  -- Unlinked refund: spread across the journey's earning entries by
  -- refund / sale revenue, capped at a full clawback. Sale revenue is
  -- summed per fulfillment unit, not per entry: split-credit units write
  -- one COMMISSION row per payee and each carries the full unit revenue,
  -- so summing the rows would count a split sale twice and claw back too
  -- little. Null-unit rows (none in v1) group by their own id.
  select coalesce(sum(u.rev), 0) into v_total_rev
  from (
    select max(ce.revenue_cents) as rev
    from public.commission_entries ce
    where ce.journey_id = v_ev.journey_id
      and ce.kind = 'COMMISSION'
      and ce.reverses_entry_id is null
    group by coalesce(ce.fulfillment_unit_id, ce.id)
  ) u;

  if v_total_rev <= 0 then
    return 0;
  end if;
  v_share_bp := least(
    10000,
    round(10000.0 * v_refund_cents / v_total_rev))::int;
  if v_share_bp <= 0 then
    return 0;
  end if;

  select * into v_landing
  from public.commission_landing_for(
    v_j.company_id,
    coalesce(public.business_today(v_j.store_id), current_date));
  if v_landing.earned_date is null then
    return 0;
  end if;

  v_flags := array['RETURN_CLAWBACK', 'UNLINKED_REFUND'];
  if v_landing.landed_late then
    v_flags := array_append(v_flags, 'LANDED_IN_LATER_PERIOD'::text);
  end if;

  for v_orig in
    select ce.id
    from public.commission_entries ce
    where ce.journey_id = v_ev.journey_id
      and ce.kind = 'COMMISSION'
      and ce.reverses_entry_id is null
  loop
    v_status := public.commission_write_clawback(
      v_orig.id, v_share_bp, p_refund_event_id, v_flags,
      v_landing.earned_date, v_landing.pay_period_start,
      'Unlinked refund clawback');
    if v_status = 'WRITTEN' then
      v_written := v_written + 1;
    elsif v_status = 'SKIP_NULL_AMOUNT' then
      v_skipped := array_append(v_skipped, v_orig.id);
    end if;
  end loop;

  if array_length(v_skipped, 1) is not null then
    perform public.log_audit_event(
      v_j.company_id,
      'journey_event',
      p_refund_event_id,
      'COMMISSION_CLAWBACK_SKIPPED',
      null,
      jsonb_build_object(
        'source_id', p_refund_event_id,
        'skipped_entry_ids', to_jsonb(v_skipped),
        'reason', 'original entry has no computed amount'),
      null,
      'Clawback skipped: original commission could not be calculated',
      v_ev.journey_id,
      'SYSTEM');
  end if;

  return v_written;
end;
$$;

revoke execute on function public.commission_clawback_for_refund(uuid)
  from public, anon, authenticated;

-- ============================================================================
-- 7. commission_clawback_for_exchange: the returned unit's clawback at
--    action completion. share_bp = (original credit applied minus the
--    exchange fee) over the trial item's fee_basis_cents, capped at
--    10000. Any cash refund the same exchange owes is recorded as a
--    linked refund and skipped by commission_clawback_for_refund, so the
--    credit is counted exactly once here.
-- ============================================================================

create or replace function public.commission_clawback_for_exchange(
  p_action_id uuid
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_fee_basis integer;
  v_credit integer;
  v_fee integer;
  v_share_bp integer;
begin
  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id
    and action = 'EXCHANGE'
    and status = 'COMPLETED';
  if not found then
    return 0;
  end if;

  select sti.fee_basis_cents into v_fee_basis
  from public.sleep_trial_items sti
  where sti.id = v_action.trial_item_id;

  v_credit := coalesce(v_action.original_credit_cents, 0);
  v_fee := coalesce(v_action.exchange_fee_cents,
                    v_action.locked_fee_cents, 0);

  if v_fee_basis is null or v_fee_basis <= 0 then
    perform public.log_audit_event(
      v_action.company_id,
      'sleep_trial_action',
      p_action_id,
      'COMMISSION_CLAWBACK_SKIPPED',
      null,
      jsonb_build_object(
        'source_id', p_action_id,
        'reason', 'trial item has no fee basis'),
      null,
      'Exchange clawback skipped: no fee basis on the returned unit',
      v_action.journey_id,
      'SYSTEM');
    return 0;
  end if;

  v_share_bp := least(
    10000,
    round(10000.0 * greatest(v_credit - v_fee, 0) / v_fee_basis))::int;
  if v_share_bp <= 0 then
    return 0;
  end if;

  return public.commission_clawback_for_unit(
    v_action.trial_item_id, v_share_bp, p_action_id,
    array['RETURN_CLAWBACK'], 'Exchange clawback');
end;
$$;

revoke execute on function public.commission_clawback_for_exchange(uuid)
  from public, anon, authenticated;

-- ============================================================================
-- 8. commission_void_clawbacks: the void path. Every clawback row a
--    source produced and that is not already reversed gets one opposite
--    ADJUSTMENT row: positive amount, positive proportional revenue and
--    cost, flag CLAWBACK_VOIDED, landed in the open period today. The
--    not-exists check plus the unique index make it idempotent.
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
      'Clawback voided', p_source_id
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
-- 9. spiff_reverse_for_action: FULL_RETURN companies only. A completed
--    RETURN or EXCHANGE action reverses the rule-earned SPIFF entries on
--    the action's line, using the exact Google-review-void shape:
--    negative SPIFF row, reverses_entry_id, same employee / store /
--    credit share, earned on the store's business today so it lands in
--    the current spiff month. Already-reversed rows and Google review
--    spiffs (no line) are untouched.
-- ============================================================================

create or replace function public.spiff_reverse_for_action(
  p_action_id uuid
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_mode text;
  v_line_id uuid;
  v_store_id uuid;
  v_today date;
  v_ce record;
  v_count integer := 0;
begin
  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id
    and status = 'COMPLETED';
  if not found then
    return 0;
  end if;

  select c.spiff_return_mode into v_mode
  from public.companies c
  where c.id = v_action.company_id;
  if v_mode is distinct from 'FULL_RETURN' then
    return 0;
  end if;

  select sti.line_item_id into v_line_id
  from public.sleep_trial_items sti
  where sti.id = v_action.trial_item_id;
  if v_line_id is null then
    return 0;
  end if;

  select j.store_id into v_store_id
  from public.sleep_journeys j
  where j.id = v_action.journey_id;
  v_today := coalesce(public.business_today(v_store_id), current_date);

  for v_ce in
    select ce.id, ce.employee_id, ce.store_id, ce.amount_cents,
           ce.credit_share_bp, ce.spiff_rule_id
    from public.commission_entries ce
    where ce.journey_id = v_action.journey_id
      and ce.line_item_id = v_line_id
      and ce.kind = 'SPIFF'
      and ce.reverses_entry_id is null
      and not exists (
        select 1
        from public.commission_entries r
        where r.reverses_entry_id = ce.id
      )
  loop
    insert into public.commission_entries (
      company_id, journey_id, line_item_id, fulfillment_unit_id,
      employee_id, store_id, kind, amount_cents, earned_at, earned_date,
      pay_period_start, revenue_cents, cost_cents, rate_bp,
      credit_share_bp, flags, reverses_entry_id, note,
      spiff_rule_id, review_spiff_id
    ) values (
      v_action.company_id, v_action.journey_id, v_line_id, null,
      v_ce.employee_id, v_ce.store_id, 'SPIFF',
      -1 * v_ce.amount_cents, now(), v_today,
      coalesce(
        public.commission_pay_period_start(v_action.company_id, v_today),
        v_today
      ),
      null, null, null, v_ce.credit_share_bp, '{}',
      v_ce.id,
      'Spiff reversed: ' || lower(v_action.action) || ' completed',
      v_ce.spiff_rule_id, null
    );
    v_count := v_count + 1;
  end loop;

  if v_count > 0 then
    perform public.log_audit_event(
      v_action.company_id,
      'sleep_trial_action',
      p_action_id,
      'SPIFF_ENTRIES_REVERSED',
      null,
      jsonb_build_object(
        'reversed_count', v_count,
        'reason', lower(v_action.action) || '_completed'),
      null,
      'Rule-based spiff entries reversed on completed '
        || lower(v_action.action),
      v_action.journey_id,
      'SYSTEM');
  end if;

  return v_count;
end;
$$;

revoke execute on function public.spiff_reverse_for_action(uuid)
  from public, anon, authenticated;

-- ============================================================================
-- 10. Triggers. Every hook runs inside an exception handler: a clawback
--     failure raises a warning plus an audit_events row and never blocks
--     the refund, the void or the action completion. record_payment_
--     refund is the only writer of payment_refunded events, so the
--     insert trigger is exactly "after the payment_refunded event is
--     written" while also covering any future writer. The void trigger
--     catches void_payment_refund and the void inside reopen_sleep_
--     trial_action alike; the completion trigger catches the manual
--     complete and every auto-complete path.
-- ============================================================================

create or replace function public.trg_clawback_refund()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  perform public.commission_clawback_for_refund(new.id);
  return new;
exception when others then
  raise warning 'commission_clawback_for_refund failed for refund %: %',
    new.id, sqlerrm;

  select s.company_id into v_company_id
  from public.sleep_journeys j
  join public.stores s on s.id = j.store_id
  where j.id = new.journey_id;

  begin
    perform public.log_audit_event(
      v_company_id,
      'journey_event',
      new.id,
      'COMMISSION_CLAWBACK_ERROR',
      null,
      jsonb_build_object(
        'event_id', new.id,
        'sqlstate', sqlstate,
        'error', sqlerrm
      ),
      'COMMISSION_CLAWBACK_FAILED',
      sqlerrm,
      new.journey_id,
      'SYSTEM'
    );
  exception when others then
    raise warning 'clawback audit write failed for refund %: %',
      new.id, sqlerrm;
  end;

  return new;
end;
$$;

revoke execute on function public.trg_clawback_refund()
  from public, anon, authenticated;

drop trigger if exists trg_zz_clawback_refund on public.journey_events;
create trigger trg_zz_clawback_refund
  after insert on public.journey_events
  for each row
  when (new.event_type = 'payment_refunded'
        and new.outcome = 'SUCCEEDED')
  execute function public.trg_clawback_refund();

create or replace function public.trg_clawback_refund_void()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  perform public.commission_void_clawbacks(new.id);
  return new;
exception when others then
  raise warning 'commission_void_clawbacks failed for refund %: %',
    new.id, sqlerrm;

  select s.company_id into v_company_id
  from public.sleep_journeys j
  join public.stores s on s.id = j.store_id
  where j.id = new.journey_id;

  begin
    perform public.log_audit_event(
      v_company_id,
      'journey_event',
      new.id,
      'COMMISSION_CLAWBACK_ERROR',
      null,
      jsonb_build_object(
        'event_id', new.id,
        'sqlstate', sqlstate,
        'error', sqlerrm
      ),
      'COMMISSION_CLAWBACK_VOID_FAILED',
      sqlerrm,
      new.journey_id,
      'SYSTEM'
    );
  exception when others then
    raise warning 'clawback void audit write failed for refund %: %',
      new.id, sqlerrm;
  end;

  return new;
end;
$$;

revoke execute on function public.trg_clawback_refund_void()
  from public, anon, authenticated;

drop trigger if exists trg_zz_clawback_refund_void on public.journey_events;
create trigger trg_zz_clawback_refund_void
  after update of outcome on public.journey_events
  for each row
  when (new.event_type = 'payment_refunded'
        and old.outcome is distinct from 'VOIDED'
        and new.outcome = 'VOIDED')
  execute function public.trg_clawback_refund_void();

create or replace function public.trg_action_completed_clawback()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  if new.action = 'EXCHANGE' then
    perform public.commission_clawback_for_exchange(new.id);
  end if;
  perform public.spiff_reverse_for_action(new.id);
  return new;
exception when others then
  raise warning 'action completion clawback failed for action %: %',
    new.id, sqlerrm;

  v_company_id := new.company_id;

  begin
    perform public.log_audit_event(
      v_company_id,
      'sleep_trial_action',
      new.id,
      'COMMISSION_CLAWBACK_ERROR',
      null,
      jsonb_build_object(
        'action_id', new.id,
        'action', new.action,
        'sqlstate', sqlstate,
        'error', sqlerrm
      ),
      'COMMISSION_CLAWBACK_FAILED',
      sqlerrm,
      new.journey_id,
      'SYSTEM'
    );
  exception when others then
    raise warning 'clawback audit write failed for action %: %',
      new.id, sqlerrm;
  end;

  return new;
end;
$$;

revoke execute on function public.trg_action_completed_clawback()
  from public, anon, authenticated;

drop trigger if exists trg_zz_action_completed_clawback
  on public.sleep_trial_actions;
create trigger trg_zz_action_completed_clawback
  after update of status on public.sleep_trial_actions
  for each row
  when (old.status is distinct from 'COMPLETED'
        and new.status = 'COMPLETED')
  execute function public.trg_action_completed_clawback();

-- ============================================================================
-- 11. commission_earn_for_unit: 175 body verbatim except the
--     sale_kind = 'EXCHANGE' early return is gone. Exchange child
--     journeys now earn on their replacement lines: same price and cost
--     snapshots, same credit-share resolution (the committer is the
--     child's assigned_employee_id, so absent explicit sale_credits the
--     employee who committed the exchange gets the credit). The credit
--     and fee lines have no product_id and still earn nothing.
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
      where fulfillment_unit_id is not null and reverses_entry_id is null
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
-- 12. list_commission_entries: same read plus a trailing type_label.
--     ADJUSTMENT rows get their reason label, SPIFF rows get the rule
--     name (Google review when there is no rule), COMMISSION rows get
--     'Commission'. The return type changed, so the function is dropped
--     and recreated; signature and filters are otherwise identical.
-- ============================================================================

drop function if exists public.list_commission_entries(date, date, uuid);

create function public.list_commission_entries(
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
               when 'UNLINKED_REFUND' = any(ce.flags)
                 then 'Unlinked refund'
               when 'CLAWBACK_VOIDED' = any(ce.flags)
                 then 'Clawback voided'
               when 'RETURN_CLAWBACK' = any(ce.flags)
                 then 'Return clawback'
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
-- 13. get_my_earnings: 181 body verbatim plus returns_cents, the net
--     signed total of the caller's return-adjustment rows (clawbacks
--     negative, clawback voids positive) inside the same period. The
--     client hides the Returns line when it is zero.
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

  -- No employee row: null, not an empty report, so the client can tell
  -- "no account" apart from "a real empty period".
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

  -- Cost leaves the server only when the switch is on AND the company
  -- prices commission on COMMISSION_COST. On the WHOLESALE basis this
  -- stays false no matter how the switch is set.
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
             'pending', (ce.amount_cents is null)
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

  -- Same effective-dated draw rule as the payout report: newest draw
  -- row at or before the period start, 0 when none exists.
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
-- 14. get_bonus_preview: 182 body verbatim except the COMMISSION_COST
--     cost branch in both aggregates. The margin test prices cost from
--     unit_cost_snapshot, which gave every adjustment row a positive
--     cost. Adjustment rows now scale the snapshot by their share of the
--     reversed original's revenue (the reversed chain's root for
--     clawback-voids), so the return is seen under both cost bases.
-- ============================================================================

create or replace function public.get_bonus_preview(p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_month_start date;
  v_month_end date;
  v_cost_basis text;
  v_plan_i_id uuid;
  v_plan_i_name text;
  v_plan_i_floor integer;
  v_plan_s_id uuid;
  v_plan_s_name text;
  v_plan_s_floor integer;
  v_ind jsonb := '[]'::jsonb;
  v_sto jsonb := '[]'::jsonb;
  r record;
  v_sales bigint;
  v_cost bigint;
  v_needs integer;
  v_margin_bp integer;
  v_margin_ok boolean;
  v_tier_threshold bigint;
  v_tier_base integer;
  v_tier_step bigint;
  v_tier_step_bonus integer;
  v_next bigint;
  v_bonus bigint;
  v_status text;
begin
  if not (
    public.has_permission('commission.payouts_view')
    or public.has_permission('commission.manage')
  ) then
    raise exception 'You do not have permission to view bonuses';
  end if;

  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_company_id is null or p_month is null then
    return null;
  end if;

  v_month_start := date_trunc('month', p_month)::date;
  v_month_end := (v_month_start + interval '1 month - 1 day')::date;

  select c.commission_cost_basis into v_cost_basis
  from public.companies c
  where c.id = v_company_id;

  -- Newest plan per scope whose window covers this month.
  select p.id, p.name, p.margin_floor_bp
    into v_plan_i_id, v_plan_i_name, v_plan_i_floor
  from public.bonus_plans p
  where p.company_id = v_company_id
    and p.scope = 'INDIVIDUAL'
    and p.starts_on <= v_month_start
  order by p.starts_on desc, p.created_at desc
  limit 1;

  select p.id, p.name, p.margin_floor_bp
    into v_plan_s_id, v_plan_s_name, v_plan_s_floor
  from public.bonus_plans p
  where p.company_id = v_company_id
    and p.scope = 'STORE'
    and p.starts_on <= v_month_start
  order by p.starts_on desc, p.created_at desc
  limit 1;

  for r in
    select a.employee_id,
           e.name as employee_name,
           e.home_store_id as store_id,
           a.sales_cents,
           a.cost_cents,
           a.needs_cost_count
    from (
      select ce.employee_id,
             coalesce(sum(
               case when ce.revenue_cents is not null
                    then floor(ce.revenue_cents::numeric
                         * coalesce(ce.credit_share_bp, 10000)
                         / 10000)::bigint
                    else 0 end), 0) as sales_cents,
             coalesce(sum(
               case when ce.revenue_cents is not null
                    then floor(
                         (case
                            when v_cost_basis = 'WHOLESALE'
                              then ce.cost_cents
                            else round(
                              li.unit_cost_snapshot * 100
                              * case
                                  when ce.kind = 'ADJUSTMENT'
                                       and orig.revenue_cents is not null
                                       and orig.revenue_cents <> 0
                                    then ce.revenue_cents::numeric
                                         / orig.revenue_cents
                                  else 1
                                end)::integer
                          end)::numeric
                         * coalesce(ce.credit_share_bp, 10000)
                         / 10000)::bigint
                    else 0 end), 0) as cost_cents,
             count(*) filter (
               where ce.revenue_cents is not null
                 and (case
                        when v_cost_basis = 'WHOLESALE'
                          then ce.cost_cents
                        else round(
                          li.unit_cost_snapshot * 100
                          * case
                              when ce.kind = 'ADJUSTMENT'
                                   and orig.revenue_cents is not null
                                   and orig.revenue_cents <> 0
                                then ce.revenue_cents::numeric
                                     / orig.revenue_cents
                              else 1
                            end)::integer
                      end) is null
             )::integer as needs_cost_count
      from public.commission_entries ce
      left join public.journey_line_items li
        on li.id = ce.line_item_id
      left join public.commission_entries parent
        on parent.id = ce.reverses_entry_id
      left join public.commission_entries orig
        on orig.id = coalesce(parent.reverses_entry_id, parent.id)
      where ce.company_id = v_company_id
        and ce.employee_id is not null
        and ce.kind in ('COMMISSION', 'ADJUSTMENT')
        and ce.earned_date between v_month_start and v_month_end
      group by ce.employee_id
    ) a
    join public.employees e on e.id = a.employee_id
    order by e.name
  loop
    v_sales := r.sales_cents;
    v_cost := r.cost_cents;
    v_needs := r.needs_cost_count;
    v_margin_bp := case when v_sales > 0
                        then floor((v_sales - v_cost) * 10000
                                   / v_sales)::integer
                        else null end;
    v_margin_ok := v_sales > 0
                   and v_needs = 0
                   and v_plan_i_id is not null
                   and (v_sales - v_cost) * 10000
                       >= v_plan_i_floor * v_sales;

    v_tier_threshold := null;
    v_tier_base := null;
    v_tier_step := null;
    v_tier_step_bonus := null;
    v_next := null;
    v_bonus := null;

    if v_plan_i_id is null then
      v_status := 'NO_PLAN';
    elsif v_needs > 0 then
      v_status := 'NEEDS_COST';
    elsif not v_margin_ok then
      v_status := 'BELOW_MARGIN';
      v_bonus := 0;
    else
      select t.threshold_cents, t.base_cents, t.step_cents,
             t.step_bonus_cents
        into v_tier_threshold, v_tier_base, v_tier_step,
             v_tier_step_bonus
      from public.bonus_plan_tiers t
      where t.plan_id = v_plan_i_id
        and t.threshold_cents <= v_sales
      order by t.threshold_cents desc
      limit 1;

      select min(t.threshold_cents) into v_next
      from public.bonus_plan_tiers t
      where t.plan_id = v_plan_i_id
        and t.threshold_cents > v_sales;

      if v_tier_threshold is null then
        v_status := 'BELOW_TIER';
        v_bonus := 0;
      else
        v_status := 'PAID_TIER';
        v_bonus := v_tier_base
          + v_tier_step_bonus
            * floor((v_sales - v_tier_threshold)::numeric
                    / v_tier_step)::bigint;
      end if;
    end if;

    v_ind := v_ind || jsonb_build_object(
      'employee_id', r.employee_id,
      'name', r.employee_name,
      'store_id', r.store_id,
      'sales_cents', v_sales,
      'cost_cents', v_cost,
      'margin_bp', v_margin_bp,
      'margin_ok', coalesce(v_margin_ok, false),
      'needs_cost_count', v_needs,
      'plan_name', v_plan_i_name,
      'tier_threshold_cents', v_tier_threshold,
      'bonus_cents', v_bonus,
      'next_threshold_cents', v_next,
      'to_next_cents',
        case when v_next is not null then v_next - v_sales end,
      'status', v_status
    );
  end loop;

  for r in
    select a.store_id,
           s.name as store_name,
           a.sales_cents,
           a.cost_cents,
           a.needs_cost_count
    from (
      select ce.store_id,
             coalesce(sum(
               case when ce.revenue_cents is not null
                    then floor(ce.revenue_cents::numeric
                         * coalesce(ce.credit_share_bp, 10000)
                         / 10000)::bigint
                    else 0 end), 0) as sales_cents,
             coalesce(sum(
               case when ce.revenue_cents is not null
                    then floor(
                         (case
                            when v_cost_basis = 'WHOLESALE'
                              then ce.cost_cents
                            else round(
                              li.unit_cost_snapshot * 100
                              * case
                                  when ce.kind = 'ADJUSTMENT'
                                       and orig.revenue_cents is not null
                                       and orig.revenue_cents <> 0
                                    then ce.revenue_cents::numeric
                                         / orig.revenue_cents
                                  else 1
                                end)::integer
                          end)::numeric
                         * coalesce(ce.credit_share_bp, 10000)
                         / 10000)::bigint
                    else 0 end), 0) as cost_cents,
             count(*) filter (
               where ce.revenue_cents is not null
                 and (case
                        when v_cost_basis = 'WHOLESALE'
                          then ce.cost_cents
                        else round(
                          li.unit_cost_snapshot * 100
                          * case
                              when ce.kind = 'ADJUSTMENT'
                                   and orig.revenue_cents is not null
                                   and orig.revenue_cents <> 0
                                then ce.revenue_cents::numeric
                                     / orig.revenue_cents
                              else 1
                            end)::integer
                      end) is null
             )::integer as needs_cost_count
      from public.commission_entries ce
      left join public.journey_line_items li
        on li.id = ce.line_item_id
      left join public.commission_entries parent
        on parent.id = ce.reverses_entry_id
      left join public.commission_entries orig
        on orig.id = coalesce(parent.reverses_entry_id, parent.id)
      where ce.company_id = v_company_id
        and ce.store_id is not null
        and ce.kind in ('COMMISSION', 'ADJUSTMENT')
        and ce.earned_date between v_month_start and v_month_end
      group by ce.store_id
    ) a
    join public.stores s on s.id = a.store_id
    order by s.name
  loop
    v_sales := r.sales_cents;
    v_cost := r.cost_cents;
    v_needs := r.needs_cost_count;
    v_margin_bp := case when v_sales > 0
                        then floor((v_sales - v_cost) * 10000
                                   / v_sales)::integer
                        else null end;
    v_margin_ok := v_sales > 0
                   and v_needs = 0
                   and v_plan_s_id is not null
                   and (v_sales - v_cost) * 10000
                       >= v_plan_s_floor * v_sales;

    v_tier_threshold := null;
    v_tier_base := null;
    v_tier_step := null;
    v_tier_step_bonus := null;
    v_next := null;
    v_bonus := null;

    if v_plan_s_id is null then
      v_status := 'NO_PLAN';
    elsif v_needs > 0 then
      v_status := 'NEEDS_COST';
    elsif not v_margin_ok then
      v_status := 'BELOW_MARGIN';
      v_bonus := 0;
    else
      select t.threshold_cents, t.base_cents, t.step_cents,
             t.step_bonus_cents
        into v_tier_threshold, v_tier_base, v_tier_step,
             v_tier_step_bonus
      from public.bonus_plan_tiers t
      where t.plan_id = v_plan_s_id
        and t.threshold_cents <= v_sales
      order by t.threshold_cents desc
      limit 1;

      select min(t.threshold_cents) into v_next
      from public.bonus_plan_tiers t
      where t.plan_id = v_plan_s_id
        and t.threshold_cents > v_sales;

      if v_tier_threshold is null then
        v_status := 'BELOW_TIER';
        v_bonus := 0;
      else
        v_status := 'PAID_TIER';
        v_bonus := v_tier_base
          + v_tier_step_bonus
            * floor((v_sales - v_tier_threshold)::numeric
                    / v_tier_step)::bigint;
      end if;
    end if;

    v_sto := v_sto || jsonb_build_object(
      'store_id', r.store_id,
      'store_name', r.store_name,
      'sales_cents', v_sales,
      'cost_cents', v_cost,
      'margin_bp', v_margin_bp,
      'margin_ok', coalesce(v_margin_ok, false),
      'needs_cost_count', v_needs,
      'plan_name', v_plan_s_name,
      'tier_threshold_cents', v_tier_threshold,
      'bonus_cents', v_bonus,
      'next_threshold_cents', v_next,
      'to_next_cents',
        case when v_next is not null then v_next - v_sales end,
      'status', v_status,
      'manager_employee_ids',
        (select coalesce(jsonb_agg(e.id order by e.name), '[]'::jsonb)
         from public.employees e
         where e.home_store_id = r.store_id
           and e.role = 'manager'
           and e.is_active)
    );
  end loop;

  return jsonb_build_object(
    'month_start', v_month_start,
    'month_end', v_month_end,
    'paid_on',
      public.commission_spiff_pay_date_for_month(
        v_company_id, v_month_start),
    'individual', v_ind,
    'store', v_sto
  );
end;
$$;

revoke execute on function public.get_bonus_preview(date)
  from public, anon;
grant execute on function public.get_bonus_preview(date)
  to authenticated;

-- ============================================================================
-- 15. guard_journey_line_item_mutation: 076 body verbatim plus the
--     earned-unit lock. A line with any fulfilled unit that earned a
--     COMMISSION entry cannot have unit_price or quantity changed, on
--     any journey state: a partially fulfilled order has no delivered_at
--     and was previously editable even after money earned. The metadata
--     carve-out is untouched.
-- ============================================================================

create or replace function public.guard_journey_line_item_mutation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_journey_id uuid;
  v_delivered date;
  v_state public.journey_state;
begin
  v_journey_id := coalesce(new.journey_id, old.journey_id);

  select delivered_at, current_state
    into v_delivered, v_state
  from public.sleep_journeys
  where id = v_journey_id;

  if not found then
    return coalesce(new, old);
  end if;

  -- A fulfilled unit that earned commission freezes this line's price
  -- and quantity on every journey state, including partially fulfilled
  -- orders that have no delivered_at yet. Commission rows are append
  -- only; corrections go through the return or exchange flow.
  if tg_op = 'UPDATE'
     and (new.unit_price is distinct from old.unit_price
          or new.quantity is distinct from old.quantity)
     and exists (
       select 1
       from public.journey_fulfillment_units jfu
       join public.commission_entries ce
         on ce.fulfillment_unit_id = jfu.id
       where jfu.line_item_id = old.id
         and ce.kind = 'COMMISSION'
     ) then
    raise exception 'Cannot change price or quantity on a line whose units already earned commission - use the return or exchange flow';
  end if;

  -- Pre-delivery journeys are unaffected.
  if v_delivered is null
     and v_state not in ('Sleep Trial', 'Completed') then
    return coalesce(new, old);
  end if;

  -- Delivered / trial-active / completed: business fields are frozen.
  -- System metadata updates (trial_ineligible_reason, updated_at) pass.
  if tg_op = 'UPDATE'
     and new.journey_id = old.journey_id
     and new.product_id is not distinct from old.product_id
     and new.item_name is not distinct from old.item_name
     and new.quantity is not distinct from old.quantity
     and new.unit_price is not distinct from old.unit_price
     and new.fulfillment_type_override is not distinct from old.fulfillment_type_override
     and new.pickup_location_id is not distinct from old.pickup_location_id
     and new.pair_group_id is not distinct from old.pair_group_id
     and new.sold_condition is not distinct from old.sold_condition
  then
    return new;
  end if;

  raise exception 'Cannot modify line items on a delivered journey - use the exchange flow';
end;
$$;

-- ============================================================================
-- 16. get_spiff_return_mode / set_spiff_return_mode: same permission
--     behaviour as the spiff settings pair (read = any active employee,
--     write = commission.manage or commission.spiffs_manage, audited
--     before and after). get/set_spiff_settings are untouched.
-- ============================================================================

create or replace function public.get_spiff_return_mode()
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_mode text;
begin
  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_company_id is null then
    return null;
  end if;

  select c.spiff_return_mode into v_mode
  from public.companies c
  where c.id = v_company_id;

  return v_mode;
end;
$$;

revoke execute on function public.get_spiff_return_mode()
  from public, anon;
grant execute on function public.get_spiff_return_mode()
  to authenticated;

create or replace function public.set_spiff_return_mode(p_mode text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_before jsonb;
  v_after jsonb;
begin
  if not (
    public.has_permission('commission.manage')
    or public.has_permission('commission.spiffs_manage')
  ) then
    raise exception 'You do not have permission to manage spiff settings';
  end if;

  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_company_id is null then
    raise exception 'Not authenticated as an employee';
  end if;

  if p_mode not in ('NEVER', 'FULL_RETURN') then
    raise exception 'Return mode must be NEVER or FULL_RETURN';
  end if;

  select jsonb_build_object('spiff_return_mode', c.spiff_return_mode)
    into v_before
  from public.companies c
  where c.id = v_company_id;

  update public.companies c
  set spiff_return_mode = p_mode
  where c.id = v_company_id;

  v_after := jsonb_build_object('spiff_return_mode', p_mode);

  perform public.log_audit_event(
    v_company_id,
    'companies',
    v_company_id,
    'SPIFF_RETURN_MODE_SET',
    v_before,
    v_after
  );
end;
$$;

revoke execute on function public.set_spiff_return_mode(text)
  from public, anon;
grant execute on function public.set_spiff_return_mode(text)
  to authenticated;

-- ============================================================================
-- 17. Exchange replacement-sale credit.
--
--     The existing sleep_trial_actions.sale_attribution_employee_id
--     column already means "who gets credit for this sale": drafts have
--     auto-stored the creating employee there since 087 and nothing has
--     ever read it. It now carries the CHOSEN credit employee: drafts
--     insert null (default = the original journey's credit), a non-null
--     value is the override the commit path reads.
-- ============================================================================

-- 17a. Drafts created before this change store the creator in
--      sale_attribution_employee_id even though nobody chose it. Rows
--      where the stored value is just the auto-populated creator are
--      nulled back to the default; a deliberately chosen different
--      employee survives a re-run.

update public.sleep_trial_actions
set sale_attribution_employee_id = null
where status = 'DRAFT'
  and sale_attribution_employee_id = created_by;

-- 17b. create_exchange_draft: 088 body verbatim except
--      sale_attribution_employee_id inserts null instead of the creator.

create or replace function public.create_exchange_draft(
  p_trial_item_id uuid,
  p_action text,
  p_replacement_product_id uuid,
  p_replacement_variant_id uuid,
  p_fulfillment_method text,
  p_idempotency_key text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_item public.sleep_trial_items%rowtype;
  v_company uuid;
  v_employee uuid;
  v_existing uuid;
  v_existing_item uuid;
  v_existing_action text;
  v_open record;
  v_quote jsonb;
  v_action_id uuid;
  v_exception_id uuid;
begin
  if p_action not in ('EXCHANGE','RETURN') then
    raise exception 'action must be EXCHANGE or RETURN';
  end if;

  if p_action = 'EXCHANGE'
     and not public.has_permission('sleep_trial.start_exchange') then
    raise exception 'Missing permission: sleep_trial.start_exchange';
  end if;
  if p_action = 'RETURN'
     and not public.has_permission('sleep_trial.start_return') then
    raise exception 'Missing permission: sleep_trial.start_return';
  end if;

  if p_fulfillment_method is not null
     and p_fulfillment_method not in ('delivery','pickup') then
    raise exception 'fulfillment_method must be delivery or pickup';
  end if;

  select e.id into v_employee
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;

  -- Lock the trial item: the ACTIVE check and the open-action check must
  -- serialize against a concurrent draft/commit on the same mattress.
  select * into v_item
  from public.sleep_trial_items
  where id = p_trial_item_id
  for update;
  if not found then
    raise exception 'Trial item not found';
  end if;
  if not public.is_journey_visible(v_item.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select st.company_id into v_company
  from public.sleep_journeys sj
  join public.stores st on st.id = sj.store_id
  where sj.id = v_item.journey_id;

  -- Idempotent retry: the same key returns the stored id, but only when
  -- the replay is for the same trial item and action - a key reused with
  -- different parameters is an error, not a silent hit.
  if p_idempotency_key is not null then
    select a.id, a.trial_item_id, a.action
      into v_existing, v_existing_item, v_existing_action
    from public.sleep_trial_actions a
    where a.company_id = v_company
      and a.idempotency_key = p_idempotency_key;
    if v_existing is not null then
      if v_existing_item is distinct from p_trial_item_id
         or v_existing_action is distinct from p_action then
        raise exception
          'Idempotency key "%" was already used for a different draft',
          p_idempotency_key;
      end if;
      return v_existing;
    end if;
  end if;

  -- The replacement variant must belong to this company (the quote only
  -- validates replacement_product_id).
  if p_replacement_variant_id is not null
     and not exists (
       select 1 from public.products p
       where p.id = p_replacement_variant_id
         and p.company_id = v_company) then
    raise exception 'Replacement variant not found in this company';
  end if;

  if v_item.status <> 'ACTIVE' then
    raise exception 'This mattress''s trial is not active (status %)',
      v_item.status;
  end if;

  -- Friendly pre-check; the partial unique index is the real guarantee.
  select a.id, e.name into v_open
  from public.sleep_trial_actions a
  left join public.employees e on e.id = a.created_by
  where a.trial_item_id = p_trial_item_id
    and a.status in ('DRAFT','COMMITTED')
  limit 1;
  if v_open.id is not null then
    raise exception 'An exchange or return is already in progress for this mattress (started by %)',
      coalesce(v_open.name, 'another employee');
  end if;

  v_quote := public.quote_sleep_trial_action(
    p_trial_item_id, p_action, p_replacement_product_id);

  v_exception_id := nullif(
    v_quote #>> '{applicable_exception,exception_id}', '')::uuid;

  insert into public.sleep_trial_actions (
    company_id,
    journey_id,
    trial_item_id,
    action,
    status,
    locked_evaluation,
    locked_fee_cents,
    exception_id,
    replacement_product_id,
    replacement_variant_id,
    replacement_quantity,
    replacement_price_cents,
    original_credit_cents,
    exchange_fee_cents,
    other_fees_cents,
    net_cents,
    refund_owed_cents,
    commission_basis_cents,
    sale_attribution_employee_id,
    fulfillment_method,
    idempotency_key,
    created_by
  ) values (
    v_company,
    v_item.journey_id,
    p_trial_item_id,
    p_action,
    'DRAFT',
    v_quote -> 'evaluation',
    nullif(v_quote ->> 'locked_fee_cents', '')::int,
    v_exception_id,
    p_replacement_product_id,
    p_replacement_variant_id,
    case when p_action = 'EXCHANGE' then 1 else null end,
    nullif(v_quote ->> 'replacement_price_cents', '')::int,
    nullif(v_quote ->> 'original_credit_cents', '')::int,
    nullif(v_quote ->> 'locked_fee_cents', '')::int,
    0,
    nullif(v_quote ->> 'net_cents', '')::int,
    nullif(v_quote ->> 'refund_owed_cents', '')::int,
    nullif(v_quote ->> 'commission_basis_cents', '')::int,
    null,  -- 185: no credit choice yet; default = original seller(s)
    p_fulfillment_method,
    p_idempotency_key,
    v_employee
  )
  returning id into v_action_id;

  perform public.log_audit_event(
    p_company_id := v_company,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := v_action_id,
    p_event_type := 'EXCHANGE_DRAFT_CREATED',
    p_after := jsonb_build_object(
      'action', p_action,
      'status', 'DRAFT',
      'trial_item_id', p_trial_item_id,
      'replacement_product_id', p_replacement_product_id,
      'fulfillment_method', p_fulfillment_method,
      'net_cents', nullif(v_quote ->> 'net_cents', '')::int,
      'exception_id', v_exception_id),
    p_journey_id := v_item.journey_id,
    p_actor_employee_id := v_employee
  );

  return v_action_id;
exception
  when unique_violation then
    -- Race: either the idempotency key or the open-action index tripped.
    if p_idempotency_key is not null then
      select a.id, a.trial_item_id, a.action
        into v_existing, v_existing_item, v_existing_action
      from public.sleep_trial_actions a
      where a.company_id = v_company
        and a.idempotency_key = p_idempotency_key;
      if v_existing is not null then
        if v_existing_item is distinct from p_trial_item_id
           or v_existing_action is distinct from p_action then
          raise exception
            'Idempotency key "%" was already used for a different draft',
            p_idempotency_key;
        end if;
        return v_existing;
      end if;
    end if;
    raise exception 'An exchange or return is already in progress for this mattress';
end;
$$;

revoke execute on function public.create_exchange_draft(
  uuid, text, uuid, uuid, text, text) from public, anon;
grant execute on function public.create_exchange_draft(
  uuid, text, uuid, uuid, text, text) to authenticated;

-- 17c. Child-journey credit. The commit creates the child inside its own
--      transaction; triggers on that insert keep commit_sleep_trial_
--      action untouched while applying the credit rule to the only place
--      exchange children are created.
--        BEFORE INSERT: exchange_action_id names the action. A chosen
--          credit employee becomes the child's assigned_employee_id;
--          otherwise the child inherits the ORIGINAL journey's assigned
--          employee (the committer is never the default any more).
--        AFTER INSERT: a chosen credit employee gets one EMPLOYEE
--          sale_credits row at 10000 bp. Otherwise the original
--          journey's active sale_credits rows are copied as-is, so a
--          50/50 split stays 50/50. When the original has no active rows
--          nothing is written and commission_credit_shares' assigned-
--          employee fallback gives the original seller 100 percent.

create or replace function public.trg_exchange_child_assign()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attr uuid;
begin
  select a.sale_attribution_employee_id into v_attr
  from public.sleep_trial_actions a
  where a.id = new.exchange_action_id;

  if v_attr is not null then
    new.assigned_employee_id := v_attr;
  else
    select sj.assigned_employee_id into new.assigned_employee_id
    from public.sleep_journeys sj
    where sj.id = new.parent_journey_id;
  end if;

  return new;
end;
$$;

revoke execute on function public.trg_exchange_child_assign()
  from public, anon, authenticated;

drop trigger if exists trg_exchange_child_assign on public.sleep_journeys;
create trigger trg_exchange_child_assign
  before insert on public.sleep_journeys
  for each row
  when (new.exchange_action_id is not null)
  execute function public.trg_exchange_child_assign();

create or replace function public.trg_exchange_child_credits()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attr uuid;
  v_company uuid;
  v_emp uuid;
begin
  select a.sale_attribution_employee_id into v_attr
  from public.sleep_trial_actions a
  where a.id = new.exchange_action_id;

  select s.company_id into v_company
  from public.stores s
  where s.id = new.store_id;

  select e.id into v_emp
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_attr is not null then
    insert into public.sale_credits (
      company_id, journey_id, kind, employee_id, share_bp,
      reason, created_by
    ) values (
      v_company, new.id, 'EMPLOYEE', v_attr, 10000,
      'Exchange credit override', v_emp
    );
  else
    insert into public.sale_credits (
      company_id, journey_id, kind, employee_id, store_id, share_bp,
      reason, created_by
    )
    select v_company, new.id, sc.kind, sc.employee_id, sc.store_id,
           sc.share_bp, 'Exchange credit inherited', v_emp
    from public.sale_credits sc
    where sc.journey_id = new.parent_journey_id
      and sc.superseded_at is null;
  end if;

  return new;
end;
$$;

revoke execute on function public.trg_exchange_child_credits()
  from public, anon, authenticated;

drop trigger if exists trg_exchange_child_credits on public.sleep_journeys;
create trigger trg_exchange_child_credits
  after insert on public.sleep_journeys
  for each row
  when (new.exchange_action_id is not null)
  execute function public.trg_exchange_child_credits();

-- 17d. set_exchange_credit_employee: choose the replacement-sale credit
--      while the action is a DRAFT. Same gate as create_exchange_draft
--      and commit_sleep_trial_action (sleep_trial.start_exchange plus
--      journey visibility); the chosen employee must be an active
--      employee of the action's company; null restores the default.

create or replace function public.set_exchange_credit_employee(
  p_action_id uuid,
  p_employee_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_employee uuid;
  v_before uuid;
begin
  if not public.has_permission('sleep_trial.start_exchange') then
    raise exception 'Missing permission: sleep_trial.start_exchange';
  end if;

  select e.id into v_employee
  from public.employees e
  where e.auth_user_id = auth.uid()
    and e.is_active;
  if v_employee is null then
    raise exception 'Employee record not found';
  end if;

  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id
  for update;
  if not found then
    raise exception 'Exchange action not found';
  end if;
  if not public.is_journey_visible(v_action.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;
  if v_action.action <> 'EXCHANGE' then
    raise exception 'Credit can only be chosen on an exchange action';
  end if;
  if v_action.status <> 'DRAFT' then
    raise exception 'Only a draft can change credit (status %)',
      v_action.status;
  end if;

  if p_employee_id is not null
     and not exists (
       select 1
       from public.employees e
       join public.stores s on s.id = e.home_store_id
       where e.id = p_employee_id
         and e.is_active
         and s.company_id = v_action.company_id) then
    raise exception 'Employee not found or not active in this company';
  end if;

  v_before := v_action.sale_attribution_employee_id;

  update public.sleep_trial_actions
  set sale_attribution_employee_id = p_employee_id
  where id = p_action_id;

  perform public.log_audit_event(
    p_company_id := v_action.company_id,
    p_entity_type := 'sleep_trial_action',
    p_entity_id := p_action_id,
    p_event_type := 'EXCHANGE_CREDIT_EMPLOYEE_SET',
    p_before := jsonb_build_object(
      'sale_attribution_employee_id', v_before),
    p_after := jsonb_build_object(
      'sale_attribution_employee_id', p_employee_id),
    p_journey_id := v_action.journey_id,
    p_actor_employee_id := v_employee
  );
end;
$$;

revoke execute on function public.set_exchange_credit_employee(uuid, uuid)
  from public, anon;
grant execute on function public.set_exchange_credit_employee(uuid, uuid)
  to authenticated;

-- 17e. get_exchange_credit_info: the builder's read for the credit
--      select. Returns the current choice plus the default label,
--      derived from the original journey's active employee credit rows
--      (commission.manage-only reads) or its assigned employee.

create or replace function public.get_exchange_credit_info(
  p_action_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_action public.sleep_trial_actions%rowtype;
  v_credit_count integer;
  v_credit_name text;
  v_label text;
begin
  select * into v_action
  from public.sleep_trial_actions
  where id = p_action_id;
  if not found then
    raise exception 'Exchange action not found';
  end if;
  if not public.is_journey_visible(v_action.journey_id) then
    raise exception 'Not authorized for this journey';
  end if;

  select count(*), max(e.name)
    into v_credit_count, v_credit_name
  from public.sale_credits sc
  join public.employees e on e.id = sc.employee_id
  where sc.journey_id = v_action.journey_id
    and sc.kind = 'EMPLOYEE'
    and sc.superseded_at is null;

  if v_credit_count = 1 then
    v_label := 'Original seller (' || v_credit_name || ')';
  elsif v_credit_count > 1 then
    v_label := 'Original sellers';
  else
    select e.name into v_credit_name
    from public.sleep_journeys sj
    join public.employees e on e.id = sj.assigned_employee_id
    where sj.id = v_action.journey_id;
    v_label := case when v_credit_name is not null
                    then 'Original seller (' || v_credit_name || ')'
                    else 'Original seller' end;
  end if;

  return jsonb_build_object(
    'credit_employee_id', v_action.sale_attribution_employee_id,
    'default_credit_label', v_label);
end;
$$;

revoke execute on function public.get_exchange_credit_info(uuid)
  from public, anon;
grant execute on function public.get_exchange_credit_info(uuid)
  to authenticated;
