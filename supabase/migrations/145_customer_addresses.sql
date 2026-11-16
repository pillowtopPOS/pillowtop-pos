-- Migration 145: Saved customer addresses and a per-order ship-to (slice 2b)
--
-- A customer keeps one PRIMARY address (customers.street_address etc., still
-- required for delivery orders, so every existing delivery check stays valid)
-- and may have any number of SAVED addresses. An order may ship to a saved
-- address (sleep_journeys.ship_to_address_id); null means the primary.
-- Changing an order's ship-to never rewrites the customer's other orders.
--   * customer_addresses: one row per saved address (archive, never delete).
--   * RPCs: add_customer_address, update_customer_address,
--     archive_customer_address, set_journey_ship_to; get_customer now returns
--     the saved addresses with how many open orders use each.
--   * journey_ship_to_log: append-only history of ship-to changes.
--   * Display readers switched to the effective address:
--     get_delivery_day_plan, get_delivery_confirmation_list.
--   * merge_customers moves saved addresses, and keeps the removed customer's
--     own orders shipping to the address they used before the merge.
--   * An exchange's replacement order starts with the original's ship-to.
-- Idempotent: safe to run twice.

-- ---------------------------------------------------------------------------
-- 1. customer_addresses
-- ---------------------------------------------------------------------------

