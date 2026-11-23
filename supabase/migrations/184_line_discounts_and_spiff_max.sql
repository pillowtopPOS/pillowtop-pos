-- 184_line_discounts_and_spiff_max.sql
--
-- Two pieces:
--   1. journey_line_items.list_price_snapshot: the product's REGULAR
--      price (products.price) captured exactly like unit_cost_snapshot
--      -- filled on insert when null, refreshed on product change only
--      while the journey has never had a payment. Old rows stay null;
--      null means unknown and never blocks anything.
--   2. spiff_rules.max_discount_type / max_discount_value: an optional
--      cap on the per-unit discount a line may carry before the rule
--      stops paying on it. The discount is measured from the list
--      snapshot, so a loaded commission cost can never blur the number.
--      A skipped rule is audited once per line and rule and never
--      affects other rules on the same line.

-- ----------------------------------------------------------------------------
-- 1. Column and snapshot trigger.
-- ----------------------------------------------------------------------------

alter table public.journey_line_items
  add column if not exists list_price_snapshot numeric;

comment on column public.journey_line_items.list_price_snapshot is
  'products.price captured when the line was added. Null for lines with no product, pre-184 lines, and lines the app wrote a snapshot into itself.';

create or replace function public.journey_line_item_cost_snapshot()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_product_cost            numeric;
  v_product_commission_cost numeric;
  v_product_price           numeric;
  v_has_payment             boolean;
begin
  if tg_op = 'INSERT' then
    if new.product_id is null then
      return new;
    end if;
    if new.unit_cost_snapshot is not null
       and new.unit_commission_cost_snapshot is not null
       and new.list_price_snapshot is not null then
      return new;
    end if;
    select p.cost, p.commission_cost, p.price
      into v_product_cost, v_product_commission_cost, v_product_price
    from public.products p
    where p.id = new.product_id;
    if not found then
      return new;
    end if;
    if new.unit_cost_snapshot is null then
      new.unit_cost_snapshot := v_product_cost;
    end if;
    if new.unit_commission_cost_snapshot is null then
      new.unit_commission_cost_snapshot :=
        coalesce(v_product_commission_cost, v_product_cost);
    end if;
    if new.list_price_snapshot is null then
      new.list_price_snapshot := v_product_price;
    end if;
    return new;
  end if;

  -- UPDATE OF product_id: refresh only when the product actually changed
  -- and the journey has never had a payment (no paid balance and no
  -- payment event on record). Once money moved the snapshots are part of
  -- the sale record.
  if new.product_id is not distinct from old.product_id then
    return new;
  end if;
  if new.product_id is null then
    -- Product link cleared: keep whatever snapshot exists as history.
    return new;
  end if;

  select exists (
    select 1
    from public.journey_events e
    where e.journey_id = new.journey_id
      and e.event_type in ('deposit_received', 'payment_completed')
  ) or coalesce(public.total_paid(new.journey_id), 0) > 0
    into v_has_payment;
  if v_has_payment then
    return new;
  end if;

  select p.cost, p.commission_cost, p.price
    into v_product_cost, v_product_commission_cost, v_product_price
  from public.products p
  where p.id = new.product_id;
  if not found then
    return new;
  end if;

  new.unit_cost_snapshot := v_product_cost;
  new.unit_commission_cost_snapshot :=
    coalesce(v_product_commission_cost, v_product_cost);
  new.list_price_snapshot := v_product_price;
  return new;
end;
$$;

revoke execute on function public.journey_line_item_cost_snapshot()
  from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 2. spiff_rules max discount columns.
-- ----------------------------------------------------------------------------

alter table public.spiff_rules
  add column if not exists max_discount_type text,
  add column if not exists max_discount_value numeric;

comment on column public.spiff_rules.max_discount_type is
  'DOLLAR: dollars of discount per unit allowed; PERCENT: percent off the regular price allowed. Null means no limit.';
comment on column public.spiff_rules.max_discount_value is
  'The limit amount: dollars per unit for DOLLAR, 0 to 100 percent for PERCENT. Must be set together with max_discount_type.';

alter table public.spiff_rules
  drop constraint if exists spiff_rules_max_discount_type_check;
alter table public.spiff_rules
  add constraint spiff_rules_max_discount_type_check
  check (max_discount_type is null
         or max_discount_type in ('DOLLAR', 'PERCENT'));

alter table public.spiff_rules
  drop constraint if exists spiff_rules_max_discount_value_check;
alter table public.spiff_rules
  add constraint spiff_rules_max_discount_value_check
  check (max_discount_value is null or max_discount_value >= 0);

alter table public.spiff_rules
  drop constraint if exists spiff_rules_max_discount_pair_check;
