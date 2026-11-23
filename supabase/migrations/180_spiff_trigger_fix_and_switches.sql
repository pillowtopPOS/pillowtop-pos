-- 180_spiff_trigger_fix_and_switches.sql
--
-- Part A (bug fix): spiffs never earned for orders that never produce a
-- journey_updated_to_sold event. Pickup order SJ-MS00289, for example,
-- went line_item_added -> payment_completed -> inventory_received and
-- the earn trigger, which only listened for journey_updated_to_sold,
-- never ran. The trigger now also fires on payment_completed and
-- deposit_received, and spiff_earn_for_sale falls back to the earliest
-- payment_completed event when no sold event exists. All existing
-- guards stay: real journey, not cancelled, has lines, price > 0 and
-- paid in full, plus the dedup index keeps repeated events idempotent.
--
-- Part B: two company switches. companies.spiffs_enabled gates NEW
-- product, brand and category spiff earning (existing entries stay
-- payable). companies.google_reviews_enabled gates NEW review logging;
-- listing and voiding keep working so history can be managed. Rules
-- can still be edited while spiffs are off. Turning a switch back on
-- never backfills past sales.

-- ============================================================================
-- 1. Company switches. The whole add + backfill sits inside one guarded
--    DO block that runs only while the columns are missing, so a second
--    run of this migration can never reset values an owner changed.
-- ============================================================================

do $$
begin
  if not exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'companies'
      and column_name = 'spiffs_enabled'
  ) then
    alter table public.companies
      add column spiffs_enabled boolean not null default false,
      add column google_reviews_enabled boolean not null default false;

    -- Every company already live had spiffs and reviews on before this
    -- column existed, so existing rows start true; fresh companies get
    -- the column default of false.
    update public.companies
    set spiffs_enabled = true,
        google_reviews_enabled = true
    where id is not null;
  end if;
end $$;

-- ============================================================================
-- 2. spiff_earn_for_sale: honor spiffs_enabled and take the sale time
--    from the earliest sold event, or the earliest payment_completed
--    event when no sold event exists. Everything else unchanged.
-- ============================================================================

