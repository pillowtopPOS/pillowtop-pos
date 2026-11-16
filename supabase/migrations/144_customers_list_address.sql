-- Migration 144: Customers list returns the address
--
-- search_customers (m143) now also returns street_address,
-- street_address_line_2 and zip_code for each row so the Customers list can
-- show the full address. Nothing else changes. Idempotent.

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
        'street_address', p.street_address,
        'street_address_line_2', p.street_address_line_2,
        'city', p.city,
        'state', p.state,
        'zip_code', p.zip_code,
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