alter table public.spiff_rules
  add constraint spiff_rules_max_discount_pair_check
  check ((max_discount_type is null) = (max_discount_value is null));

-- ----------------------------------------------------------------------------
-- 3. list_spiff_rules: return type changes, so drop first.
-- ----------------------------------------------------------------------------

drop function if exists public.list_spiff_rules();

create or replace function public.list_spiff_rules()
returns table(
  id uuid,
  name text,
  scope text,
  product_id uuid,
  product_name text,
  scope_value text,
  amount_cents integer,
  starts_on date,
  ends_on date,
  is_active boolean,
  created_at timestamptz,
  updated_at timestamptz,
  max_discount_type text,
  max_discount_value numeric
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
begin
  if not public.has_permission('commission.spiffs_manage') then
    raise exception 'You do not have permission to manage spiff rules';
  end if;

  select s.company_id into v_company_id
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid()
    and e.is_active;

  return query
    select r.id, r.name, r.scope, r.product_id, p.item_name,
           r.scope_value, r.amount_cents, r.starts_on, r.ends_on,
           r.is_active, r.created_at, r.updated_at,
           r.max_discount_type, r.max_discount_value
    from public.spiff_rules r
    left join public.products p on p.id = r.product_id
    where r.company_id = v_company_id
    order by r.is_active desc, r.name;
end;
$$;

revoke execute on function public.list_spiff_rules()
  from public, anon;
grant execute on function public.list_spiff_rules()
  to authenticated;

-- ----------------------------------------------------------------------------
-- 4. save_spiff_rule: two trailing optional parameters so every existing
--    caller keeps working. The 9-argument overload is dropped so there
--    is exactly one signature.
-- ----------------------------------------------------------------------------

drop function if exists public.save_spiff_rule(uuid, text, text, uuid, text, integer, date, date, boolean);

create or replace function public.save_spiff_rule(
  p_id uuid default null,
  p_name text default null,
  p_scope text default null,
  p_product_id uuid default null,
  p_scope_value text default null,
  p_amount_cents integer default null,
  p_starts_on date default null,
  p_ends_on date default null,
  p_is_active boolean default true,
  p_max_discount_type text default null,
  p_max_discount_value numeric default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_caller_employee_id uuid;
  v_existing public.spiff_rules%rowtype;
  v_rule_id uuid;
  v_product_id uuid;
  v_scope_value text;
  v_is_active boolean;
begin
  if not public.has_permission('commission.spiffs_manage') then
    raise exception 'You do not have permission to manage spiff rules';
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

  if nullif(btrim(p_name), '') is null then
    raise exception 'name is required';
  end if;

  if p_scope is null or p_scope not in ('PRODUCT', 'BRAND', 'CATEGORY') then
    raise exception 'scope must be PRODUCT, BRAND or CATEGORY';
  end if;

  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'amount_cents must be greater than 0';
  end if;

  if p_starts_on is not null and p_ends_on is not null
     and p_ends_on < p_starts_on then
    raise exception 'ends_on cannot be before starts_on';
  end if;

  if (p_max_discount_type is null) <> (p_max_discount_value is null) then
    raise exception 'Maximum discount needs both a type and a value.';
  end if;
  if p_max_discount_type is not null
     and p_max_discount_type not in ('DOLLAR', 'PERCENT') then
    raise exception 'max_discount_type must be DOLLAR or PERCENT';
  end if;
  if p_max_discount_value is not null and p_max_discount_value < 0 then
    raise exception 'max_discount_value cannot be negative';
  end if;
  if p_max_discount_type = 'PERCENT' and p_max_discount_value > 100 then
    raise exception 'Percent off cannot be above 100';
  end if;

  -- Normalize: PRODUCT keeps only product_id, the other scopes keep
  -- only scope_value, so the table check and the matcher see the same
  -- shape no matter what the caller sent.
  if p_scope = 'PRODUCT' then
    if p_product_id is null then
      raise exception 'product_id is required for PRODUCT scope';
    end if;
    select p.id into v_product_id
    from public.products p
    where p.id = p_product_id
      and p.company_id = v_company_id;
    if v_product_id is null then
      raise exception 'Product does not belong to your company';
    end if;
    v_scope_value := null;
  else
    v_scope_value := nullif(btrim(p_scope_value), '');
    if v_scope_value is null then
      raise exception 'scope_value is required for % scope', p_scope;
    end if;
    v_product_id := null;
  end if;

  if p_id is null then
    insert into public.spiff_rules (
      company_id, name, scope, product_id, scope_value, amount_cents,
      starts_on, ends_on, is_active, created_by,
      max_discount_type, max_discount_value
    ) values (
      v_company_id, btrim(p_name), p_scope, v_product_id, v_scope_value,
      p_amount_cents, p_starts_on, p_ends_on,
      coalesce(p_is_active, true), v_caller_employee_id,
      p_max_discount_type, p_max_discount_value
    )
    returning id into v_rule_id;

    perform public.log_audit_event(
      v_company_id,
      'spiff_rule',
      v_rule_id,
      'SPIFF_RULE_SAVED',
      null,
      (select to_jsonb(r) from public.spiff_rules r where r.id = v_rule_id)
    );
  else
    select * into v_existing
    from public.spiff_rules r
    where r.id = p_id
      and r.company_id = v_company_id;

    if v_existing.id is null then
      raise exception 'Spiff rule not found';
    end if;

    v_is_active := coalesce(p_is_active, v_existing.is_active);

    update public.spiff_rules r
    set name = btrim(p_name),
        scope = p_scope,
        product_id = v_product_id,
        scope_value = v_scope_value,
        amount_cents = p_amount_cents,
        starts_on = p_starts_on,
        ends_on = p_ends_on,
        is_active = v_is_active,
        updated_at = now(),
        max_discount_type = p_max_discount_type,
        max_discount_value = p_max_discount_value
    where r.id = p_id;

    perform public.log_audit_event(
      v_company_id,
      'spiff_rule',
      p_id,
      'SPIFF_RULE_SAVED',
      to_jsonb(v_existing),
      (select to_jsonb(r) from public.spiff_rules r where r.id = p_id)
    );

    v_rule_id := p_id;
  end if;

  return v_rule_id;
end;
$$;

revoke execute on function public.save_spiff_rule(uuid, text, text, uuid, text, integer, date, date, boolean, text, numeric)
  from public, anon;
grant execute on function public.save_spiff_rule(uuid, text, text, uuid, text, integer, date, date, boolean, text, numeric)
  to authenticated;

-- ----------------------------------------------------------------------------
-- 5. spiff_earn_for_sale: identical to the 180 version plus the max
--    discount skip. Only the rule-select gains the two columns, the
--    line-select gains unit_price and list_price_snapshot, and the skip
--    block sits between the rule match and the credit-share loop.
-- ----------------------------------------------------------------------------

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
  v_discount numeric;
  v_skip boolean;
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
           li.unit_price, li.list_price_snapshot,
           p.brand, pc.name as category_name
    from public.journey_line_items li
    join public.products p on p.id = li.product_id
    left join public.product_categories pc on pc.id = p.category_id
    where li.journey_id = p_journey_id
      and li.product_id is not null
      and li.quantity > 0
  loop
    for v_rule in
      select r.id, r.amount_cents,
             r.max_discount_type, r.max_discount_value
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
      -- Optional per-rule cap: the per-unit discount is the list
      -- snapshot minus the sold unit price, floored at zero, and only
      -- measured when the snapshot exists. DOLLAR compares dollars;
      -- PERCENT compares discount * 100 > limit * snapshot so no
      -- rounding ever shifts the boundary. A skipped rule only misses
      -- this line; other rules and other lines are untouched.
      v_skip := false;
      v_discount := null;
      if v_rule.max_discount_value is not null
         and v_line.list_price_snapshot is not null then
        v_discount := greatest(
          v_line.list_price_snapshot - v_line.unit_price, 0);
        v_skip :=
          (v_rule.max_discount_type = 'DOLLAR'
           and v_discount > v_rule.max_discount_value)
          or
          (v_rule.max_discount_type = 'PERCENT'
           and v_discount * 100
               > v_rule.max_discount_value * v_line.list_price_snapshot);
      end if;

      if v_skip then
        -- One audit row per line and rule: repeated payment events on
        -- the same journey re-run this function and must not spam.
        if not exists (
          select 1 from public.audit_events a
          where a.company_id = v_j.company_id
            and a.event_type = 'SPIFF_SKIPPED_DISCOUNT'
            and a.journey_id = p_journey_id
            and a.entity_id = v_rule.id
            and a.after ->> 'line_item_id' = v_line.line_item_id::text
        ) then
          perform public.log_audit_event(
            v_j.company_id,
            'spiff_rule',
            v_rule.id,
            'SPIFF_SKIPPED_DISCOUNT',
            null,
            jsonb_build_object(
              'journey_id', p_journey_id,
              'line_item_id', v_line.line_item_id,
              'spiff_rule_id', v_rule.id,
              'unit_price', v_line.unit_price,
              'list_price_snapshot', v_line.list_price_snapshot,
              'discount_per_unit', v_discount,
              'max_discount_type', v_rule.max_discount_type,
              'max_discount_value', v_rule.max_discount_value
            ),
            null,
            null,
            p_journey_id,
            'SYSTEM'
          );
        end if;
        continue;
      end if;

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
