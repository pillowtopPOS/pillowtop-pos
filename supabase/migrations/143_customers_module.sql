-- Migration 143: Customers module (slice 2a)
--
-- Adds what the Customers page needs, with no change to any existing
-- screen or SQL function that builds a customer name:
--   * customers.is_company and customers.company_name. For a company
--     customer a trigger mirrors the company name into first_name (and
--     blanks last_name), so every existing name display, label, call list
--     and report shows the company name unchanged. Contact people for a
--     company live in the existing customer_contacts table.
--   * find_matching_customers also matches a company by name.
--   * search_customers, get_customer, update_customer, merge_customers:
--     company-scoped security definer RPCs for the Customers page.
--   * customer_merge_log: append-only record of every merge.
-- Idempotent: safe to run twice.

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------

alter table public.customers
  add column if not exists is_company boolean not null default false,
  add column if not exists company_name text;

comment on column public.customers.company_name is
  'Set only when is_company is true. first_name mirrors it and last_name is blank (trigger) so existing name displays keep working.';

-- ---------------------------------------------------------------------------
-- 2. Company name mirror trigger
-- ---------------------------------------------------------------------------

create or replace function public.customers_apply_company_name()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.is_company then
    new.company_name := nullif(btrim(coalesce(new.company_name, '')), '');
    if new.company_name is null then
      -- Switching an existing person to a company without a name: use the
      -- existing display name so nothing is lost; a brand new row must
      -- supply one.
      if tg_op = 'UPDATE' then
        new.company_name := nullif(btrim(concat_ws(' ', old.first_name, old.last_name)), '');
      end if;
      if new.company_name is null then
        raise exception 'A company needs a company name';
      end if;
    end if;
    new.first_name := new.company_name;
    new.last_name := '';
  else
    new.company_name := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_customers_apply_company_name on public.customers;
create trigger trg_customers_apply_company_name
  before insert or update on public.customers
  for each row execute function public.customers_apply_company_name();

-- ---------------------------------------------------------------------------
-- 3. Merge log (append-only)
-- ---------------------------------------------------------------------------

create table if not exists public.customer_merge_log (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  kept_customer_id uuid not null,
  removed_customer_id uuid not null,
  removed_snapshot jsonb not null,
  moved_journeys integer not null default 0,
  merged_by_employee_id uuid,
  merged_at timestamptz not null default now()
);

alter table public.customer_merge_log enable row level security;

drop policy if exists "Merge log viewable within company" on public.customer_merge_log;
create policy "Merge log viewable within company"
  on public.customer_merge_log for select to authenticated
  using (company_id = public.current_employee_company_id());

revoke insert, update, delete on public.customer_merge_log from authenticated, anon;
revoke all on public.customer_merge_log from anon;

-- ---------------------------------------------------------------------------
-- 4. find_matching_customers: also match a company by name
-- ---------------------------------------------------------------------------

