-- ============================================================================
-- 142: Customer foundation (slice 1 of 3)
--
-- customers gains company_id (backfilled through the customer's journeys ->
-- stores), a second phone, a referral source, a customer-since date, and an
-- updated_at stamp. A format trigger normalizes phone and phone2 to
-- xxx-xxx-xxxx (odd-length values are left as typed). A company-scoped
-- SELECT policy lets employees see customers with no journeys yet, and
-- find_matching_customers powers the repeat-customer lookup on the new
-- order form.
--
-- Idempotent: every statement is if-not-exists / create-or-replace /
-- where-guarded, so running this file twice is a no-op.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. New columns. No company or address columns are added here; the
--    existing street_address/city/state/zip columns are untouched.
-- ---------------------------------------------------------------------------

alter table public.customers
  add column if not exists company_id uuid references public.companies (id),
  add column if not exists phone2 text,
  add column if not exists referral_source text,
  add column if not exists customer_since date,
  add column if not exists updated_at timestamptz not null default now();

comment on column public.customers.company_id is
  'Company that owns this customer. Set from the caller''s employee company on insert when absent; backfilled from the customer''s journeys.';
comment on column public.customers.phone2 is
  'Optional second phone number, formatted xxx-xxx-xxxx by trigger when recognizable.';
comment on column public.customers.referral_source is
  'How the customer heard about us (free-text label chosen on the order form).';
comment on column public.customers.customer_since is
  'Date the customer relationship started; defaults to the order date for new rows, backfilled from created_at for existing rows.';
comment on column public.customers.updated_at is
  'Last time any customer column was written.';

-- ---------------------------------------------------------------------------
-- 2. Backfill. company_id comes from the customer's earliest journey's store;
--    customers with no journey stay null. customer_since falls back to the
--    row's created date, then the column default becomes current_date.
-- ---------------------------------------------------------------------------

update public.customers c
set company_id = sub.company_id
from (
  select distinct on (sj.customer_id)
    sj.customer_id,
    s.company_id
  from public.sleep_journeys sj
  join public.stores s on s.id = sj.store_id
  order by sj.customer_id, sj.created_at
) sub
where c.id = sub.customer_id
  and c.company_id is null;

update public.customers
set customer_since = created_at::date
where customer_since is null;

alter table public.customers
  alter column customer_since set default current_date;

-- ---------------------------------------------------------------------------
-- 3. BEFORE INSERT: fill company_id from the caller's employee company.
--    Under the service role auth.uid() is null, so the helper returns null
--    and the column simply stays null.
-- ---------------------------------------------------------------------------

create or replace function public.customers_set_company_id()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.company_id is null then
    new.company_id := public.current_employee_company_id();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_customers_set_company_id on public.customers;
create trigger trg_customers_set_company_id
before insert on public.customers
for each row execute function public.customers_set_company_id();

-- ---------------------------------------------------------------------------
-- 4. format_phone_dashed: canonical display/storage form xxx-xxx-xxxx.
--    Digits only; a leading 1 on an 11-digit number is dropped; exactly 10
--    digits formats, anything else returns the trimmed input unchanged.
--    Same grants lesson as m134: triggers and indexes evaluate under the
--    caller's rights, so authenticated and service_role keep EXECUTE.
-- ---------------------------------------------------------------------------

create or replace function public.format_phone_dashed(p_phone text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  v text;
begin
  if p_phone is null then
    return null;
  end if;
  v := regexp_replace(p_phone, '\D', '', 'g');
  if length(v) = 11 and left(v, 1) = '1' then
    v := substr(v, 2);
  end if;
  if length(v) = 10 then
    return substr(v, 1, 3) || '-' || substr(v, 4, 3) || '-' || substr(v, 7, 4);
  end if;
  return btrim(p_phone);
end;
$$;

revoke execute on function public.format_phone_dashed(text) from public, anon;
grant execute on function public.format_phone_dashed(text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. BEFORE INSERT OR UPDATE: normalize both phone columns and stamp
--    updated_at on update. format_phone_dashed is idempotent, so the
--    backfill below can run through this trigger safely.
-- ---------------------------------------------------------------------------

create or replace function public.customers_format_phones()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.phone := public.format_phone_dashed(new.phone);
  new.phone2 := public.format_phone_dashed(new.phone2);
  if tg_op = 'UPDATE' then
    new.updated_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists trg_customers_format_phones on public.customers;
create trigger trg_customers_format_phones
before insert or update on public.customers
for each row execute function public.customers_format_phones();

-- ---------------------------------------------------------------------------
-- 6. Backfill existing phones into the dashed form. Safe for the m134 hold
--    logic and the customers_norm_phone_idx expression index: every phone
--    comparison in the schema goes through delivery_norm_phone, which
--    strips non-digits before comparing, so reformatting cannot change any
--    match result. Verified by grep: the only raw phone reads are display
--    selects (004_phase2, 132, 136) and the index/function definitions.
-- ---------------------------------------------------------------------------

update public.customers c
set phone = public.format_phone_dashed(c.phone)
where public.format_phone_dashed(c.phone) is distinct from c.phone;

-- ---------------------------------------------------------------------------
-- 7. Company-scoped SELECT. Kept alongside the existing journey-based
--    policy (policies are OR'd): a customer is visible if the caller can
--    see any of its journeys OR it belongs to the caller's company.
--    INSERT/UPDATE/DELETE policies are untouched.
-- ---------------------------------------------------------------------------

drop policy if exists "Customers viewable within company" on public.customers;
create policy "Customers viewable within company"
  on public.customers for select
  to authenticated
  using (
    company_id is not null
    and company_id = public.current_employee_company_id()
  );

-- ---------------------------------------------------------------------------
-- 8. find_matching_customers: repeat-customer lookup for the order form.
--    Security definer so the company filter is authoritative regardless of
--    the caller's row visibility; returns at most 5 ranked candidates.
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
begin
  if v_company is null then
    raise exception 'No company for this user';
  end if;

  -- Email counts only when the input actually looks like an email.
  v_email := case
    when position('@' in coalesce(p_email, '')) > 0
      then lower(btrim(p_email))
    else null
  end;

  v_name_ok :=
    length(coalesce(v_first, '')) >= 2
    and length(coalesce(v_last, '')) >= 2;

  return coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id', s.id,
        'first_name', s.first_name,
        'last_name', s.last_name,
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
          (v_name_ok
            and lower(btrim(cu.first_name)) = lower(v_first)
            and lower(btrim(cu.last_name)) = lower(v_last)) as m_name
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

-- 9. Tenant guards on customers.company_id (found in review: with the old
--    INSERT policy (check true) any signed-in user could plant a customer in
--    ANOTHER company, and the new company-scoped SELECT then shows it there).
drop policy if exists "Customers insertable by authenticated users" on public.customers;
create policy "Customers insertable by authenticated users"
  on public.customers for insert
  to authenticated
  with check (
    company_id is not null
    and company_id = public.current_employee_company_id()
  );

create or replace function public.customers_lock_company_id()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  -- Signed-in users can never move a customer between companies. Service
  -- role (auth.uid() is null) may, for data repair.
  if auth.uid() is not null
     and old.company_id is not null
     and new.company_id is distinct from old.company_id then
    raise exception 'A customer cannot be moved to another company';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_customers_lock_company_id on public.customers;
create trigger trg_customers_lock_company_id
before update on public.customers
for each row execute function public.customers_lock_company_id();