create or replace function public.spiff_earn_for_sale(
  p_journey_id uuid,
  p_sold_at timestamptz
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_j record;
  v_sold_at timestamptz;
  v_sale_date date;
  v_line record;
  v_rule record;
  v_share record;
  v_amount integer;
  v_inserted integer;
  v_written integer := 0;
begin
  select j.id, j.store_id, j.price, j.cancelled_at, s.company_id,
         coalesce(s.timezone, c.business_timezone) as tz,
         c.spiffs_enabled
    into v_j
  from public.sleep_journeys j
  join public.stores s on s.id = j.store_id
  join public.companies c on c.id = s.company_id
  where j.id = p_journey_id;

  -- The event row that fired the trigger cannot be trusted (see the
  -- comment on trg_zz_spiff_earn below), so "sold" is proven here
  -- instead of taken from current_state: the journey must exist, be
  -- uncancelled, carry at least one line item, be priced above zero,
  -- be paid in full, and the company must have spiffs turned on.
  -- Turning spiffs off only stops NEW earning; existing entries stay
  -- payable and there is no backfill when it turns back on.
  if v_j.id is null
     or not v_j.spiffs_enabled
     or v_j.cancelled_at is not null
     or v_j.price is null
     or v_j.price <= 0
     or not exists (
       select 1 from public.journey_line_items li
       where li.journey_id = p_journey_id
     )
     or coalesce(public.total_paid(p_journey_id), 0) < v_j.price then
    return 0;
  end if;

  -- The sale time is the FIRST journey_updated_to_sold event ever
  -- written, or when there is none (pickup orders can go straight to
  -- payment_completed) the FIRST payment_completed event. It is never
  -- the current event, so a re-fired, hand-inserted or later payment
  -- event can never move the sale date forward onto a newer rule. A
  -- deposit alone does not mark the sale; the first completed payment
  -- does.
  select coalesce(
    (select min(e.created_at)
       from public.journey_events e
      where e.journey_id = p_journey_id
        and e.event_type = 'journey_updated_to_sold'),
    (select min(e.created_at)
       from public.journey_events e
      where e.journey_id = p_journey_id
        and e.event_type = 'payment_completed')
  ) into v_sold_at;

  if v_sold_at is null then
    return 0;
  end if;

  v_sale_date := (v_sold_at at time zone coalesce(v_j.tz, 'UTC'))::date;

  for v_line in
    select li.id as line_item_id, li.product_id, li.quantity,
           p.brand, pc.name as category_name
    from public.journey_line_items li
    join public.products p on p.id = li.product_id
    left join public.product_categories pc on pc.id = p.category_id
    where li.journey_id = p_journey_id
      and li.product_id is not null
      and li.quantity > 0
  loop
    for v_rule in
      select r.id, r.amount_cents
      from public.spiff_rules r
      where r.company_id = v_j.company_id
        and r.is_active
        and (r.starts_on is null or r.starts_on <= v_sale_date)
        and (r.ends_on is null or r.ends_on >= v_sale_date)
        and (
          (r.scope = 'PRODUCT' and r.product_id = v_line.product_id)
          or (r.scope = 'BRAND' and v_line.brand is not null
              and lower(btrim(r.scope_value)) = lower(btrim(v_line.brand)))
          or (r.scope = 'CATEGORY' and v_line.category_name is not null
              and lower(btrim(r.scope_value))
                  = lower(btrim(v_line.category_name)))
        )
    loop
      for v_share in
        select cs.employee_id, cs.share_bp
        from public.commission_credit_shares(p_journey_id) cs
        where cs.kind = 'EMPLOYEE'
          and cs.employee_id is not null
      loop
        -- cents per unit * quantity * share, rounded half up.
        v_amount := floor(
          v_rule.amount_cents::numeric * v_line.quantity
            * v_share.share_bp / 10000 + 0.5
        )::integer;

        insert into public.commission_entries (
          company_id, journey_id, line_item_id, fulfillment_unit_id,
          employee_id, store_id, kind, amount_cents, earned_at,
          earned_date, pay_period_start, revenue_cents, cost_cents,
          rate_bp, credit_share_bp, flags, spiff_rule_id, review_spiff_id
        ) values (
          v_j.company_id, p_journey_id, v_line.line_item_id, null,
          v_share.employee_id, v_j.store_id, 'SPIFF', v_amount,
          v_sold_at, v_sale_date,
          coalesce(
            public.commission_pay_period_start(v_j.company_id, v_sale_date),
            v_sale_date
          ),
          null, null, null, v_share.share_bp, '{}',
          v_rule.id, null
        )
        on conflict (line_item_id, employee_id, spiff_rule_id)
          where kind = 'SPIFF'
            and reverses_entry_id is null
            and spiff_rule_id is not null
          do nothing;

        get diagnostics v_inserted = row_count;
        v_written := v_written + v_inserted;
      end loop;
    end loop;
  end loop;

  return v_written;
end;
$$;

revoke execute on function public.spiff_earn_for_sale(uuid, timestamptz)
  from public, anon, authenticated;

-- journey_events is directly insertable by authenticated users (a known
-- go-live gate, not just a spiffs problem), so this trigger cannot trust
-- the event; the paid-in-full proof inside spiff_earn_for_sale is what
-- stops a hand-inserted sold or payment event from paying out. The
-- trigger listens for payment_completed and deposit_received as well as
-- the sold event because sold journeys do not always emit one.
drop trigger if exists trg_zz_spiff_earn on public.journey_events;
create trigger trg_zz_spiff_earn
  after insert on public.journey_events
  for each row
  when (new.event_type in ('journey_updated_to_sold',
                           'payment_completed',
                           'deposit_received'))
  execute function public.trg_spiff_earn();

-- ============================================================================
-- 3. log_google_review gated on google_reviews_enabled. Everything else
--    identical to the 178 version; void and list stay available so the
--    history can still be managed while logging is off.
-- ============================================================================

create or replace function public.log_google_review(
  p_journey_id uuid,
  p_review_date date,
  p_amount_cents integer default 2500,
  p_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_caller_employee_id uuid;
  v_j record;
  v_review_id uuid;
  v_earned date;
  v_share record;
begin
  if not public.has_permission('commission.spiffs_log_review') then
    raise exception 'You do not have permission to log reviews';
  end if;

  select e.id, s.company_id
    into v_caller_employee_id, v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_company_id is null then
    raise exception 'Not authenticated as an employee';
  end if;

  select j.id, j.store_id, s.company_id
    into v_j
  from public.sleep_journeys j
  join public.stores s on s.id = j.store_id
  where j.id = p_journey_id;

  if v_j.id is null or v_j.company_id <> v_company_id then
    raise exception 'Journey does not belong to your company';
  end if;

  -- Company switch: review logging can be turned off without losing the
  -- history. void_google_review and list_google_reviews keep working.
  if not (select c.google_reviews_enabled
          from public.companies c
          where c.id = v_j.company_id) then
    raise exception 'Google review logging is turned off';
  end if;

  if p_review_date is null then
    raise exception 'review_date is required';
  end if;

  v_earned := coalesce(public.business_today(v_j.store_id), current_date);

  if p_review_date > v_earned then
    raise exception 'review_date cannot be in the future';
  end if;

  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'amount_cents must be greater than 0';
  end if;

  begin
    insert into public.google_review_spiffs (
      company_id, journey_id, review_date, amount_cents, note, logged_by
    ) values (
      v_company_id, p_journey_id, p_review_date, p_amount_cents,
      p_note, v_caller_employee_id
    )
    returning id into v_review_id;
  exception
    when unique_violation then
      raise exception 'An active review is already logged for this journey';
  end;

  -- One entry per current EMPLOYEE credit holder, split by share. The
  -- spiff belongs to the credit holders, not to whoever typed the log.
  -- earned_date is today, not the review date, and revenue, cost and
  -- rate stay null because there is no margin math.
  for v_share in
    select cs.employee_id, cs.share_bp
    from public.commission_credit_shares(p_journey_id) cs
    where cs.kind = 'EMPLOYEE'
      and cs.employee_id is not null
  loop
    insert into public.commission_entries (
      company_id, journey_id, line_item_id, fulfillment_unit_id,
      employee_id, store_id, kind, amount_cents, earned_at, earned_date,
      pay_period_start, revenue_cents, cost_cents, rate_bp,
      credit_share_bp, flags, note, spiff_rule_id, review_spiff_id
    ) values (
      v_company_id, p_journey_id, null, null,
      v_share.employee_id, v_j.store_id, 'SPIFF',
      floor(p_amount_cents::numeric * v_share.share_bp / 10000 + 0.5)::integer,
      now(), v_earned,
      coalesce(
        public.commission_pay_period_start(v_company_id, v_earned),
        v_earned
      ),
      null, null, null, v_share.share_bp, '{}',
      p_note, null, v_review_id
    );
  end loop;

  perform public.log_audit_event(
    v_company_id,
    'google_review_spiff',
    v_review_id,
    'GOOGLE_REVIEW_LOGGED',
    null,
    jsonb_build_object(
      'journey_id', p_journey_id,
      'review_date', p_review_date,
      'amount_cents', p_amount_cents
    ),
    null,
    p_note,
    p_journey_id
  );

  return v_review_id;
end;
$$;

revoke execute on function public.log_google_review(uuid, date, integer, text)
  from public, anon;
grant execute on function public.log_google_review(uuid, date, integer, text)
  to authenticated;

-- ============================================================================
-- 4. Settings RPCs. get_spiff_settings is readable by any active
--    employee so the client can hide menus; set_spiff_settings needs
--    commission.manage or commission.spiffs_manage and audits the
--    before and after.
-- ============================================================================

create or replace function public.get_spiff_settings()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  if v_company_id is null then
    return null;
  end if;

  -- Only the caller's own company is ever resolved; there is no
  -- company parameter, so no path can read another company's flags.
  return (
    select jsonb_build_object(
             'spiffs_enabled', c.spiffs_enabled,
             'google_reviews_enabled', c.google_reviews_enabled
           )
    from public.companies c
    where c.id = v_company_id
  );
end;
$$;

revoke execute on function public.get_spiff_settings()
  from public, anon;
grant execute on function public.get_spiff_settings()
  to authenticated;

create or replace function public.set_spiff_settings(
  p_spiffs_enabled boolean,
  p_google_reviews_enabled boolean
)
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

  select jsonb_build_object(
           'spiffs_enabled', c.spiffs_enabled,
           'google_reviews_enabled', c.google_reviews_enabled
         )
    into v_before
  from public.companies c
  where c.id = v_company_id;

  -- Warn, never block: store exactly what was sent.
  update public.companies c
  set spiffs_enabled = coalesce(p_spiffs_enabled, false),
      google_reviews_enabled = coalesce(p_google_reviews_enabled, false)
  where c.id = v_company_id;

  v_after := jsonb_build_object(
    'spiffs_enabled', coalesce(p_spiffs_enabled, false),
    'google_reviews_enabled', coalesce(p_google_reviews_enabled, false)
  );

  perform public.log_audit_event(
    v_company_id,
    'companies',
    v_company_id,
    'SPIFF_SETTINGS_SET',
    v_before,
    v_after
  );
end;
$$;

revoke execute on function public.set_spiff_settings(boolean, boolean)
  from public, anon;
grant execute on function public.set_spiff_settings(boolean, boolean)
  to authenticated;