create or replace function public.find_matching_customers(
  p_first text,
  p_last text,
  p_phone text,
  p_email text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company uuid := public.current_employee_company_id();
  v_norm_phone text := public.delivery_norm_phone(p_phone);
  v_email text;
  v_first text := nullif(btrim(coalesce(p_first, '')), '');
  v_last text := nullif(btrim(coalesce(p_last, '')), '');
  v_name_ok boolean;
  v_company_ok boolean;
begin
  if v_company is null then
    raise exception 'No company for this user';
  end if;

  v_email := case
    when position('@' in coalesce(p_email, '')) > 0
      then lower(btrim(p_email))
    else null
  end;

  v_name_ok :=
    length(coalesce(v_first, '')) >= 2
    and length(coalesce(v_last, '')) >= 2;
  -- A company is looked up by its name alone (first field, no last name).
  v_company_ok := length(coalesce(v_first, '')) >= 2 and v_last is null;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', s.id,
        'first_name', s.first_name,
        'last_name', s.last_name,
        'is_company', s.is_company,
        'company_name', s.company_name,
        'phone', s.phone,
        'phone2', s.phone2,
        'email', s.email,
        'street_address', s.street_address,
        'street_address_line_2', s.street_address_line_2,
        'city', s.city,
        'state', s.state,
        'zip_code', s.zip_code,
        'referral_source', s.referral_source,
        'journey_count', s.journey_count,
        'last_order_at', s.last_order_at,
        'reasons', s.reasons
      )
      order by s.rank, s.last_order_at desc nulls last, s.id
    )
    from (
      select
        c.id,
        c.first_name,
        c.last_name,
        c.is_company,
        c.company_name,
        c.phone,
        c.phone2,
        c.email,
        c.street_address,
        c.street_address_line_2,
        c.city,
        c.state,
        c.zip_code,
        c.referral_source,
        (select count(*) from public.sleep_journeys sj
          where sj.customer_id = c.id) as journey_count,
        (select max(sj.created_at) from public.sleep_journeys sj
          where sj.customer_id = c.id) as last_order_at,
        array_remove(array[
          case when m_phone then 'phone' end,
          case when m_email then 'email' end,
          case when m_name then 'name' end
        ], null) as reasons,
        case
          when m_phone and m_email then 0
          when m_phone then 1
          when m_email then 2
          else 3
        end as rank
      from (
        select
          cu.*,
          (v_norm_phone is not null and (
            public.delivery_norm_phone(cu.phone) = v_norm_phone
            or public.delivery_norm_phone(cu.phone2) = v_norm_phone
          )) as m_phone,
          (v_email is not null
            and lower(btrim(cu.email)) = v_email) as m_email,
          (
            (v_name_ok
              and not cu.is_company
              and lower(btrim(cu.first_name)) = lower(v_first)
              and lower(btrim(cu.last_name)) = lower(v_last))
            or
            (v_company_ok
              and cu.is_company
              and lower(btrim(cu.company_name)) = lower(v_first))
          ) as m_name
        from public.customers cu
        where cu.company_id = v_company
      ) c
      where m_phone or m_email or m_name
      order by rank, last_order_at desc nulls last, id
      limit 5
    ) s
  ), '[]'::jsonb);
end;
$$;

revoke execute on function public.find_matching_customers(text, text, text, text)
  from public, anon;
grant execute on function public.find_matching_customers(text, text, text, text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 5. search_customers: Customers page list
-- ---------------------------------------------------------------------------

create or replace function public.search_customers(
  p_query text default null,
  p_limit integer default 25,
  p_offset integer default 0
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_company uuid := public.current_employee_company_id();
  v_q text := nullif(btrim(coalesce(p_query, '')), '');
  v_digits text := regexp_replace(coalesce(p_query, ''), '\D', '', 'g');
  -- Escape LIKE wildcards so a typed % or _ is searched literally.
  v_pat text := '%' || replace(replace(replace(coalesce(btrim(p_query), ''), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 100);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
  v_total integer;
  v_items jsonb;
begin
  if v_company is null then
    raise exception 'No company for this user';
  end if;

  with hits as (
    select c.*
    from public.customers c
    where c.company_id = v_company
      and (
        v_q is null
        or concat_ws(' ', c.first_name, c.last_name) ilike v_pat
        or coalesce(c.company_name, '') ilike v_pat
        or c.email ilike v_pat
        or (length(v_digits) >= 3 and (
          regexp_replace(coalesce(c.phone, ''), '\D', '', 'g') like '%' || v_digits || '%'
          or regexp_replace(coalesce(c.phone2, ''), '\D', '', 'g') like '%' || v_digits || '%'
        ))
        or coalesce(c.street_address, '') ilike v_pat
      )
  ),
  counted as (
    select h.*,
      (select count(*) from public.sleep_journeys sj where sj.customer_id = h.id) as journey_count,
      (select max(sj.created_at) from public.sleep_journeys sj where sj.customer_id = h.id) as last_order_at
    from hits h
  ),
  page as (
    select * from counted
    order by last_order_at desc nulls last, created_at desc, id
    limit v_limit offset v_offset
  )
  select
    (select count(*) from hits),
    coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', p.id,
        'display_name', trim(concat_ws(' ', p.first_name, p.last_name)),
        'first_name', p.first_name,
        'last_name', p.last_name,
        'is_company', p.is_company,
        'company_name', p.company_name,
        'phone', p.phone,
        'phone2', p.phone2,
        'email', p.email,
        'city', p.city,
        'state', p.state,
        'customer_since', p.customer_since,
        'journey_count', p.journey_count,
        'last_order_at', p.last_order_at
      ) order by p.last_order_at desc nulls last, p.created_at desc, p.id)
      from page p
    ), '[]'::jsonb)
  into v_total, v_items;

  return jsonb_build_object('total', v_total, 'items', v_items);