create table if not exists public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  customer_id uuid not null references public.customers(id) on delete cascade,
  label text,
  street_address text not null check (btrim(street_address) <> ''),
  street_address_line_2 text,
  city text,
  state text,
  zip_code text,
  archived_at timestamptz,
  created_by_employee_id uuid references public.employees(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists customer_addresses_customer_idx
  on public.customer_addresses (customer_id);

alter table public.customer_addresses enable row level security;

drop policy if exists "Customer addresses viewable within company" on public.customer_addresses;
create policy "Customer addresses viewable within company"
  on public.customer_addresses for select to authenticated
  using (company_id = public.current_employee_company_id());

revoke all on public.customer_addresses from anon;
revoke insert, update, delete on public.customer_addresses from authenticated;

create or replace function public.customer_addresses_touch()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists trg_customer_addresses_touch on public.customer_addresses;
create trigger trg_customer_addresses_touch
  before update on public.customer_addresses
  for each row execute function public.customer_addresses_touch();

-- ---------------------------------------------------------------------------
-- 2. sleep_journeys.ship_to_address_id and its guards
-- ---------------------------------------------------------------------------

alter table public.sleep_journeys
  add column if not exists ship_to_address_id uuid
  references public.customer_addresses(id);

create index if not exists sleep_journeys_ship_to_idx
  on public.sleep_journeys (ship_to_address_id)
  where ship_to_address_id is not null;

create or replace function public.validate_journey_ship_to()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.ship_to_address_id is null then
    return new;
  end if;
  if tg_op = 'UPDATE'
     and new.ship_to_address_id is not distinct from old.ship_to_address_id
     and new.customer_id is not distinct from old.customer_id then
    return new;
  end if;
  if not exists (
    select 1 from public.customer_addresses a
    where a.id = new.ship_to_address_id
      and a.customer_id = new.customer_id
  ) then
    raise exception 'That address does not belong to this order''s customer';
  end if;
  return new;
end;
$$;

revoke execute on function public.validate_journey_ship_to() from public, anon, authenticated;

drop trigger if exists trg_validate_journey_ship_to on public.sleep_journeys;
create trigger trg_validate_journey_ship_to
  before insert or update of ship_to_address_id, customer_id on public.sleep_journeys
  for each row execute function public.validate_journey_ship_to();

-- An exchange's replacement order starts with the original order's ship-to.
create or replace function public.copy_parent_ship_to()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.ship_to_address_id is null and new.parent_journey_id is not null then
    select p.ship_to_address_id into new.ship_to_address_id
    from public.sleep_journeys p
    where p.id = new.parent_journey_id
      and p.customer_id = new.customer_id;
  end if;
  return new;
end;
$$;

revoke execute on function public.copy_parent_ship_to() from public, anon, authenticated;

drop trigger if exists trg_copy_parent_ship_to on public.sleep_journeys;
create trigger trg_copy_parent_ship_to
  before insert on public.sleep_journeys
  for each row execute function public.copy_parent_ship_to();

-- ---------------------------------------------------------------------------
-- 3. Ship-to change history (append-only)
-- ---------------------------------------------------------------------------

create table if not exists public.journey_ship_to_log (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  journey_id uuid not null references public.sleep_journeys(id) on delete cascade,
  old_address_id uuid,
  new_address_id uuid,
  changed_by_employee_id uuid,
  changed_at timestamptz not null default now()
);

alter table public.journey_ship_to_log enable row level security;

drop policy if exists "Ship-to log viewable within company" on public.journey_ship_to_log;
create policy "Ship-to log viewable within company"
  on public.journey_ship_to_log for select to authenticated
  using (company_id = public.current_employee_company_id());

revoke all on public.journey_ship_to_log from anon;
revoke insert, update, delete on public.journey_ship_to_log from authenticated;

-- ---------------------------------------------------------------------------
-- 4. RPCs
-- ---------------------------------------------------------------------------

create or replace function public.add_customer_address(
  p_customer_id uuid,
  p_label text,
  p_street_address text,
  p_street_address_line_2 text,
  p_city text,
  p_state text,
  p_zip_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company uuid := public.current_employee_company_id();
  v_emp uuid;
  v_street text := nullif(btrim(coalesce(p_street_address, '')), '');
  v_zip text := nullif(btrim(coalesce(p_zip_code, '')), '');
  v_row public.customer_addresses%rowtype;
begin
  if v_company is null then
    raise exception 'No company for this user';
  end if;
  if v_street is null then
    raise exception 'Street address is required';
  end if;
  if not exists (
    select 1 from public.customers c
    where c.id = p_customer_id and c.company_id = v_company
  ) then
    raise exception 'Customer not found';
  end if;
  if (select count(*) from public.customer_addresses
      where customer_id = p_customer_id and archived_at is null) >= 25 then
    raise exception 'This customer already has 25 saved addresses';
  end if;

  -- Same street and zip already saved: return it instead of a duplicate.
  select * into v_row from public.customer_addresses a
  where a.customer_id = p_customer_id
    and a.archived_at is null
    and lower(btrim(a.street_address)) = lower(v_street)
    and coalesce(btrim(a.zip_code), '') = coalesce(v_zip, '')
  limit 1;
  if found then
    return to_jsonb(v_row);
  end if;

  select e.id into v_emp from public.employees e where e.auth_user_id = auth.uid() limit 1;

  insert into public.customer_addresses (
    company_id, customer_id, label, street_address, street_address_line_2,
    city, state, zip_code, created_by_employee_id
  ) values (
    v_company, p_customer_id,
    nullif(btrim(coalesce(p_label, '')), ''),
    v_street,
    nullif(btrim(coalesce(p_street_address_line_2, '')), ''),
    nullif(btrim(coalesce(p_city, '')), ''),
    nullif(btrim(coalesce(p_state, '')), ''),
    v_zip, v_emp
  ) returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

revoke execute on function public.add_customer_address(uuid, text, text, text, text, text, text) from public, anon;
grant execute on function public.add_customer_address(uuid, text, text, text, text, text, text) to authenticated;

create or replace function public.update_customer_address(p_address_id uuid, p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company uuid := public.current_employee_company_id();
  v_row public.customer_addresses%rowtype;
begin
  if v_company is null then
    raise exception 'No company for this user';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'Nothing to update';
  end if;

  select * into v_row from public.customer_addresses
  where id = p_address_id and company_id = v_company
  for update;
  if not found then
    raise exception 'Address not found';
  end if;
  if v_row.archived_at is not null then
    raise exception 'This address is archived';
  end if;

  if p_patch ? 'label' then
    v_row.label := nullif(btrim(coalesce(p_patch ->> 'label', '')), '');
  end if;
  if p_patch ? 'street_address' then
    v_row.street_address := btrim(coalesce(p_patch ->> 'street_address', ''));
  end if;
  if p_patch ? 'street_address_line_2' then
    v_row.street_address_line_2 := nullif(btrim(coalesce(p_patch ->> 'street_address_line_2', '')), '');
  end if;
  if p_patch ? 'city' then
    v_row.city := nullif(btrim(coalesce(p_patch ->> 'city', '')), '');
  end if;
  if p_patch ? 'state' then
    v_row.state := nullif(btrim(coalesce(p_patch ->> 'state', '')), '');
  end if;
  if p_patch ? 'zip_code' then
    v_row.zip_code := nullif(btrim(coalesce(p_patch ->> 'zip_code', '')), '');
  end if;
  if v_row.street_address = '' then
    raise exception 'Street address is required';
  end if;

  update public.customer_addresses set
    label = v_row.label,
    street_address = v_row.street_address,
    street_address_line_2 = v_row.street_address_line_2,
    city = v_row.city,
    state = v_row.state,
    zip_code = v_row.zip_code
  where id = p_address_id
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

revoke execute on function public.update_customer_address(uuid, jsonb) from public, anon;
grant execute on function public.update_customer_address(uuid, jsonb) to authenticated;

create or replace function public.archive_customer_address(p_address_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company uuid := public.current_employee_company_id();
  v_row public.customer_addresses%rowtype;
  v_open integer;
begin
  if v_company is null then
    raise exception 'No company for this user';
  end if;

  select * into v_row from public.customer_addresses
  where id = p_address_id and company_id = v_company
  for update;
  if not found then
    raise exception 'Address not found';
  end if;

  select count(*) into v_open
  from public.sleep_journeys sj
  where sj.ship_to_address_id = p_address_id
    and sj.cancelled_at is null
    and sj.delivered_at is null;
  if v_open > 0 then
    raise exception '% open order% ship to this address. Change % first.',
      v_open, case when v_open = 1 then '' else 's' end,
      case when v_open = 1 then 'it' else 'them' end;
  end if;

  update public.customer_addresses
  set archived_at = coalesce(archived_at, now())
  where id = p_address_id
  returning * into v_row;

  return to_jsonb(v_row);
end;
$$;

revoke execute on function public.archive_customer_address(uuid) from public, anon;
grant execute on function public.archive_customer_address(uuid) to authenticated;

create or replace function public.set_journey_ship_to(p_journey_id uuid, p_address_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company uuid := public.current_employee_company_id();
  v_j public.sleep_journeys%rowtype;
  v_emp uuid;
begin
  if v_company is null then
    raise exception 'No company for this user';
  end if;

  select sj.* into v_j
  from public.sleep_journeys sj
  join public.stores st on st.id = sj.store_id
  where sj.id = p_journey_id and st.company_id = v_company
  for update of sj;
  if not found or not public.is_journey_visible(p_journey_id) then
    raise exception 'Order not found';
  end if;
  if v_j.cancelled_at is not null then
    raise exception 'This order is cancelled';
  end if;
  if v_j.delivered_at is not null then
    raise exception 'This order is already delivered';
  end if;

  if p_address_id is not null and not exists (
    select 1 from public.customer_addresses a
    where a.id = p_address_id
      and a.customer_id = v_j.customer_id
      and a.company_id = v_company
      and a.archived_at is null
  ) then
    raise exception 'That address is not available for this customer';
  end if;

  if v_j.ship_to_address_id is not distinct from p_address_id then
    return jsonb_build_object('journey_id', p_journey_id, 'ship_to_address_id', p_address_id, 'changed', false);
  end if;

  select e.id into v_emp from public.employees e where e.auth_user_id = auth.uid() limit 1;

  update public.sleep_journeys set ship_to_address_id = p_address_id where id = p_journey_id;

  insert into public.journey_ship_to_log (
    company_id, journey_id, old_address_id, new_address_id, changed_by_employee_id
  ) values (
    v_company, p_journey_id, v_j.ship_to_address_id, p_address_id, v_emp
  );

  return jsonb_build_object('journey_id', p_journey_id, 'ship_to_address_id', p_address_id, 'changed', true);
end;
$$;

revoke execute on function public.set_journey_ship_to(uuid, uuid) from public, anon;
grant execute on function public.set_journey_ship_to(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. get_customer: add the saved addresses (and how many open orders use each)
-- ---------------------------------------------------------------------------

create or replace function public.get_customer(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company uuid := public.current_employee_company_id();
  v_row public.customers%rowtype;
begin
  if v_company is null then
    raise exception 'No company for this user';
  end if;

  select * into v_row from public.customers
  where id = p_id and company_id = v_company;
  if not found then
    raise exception 'Customer not found';
  end if;

  return jsonb_build_object(
    'id', v_row.id,
    'first_name', v_row.first_name,
    'last_name', v_row.last_name,
    'is_company', v_row.is_company,
    'company_name', v_row.company_name,
    'phone', v_row.phone,
    'phone2', v_row.phone2,
    'email', v_row.email,
    'street_address', v_row.street_address,
    'street_address_line_2', v_row.street_address_line_2,
    'city', v_row.city,
    'state', v_row.state,
    'zip_code', v_row.zip_code,
    'referral_source', v_row.referral_source,
    'customer_since', v_row.customer_since,
    'created_at', v_row.created_at,
    'updated_at', v_row.updated_at,
    'primary_open_orders', (
      select count(*) from public.sleep_journeys sj
      where sj.customer_id = v_row.id and sj.ship_to_address_id is null
        and sj.cancelled_at is null and sj.delivered_at is null),
    'addresses', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', a.id,
        'label', a.label,
        'street_address', a.street_address,
        'street_address_line_2', a.street_address_line_2,
        'city', a.city,
        'state', a.state,
        'zip_code', a.zip_code,
        'open_orders', (
          select count(*) from public.sleep_journeys sj
          where sj.ship_to_address_id = a.id
            and sj.cancelled_at is null and sj.delivered_at is null)
      ) order by a.created_at)
      from public.customer_addresses a
      where a.customer_id = v_row.id and a.archived_at is null
    ), '[]'::jsonb),
    'journeys', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', sj.id,
        'journey_number', sj.journey_number,
        'current_state', sj.current_state,
        'store_id', sj.store_id,
        'store_name', st.name,
        'ship_to_address_id', sj.ship_to_address_id,
        'created_at', sj.created_at
      ) order by sj.created_at desc)
      from (
        select * from public.sleep_journeys
        where customer_id = v_row.id
        order by created_at desc
        limit 50
      ) sj
      left join public.stores st on st.id = sj.store_id
    ), '[]'::jsonb),
    'journey_count', (select count(*) from public.sleep_journeys where customer_id = v_row.id)
  );