end;
$$;

revoke execute on function public.search_customers(text, integer, integer) from public, anon;
grant execute on function public.search_customers(text, integer, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 6. get_customer: one customer with their orders
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
    'journeys', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', sj.id,
        'journey_number', sj.journey_number,
        'current_state', sj.current_state,
        'store_id', sj.store_id,
        'store_name', st.name,
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
-- 7. update_customer: edit from the Customers page
--    Only keys present in p_patch change. Any employee in the company may
--    edit (tool, not the boss); the database keeps the rules it must.
-- ---------------------------------------------------------------------------

create or replace function public.update_customer(p_id uuid, p_patch jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company uuid := public.current_employee_company_id();
  v_row public.customers%rowtype;
  v_since date;
begin
  if v_company is null then
    raise exception 'No company for this user';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object' then
    raise exception 'Nothing to update';
  end if;

  select * into v_row from public.customers
  where id = p_id and company_id = v_company
  for update;
  if not found then
    raise exception 'Customer not found';
  end if;

  if p_patch ? 'is_company' then
    v_row.is_company := coalesce((p_patch ->> 'is_company')::boolean, false);
  end if;
  if p_patch ? 'company_name' then
    v_row.company_name := p_patch ->> 'company_name';
  end if;
  if p_patch ? 'first_name' then
    v_row.first_name := btrim(coalesce(p_patch ->> 'first_name', ''));
  end if;
  if p_patch ? 'last_name' then
    v_row.last_name := btrim(coalesce(p_patch ->> 'last_name', ''));
  end if;
  if p_patch ? 'phone' then
    v_row.phone := btrim(coalesce(p_patch ->> 'phone', ''));
  end if;
  if p_patch ? 'phone2' then
    v_row.phone2 := nullif(btrim(coalesce(p_patch ->> 'phone2', '')), '');
  end if;
  if p_patch ? 'email' then
    v_row.email := btrim(coalesce(p_patch ->> 'email', ''));
  end if;
  if p_patch ? 'referral_source' then
    v_row.referral_source := nullif(btrim(coalesce(p_patch ->> 'referral_source', '')), '');
  end if;
  if p_patch ? 'customer_since' then
    v_since := nullif(btrim(coalesce(p_patch ->> 'customer_since', '')), '')::date;
    if v_since is null then
      raise exception 'Customer since needs a date';
    end if;
    if v_since > current_date then
      raise exception 'Customer since cannot be in the future';
    end if;
    v_row.customer_since := v_since;
  end if;
  if p_patch ? 'street_address' then
    v_row.street_address := nullif(btrim(coalesce(p_patch ->> 'street_address', '')), '');
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

  if not v_row.is_company then
    if v_row.first_name = '' then
      raise exception 'First name is required';
    end if;
    if v_row.last_name = '' then
      raise exception 'Last name is required';
    end if;
  end if;
  if v_row.phone = '' then
    raise exception 'Phone is required';
  end if;
  if v_row.email = '' then
    raise exception 'Email is required';
  end if;

  update public.customers set
    is_company = v_row.is_company,
    company_name = v_row.company_name,
    first_name = v_row.first_name,
    last_name = v_row.last_name,
    phone = v_row.phone,
    phone2 = v_row.phone2,
    email = v_row.email,
    referral_source = v_row.referral_source,
    customer_since = v_row.customer_since,
    street_address = v_row.street_address,
    street_address_line_2 = v_row.street_address_line_2,
    city = v_row.city,
    state = v_row.state,
    zip_code = v_row.zip_code
  where id = p_id;

  return public.get_customer(p_id);
end;
$$;

revoke execute on function public.update_customer(uuid, jsonb) from public, anon;
grant execute on function public.update_customer(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. merge_customers: managers, admins and owners only
--    Moves every order and linked record from p_remove to p_keep, fills
--    blanks on p_keep from p_remove, writes the merge log, deletes p_remove.
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

  update public.sleep_journeys set customer_id = p_keep where customer_id = p_remove;
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