end;
$$;

revoke execute on function public.get_customer(uuid) from public, anon;
grant execute on function public.get_customer(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. Delivery readers show the effective address
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_delivery_day_plan(p_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_company_id uuid;
  v_plan record;
  v_trucks jsonb;
  v_stops jsonb;
  v_released jsonb;
  v_capacity integer;
  v_booked integer;
begin
  v_company_id := public.delivery_caller_company();
  if v_company_id is null then
    raise exception 'Only active employees can view the delivery calendar.';
  end if;
  if p_date is null then
    raise exception 'Pick a delivery day.';
  end if;

  select * into v_plan
  from public.delivery_day_plans
  where company_id = v_company_id and date = p_date;

  -- Trucks ON this date, plus any OFF truck that still has BOOKED stops
  -- assigned (flagged so the screen can warn).
  with candidate_trucks as (
    select t.id, t.name, t.default_stop_cap, t.sort_order,
           ds.is_on, ds.source
    from public.delivery_trucks t
    cross join lateral public.delivery_truck_day_state(t, p_date) ds
    where t.company_id = v_company_id and t.archived_at is null
  ),
  assigned as (
    select distinct ds.truck_id
    from public.delivery_stops ds
    where ds.company_id = v_company_id
      and ds.delivery_date = p_date
      and ds.status = 'BOOKED'
      and ds.truck_id is not null
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'truck_id', ct.id,
      'name', ct.name,
      'stop_cap', case when ct.is_on then ct.default_stop_cap else 0 end,
      'on', ct.is_on,
      'assigned_off', (not ct.is_on)
        and exists (select 1 from assigned a where a.truck_id = ct.id)
    ) order by ct.sort_order, ct.name), '[]'::jsonb)
  into v_trucks
  from candidate_trucks ct
  where ct.is_on
     or exists (select 1 from assigned a where a.truck_id = ct.id);

  select coalesce(jsonb_agg(jsonb_build_object(
      'stop_id', ds.id,
      'journey_id', ds.journey_id,
      'journey_number', sj.journey_number,
      'customer_name', trim(concat_ws(' ', cu.first_name, cu.last_name)),
      'phone', cu.phone,
      'street_address', (case when ca.id is not null then ca.street_address else cu.street_address end),
      'street_address_line_2', (case when ca.id is not null then ca.street_address_line_2 else cu.street_address_line_2 end),
      'city', (case when ca.id is not null then ca.city else cu.city end),
      'state', (case when ca.id is not null then ca.state else cu.state end),
      'zip_code', (case when ca.id is not null then ca.zip_code else cu.zip_code end),
      'delivery_address', trim(concat_ws(', ',
          nullif(trim(concat_ws(' ', (case when ca.id is not null then ca.street_address else cu.street_address end), (case when ca.id is not null then ca.street_address_line_2 else cu.street_address_line_2 end))), ''),
          nullif(trim(concat_ws(' ', (case when ca.id is not null then ca.city else cu.city end), (case when ca.id is not null then ca.state else cu.state end), (case when ca.id is not null then ca.zip_code else cu.zip_code end))), ''))),
      'truck_id', ds.truck_id,
      'route_position', ds.route_position,
      'booked_by', ds.booked_by,
      'booked_by_name', eb.name,
      'booked_at', ds.created_at,
      'inside_cutoff', ds.inside_cutoff,
      'window_start', ds.window_start,
      'window_end', ds.window_end
    ) order by ds.truck_id nulls last, ds.route_position nulls last, ds.created_at), '[]'::jsonb)
  into v_stops
  from public.delivery_stops ds
  join public.sleep_journeys sj on sj.id = ds.journey_id
  left join public.customers cu on cu.id = sj.customer_id
  left join public.customer_addresses ca on ca.id = sj.ship_to_address_id
  left join public.employees eb on eb.id = ds.booked_by
  where ds.company_id = v_company_id
    and ds.delivery_date = p_date
    and ds.status = 'BOOKED';

  -- Stops released AFTER the day was last reviewed/closed. CANCELLED
  -- rows keep cancelled_at; SUPERSEDED rows (rescheduled away) only get
  -- updated_at, so coalesce covers both. reason_kind tells the screen
  -- whether the stop died ('cancelled') or moved to another day
  -- ('moved', with moved_to_date of the journey's live BOOKED stop).
  select coalesce(jsonb_agg(jsonb_build_object(
      'stop_id', ds.id,
      'journey_id', ds.journey_id,
      'journey_number', sj.journey_number,
      'customer_name', trim(concat_ws(' ', cu.first_name, cu.last_name)),
      'truck_id', ds.truck_id,
      'reason_kind', case when ds.status = 'CANCELLED' then 'cancelled' else 'moved' end,
      'moved_to_date', case when ds.status = 'SUPERSEDED' then (
        select ds2.delivery_date
        from public.delivery_stops ds2
        where ds2.journey_id = ds.journey_id and ds2.status = 'BOOKED'
        order by ds2.delivery_date
        limit 1
      ) end,
      'cancel_reason', ds.cancel_reason,
      'cancelled_at', coalesce(ds.cancelled_at, ds.updated_at)
    ) order by coalesce(ds.cancelled_at, ds.updated_at) desc), '[]'::jsonb)
  into v_released
  from public.delivery_stops ds
  join public.sleep_journeys sj on sj.id = ds.journey_id
  left join public.customers cu on cu.id = sj.customer_id
  where ds.company_id = v_company_id
    and ds.delivery_date = p_date
    and ds.status in ('CANCELLED', 'SUPERSEDED')
    and ds.truck_id is not null
    and coalesce(ds.cancelled_at, ds.updated_at)
        > coalesce(v_plan.reviewed_at, v_plan.closed_at, '-infinity'::timestamptz);

  v_capacity := public.delivery_day_capacity(v_company_id, p_date);
  select count(*) into v_booked
  from public.delivery_stops ds
  where ds.company_id = v_company_id
    and ds.delivery_date = p_date
    and ds.status in ('BOOKED', 'COMPLETED');

  return jsonb_build_object(
    'plan', case when v_plan.company_id is null then jsonb_build_object(
        'status', 'OPEN', 'version', 0, 'closed_at', null,
        'closed_by_name', null, 'reviewed_at', null
      ) else jsonb_build_object(
        'status', v_plan.status,
        'version', v_plan.version,
        'closed_at', v_plan.closed_at,
        'closed_by_name', (select e.name from public.employees e where e.id = v_plan.closed_by),
        'reopened_at', v_plan.reopened_at,
        'reviewed_at', v_plan.reviewed_at
      ) end,
    'trucks', v_trucks,
    'stops', v_stops,
    'released_after_review', v_released,
    'capacity', v_capacity,
    'booked_count', v_booked,
    'today_local', public.delivery_company_today()
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_delivery_confirmation_list(p_date date DEFAULT NULL::date, p_scope text DEFAULT 'store'::text, p_store_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_employee_id uuid;
  v_company_id uuid;
  v_store_id uuid;
  v_store_name text;
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
  if p_scope is null or p_scope not in ('store', 'all') then
    raise exception 'Scope must be store or all.';
  end if;

  -- Store resolution: an explicit p_store_id must belong to the
  -- caller's company; otherwise fall back to the home store. There is
  -- no employee-store access table, so the company check is the rule.
  if p_store_id is not null then
    select st.id, st.name
      into v_store_id, v_store_name
    from public.stores st
    where st.id = p_store_id
      and st.company_id = v_company_id;
    if v_store_id is null then
      raise exception 'That store is not in your company.';
    end if;
  else
    select e.home_store_id
      into v_store_id
    from public.employees e
    where e.id = v_employee_id;
    select st.name
      into v_store_name
    from public.stores st
    where st.id = v_store_id;
  end if;

  select c.delivery_day_mode, c.delivery_day_start, c.delivery_day_end
    into v_mode, v_day_start, v_day_end
  from public.companies c where c.id = v_company_id;

  v_tomorrow := public.delivery_company_today() + 1;

  if p_date is null then
    -- Earliest day THIS scope has a booked stop: a store with no
    -- stops on the company's next day must not be shown that day.
    select min(ds.delivery_date) into v_date
    from public.delivery_stops ds
    join public.sleep_journeys sj on sj.id = ds.journey_id
    where ds.company_id = v_company_id
      and ds.status = 'BOOKED'
      and ds.delivery_date >= v_tomorrow
      and (p_scope = 'all' or sj.store_id = v_store_id);
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
    join public.sleep_journeys sj on sj.id = ds.journey_id
    where ds.company_id = v_company_id
      and ds.status = 'BOOKED'
      and ds.delivery_date >= v_tomorrow
      and (p_scope = 'all' or sj.store_id = v_store_id)
    group by ds.delivery_date
    order by ds.delivery_date
    limit 7
  ) d;

  if v_date is null then
    return jsonb_build_object(
      'date', null, 'day_mode', v_mode,
      'day_start', v_day_start, 'day_end', v_day_end,
      'available_dates', v_dates, 'scope', p_scope,
      'store_id', v_store_id, 'store_name', v_store_name,
      'items', '[]'::jsonb);
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
      sj.store_id,
      cu.first_name || ' ' || cu.last_name as customer_name,
      cu.phone as customer_phone,
      cu.email as customer_email,
      nullif(trim(concat_ws(', ',
        nullif(trim(concat_ws(' ', (case when ca.id is not null then ca.street_address else cu.street_address end), (case when ca.id is not null then ca.street_address_line_2 else cu.street_address_line_2 end))), ''),
        nullif(trim(concat_ws(' ', (case when ca.id is not null then ca.city else cu.city end), (case when ca.id is not null then ca.state else cu.state end), (case when ca.id is not null then ca.zip_code else cu.zip_code end))), '')
      )), '') as delivery_address,
      t.name as truck_name,
      t.sort_order as truck_sort_order,
      ae.name as assigned_employee_name
    from public.delivery_stops ds
    join public.sleep_journeys sj on sj.id = ds.journey_id
    join public.stores st on st.id = sj.store_id
    join public.customers cu on cu.id = sj.customer_id
  left join public.customer_addresses ca on ca.id = sj.ship_to_address_id
    left join public.delivery_trucks t on t.id = ds.truck_id
    left join public.employees ae on ae.id = sj.assigned_employee_id
    where ds.company_id = v_company_id
      and ds.delivery_date = v_date
      and ds.status = 'BOOKED'
      and st.company_id = v_company_id
      -- 'store' = the journey's store is the resolved store; the
      -- salesperson no longer decides membership. 'all' = company.
      and (p_scope = 'all' or sj.store_id = v_store_id)
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
    'store_id', v_store_id,
    'store_name', v_store_name,
    'items', v_items);
end;
$function$;

-- ---------------------------------------------------------------------------
-- 7. merge_customers: also moves saved addresses. Orders of the removed
--    customer that shipped to their primary address keep shipping there: it
--    becomes a saved address on the kept customer when it differs from the
--    kept customer's primary.
-- ---------------------------------------------------------------------------

create or replace function public.merge_customers(p_keep uuid, p_remove uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company uuid := public.current_employee_company_id();
  v_emp record;
  v_keep public.customers%rowtype;
  v_rem public.customers%rowtype;
  v_moved integer;
  v_new_addr uuid;
begin
  if v_company is null then
    raise exception 'No company for this user';
  end if;

  select e.id, e.role into v_emp
  from public.employees e
  where e.auth_user_id = auth.uid()
  limit 1;
  if v_emp.id is null or v_emp.role not in ('owner', 'admin', 'manager') then
    raise exception 'Only managers, admins and owners can merge customers';
  end if;

  if p_keep is null or p_remove is null or p_keep = p_remove then
    raise exception 'Pick two different customers to merge';
  end if;

  -- Lock in a fixed order so two merges cannot deadlock.
  perform 1 from public.customers
  where id in (p_keep, p_remove) and company_id = v_company
  order by id for update;

  select * into v_keep from public.customers where id = p_keep and company_id = v_company;
  if not found then raise exception 'Customer not found'; end if;
  select * into v_rem from public.customers where id = p_remove and company_id = v_company;
  if not found then raise exception 'Customer not found'; end if;

  -- Never move another company's orders (only possible with damaged data).
  if exists (
    select 1 from public.sleep_journeys sj
    join public.stores st on st.id = sj.store_id
    where sj.customer_id in (p_keep, p_remove) and st.company_id <> v_company
  ) then
    raise exception 'These customers have orders in another company and cannot be merged';
  end if;

  -- Blanks on the kept customer are filled from the removed one. The kept
  -- customer's own values always win. An address is moved as a whole so the
  -- delivery address rule (036) stays satisfied for moved orders.
  update public.customers k set
    phone2 = coalesce(
      k.phone2,
      case when public.delivery_norm_phone(v_rem.phone) is distinct from public.delivery_norm_phone(k.phone)
        then v_rem.phone end,
      v_rem.phone2),
    referral_source = coalesce(k.referral_source, v_rem.referral_source),
    customer_since = least(k.customer_since, v_rem.customer_since),
    street_address = case when nullif(btrim(coalesce(k.street_address, '')), '') is null
      then v_rem.street_address else k.street_address end,
    street_address_line_2 = case when nullif(btrim(coalesce(k.street_address, '')), '') is null
      then v_rem.street_address_line_2 else k.street_address_line_2 end,
    city = case when nullif(btrim(coalesce(k.street_address, '')), '') is null
      then v_rem.city else k.city end,
    state = case when nullif(btrim(coalesce(k.street_address, '')), '') is null
      then v_rem.state else k.state end,
    zip_code = case when nullif(btrim(coalesce(k.street_address, '')), '') is null
      then v_rem.zip_code else k.zip_code end
  where k.id = p_keep;

  -- Saved addresses of the removed customer move to the kept customer.
  update public.customer_addresses set customer_id = p_keep where customer_id = p_remove;

  -- The removed customer's primary address: if the kept customer's primary is
  -- different (it was not just filled from it), keep it as a saved address so
  -- the removed customer's orders still ship there.
  if nullif(btrim(coalesce(v_rem.street_address, '')), '') is not null
     and nullif(btrim(coalesce(v_keep.street_address, '')), '') is not null
     and (lower(btrim(v_rem.street_address)) <> lower(btrim(v_keep.street_address))
          or coalesce(btrim(v_rem.zip_code), '') <> coalesce(btrim(v_keep.zip_code), '')) then
    select a.id into v_new_addr from public.customer_addresses a
    where a.customer_id = p_keep and a.archived_at is null
      and lower(btrim(a.street_address)) = lower(btrim(v_rem.street_address))
      and coalesce(btrim(a.zip_code), '') = coalesce(btrim(v_rem.zip_code), '')
    limit 1;
    if v_new_addr is null then
      insert into public.customer_addresses (
        company_id, customer_id, label, street_address, street_address_line_2,
        city, state, zip_code, created_by_employee_id
      ) values (
        v_company, p_keep, 'From merged customer', btrim(v_rem.street_address),
        v_rem.street_address_line_2, v_rem.city, v_rem.state, v_rem.zip_code, v_emp.id
      ) returning id into v_new_addr;
    end if;
  end if;

  update public.sleep_journeys
  set customer_id = p_keep,
      ship_to_address_id = coalesce(ship_to_address_id, v_new_addr)
  where customer_id = p_remove;
  get diagnostics v_moved = row_count;
  update public.customer_contacts set customer_id = p_keep where customer_id = p_remove;
  update public.sleep_concerns set customer_id = p_keep where customer_id = p_remove;
  update public.sleep_trial_items set customer_id = p_keep where customer_id = p_remove;
  update public.journey_interactions set customer_id = p_keep where customer_id = p_remove;

  insert into public.customer_merge_log (
    company_id, kept_customer_id, removed_customer_id, removed_snapshot,
    moved_journeys, merged_by_employee_id
  ) values (
    v_company, p_keep, p_remove, to_jsonb(v_rem), v_moved, v_emp.id
  );

  delete from public.customers where id = p_remove;

  return jsonb_build_object('kept_customer_id', p_keep, 'moved_journeys', v_moved);
end;
$$;


revoke execute on function public.merge_customers(uuid, uuid) from public, anon;
grant execute on function public.merge_customers(uuid, uuid) to authenticated;
