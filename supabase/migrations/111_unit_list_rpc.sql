-- ============================================================================
-- Units List Stage 1: browsable unit list RPC
--
-- The Units screen makes one call per page: filters, search, sort and paging
-- are all server-side. Held units carry their customer order so staff can
-- find a unit by who it belongs to. Company isolation is enforced exactly
-- like the other unit RPCs: the caller's company comes from the session.
-- ============================================================================

create or replace function public.list_units(
  p_search text default null,
  p_status text default null,
  p_location_id uuid default null,
  p_held_only boolean default false,
  p_show_void boolean default false,
  p_sort text default 'unit_number',
  p_dir text default 'desc',
  p_limit integer default 50,
  p_offset integer default 0
)
returns table (
  total_count bigint,
  unit_id uuid,
  unit_number bigint,
  status text,
  product_id uuid,
  sku text,
  item_name text,
  location_id uuid,
  location_name text,
  created_at timestamptz,
  journey_id uuid,
  journey_number text,
  customer_name text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company uuid;
  v_term text;
  v_raw text;
  v_sort text;
  v_dir text;
  v_limit integer;
begin
  select s.company_id into v_company
  from public.employees e
  join public.stores s on s.id = e.home_store_id
  where e.auth_user_id = auth.uid() and e.is_active;
  if v_company is null then
    raise exception 'You do not have permission to view units.';
  end if;

  if p_status is not null
     and p_status not in ('STOCK','RESERVED','IN_TRANSIT','STAGED','DELIVERED',
                          'RETURNED','QUARANTINE','DAMAGED','MISSING','VOID') then
    raise exception 'Unknown status.';
  end if;

  v_sort := lower(coalesce(p_sort, 'unit_number'));
  if v_sort not in ('unit_number','sku','item_name','location','status',
                    'received','customer','journey_number') then
    raise exception 'Unknown sort.';
  end if;
  v_dir := lower(coalesce(p_dir, 'desc'));
  if v_dir not in ('asc', 'desc') then
    raise exception 'Unknown sort direction.';
  end if;

  if p_offset < 0 then
    raise exception 'Offset must not be negative.';
  end if;
  v_limit := greatest(1, least(coalesce(p_limit, 50), 100));

  v_raw := nullif(trim(coalesce(p_search, '')), '');
  if v_raw is not null then
    -- Escape ILIKE wildcards and the escape char itself so users cannot
    -- inject patterns into the search.
    v_term := '%' || replace(replace(replace(v_raw, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  return query
  select
    count(*) over () as total_count,
    u.id, u.unit_number, u.status::text, u.product_id, p.sku, p.item_name,
    u.location_id, st.name, u.created_at,
    sj.id, sj.journey_number,
    nullif(trim(concat_ws(' ', c.first_name, c.last_name)), '')
  from public.units u
  join public.products p on p.id = u.product_id
  left join public.stores st on st.id = u.location_id
  left join public.journey_inventory_requirements jir
    on jir.id = u.assigned_requirement_id
  -- No per-journey visibility gate by product decision: all employees of
  -- the company may see customer names. The journey's store scopes the
  -- customer to the same company.
  -- Delivered units resolve their customer through delivered_journey_id so
  -- staff can find who received a unit.
  left join public.sleep_journeys sj
    on sj.id = coalesce(jir.journey_id, u.delivered_journey_id)
  left join public.stores js on js.id = sj.store_id and js.company_id = v_company
  left join public.customers c on c.id = sj.customer_id and js.id is not null
  where u.company_id = v_company
    and (p_status is null or u.status = p_status)
    and (p_show_void or p_status = 'VOID' or u.status <> 'VOID')
    and (p_location_id is null or u.location_id = p_location_id)
    and (not p_held_only or u.assigned_requirement_id is not null)
    and (
      v_raw is null
      or p.sku ilike v_term escape '\'
      or p.item_name ilike v_term escape '\'
      or sj.journey_number ilike v_term escape '\'
      or nullif(trim(concat_ws(' ', c.first_name, c.last_name)), '')
           ilike v_term escape '\'
      or (v_raw ~ '^[0-9]+$' and length(v_raw) <= 18
          and u.unit_number = v_raw::bigint)
      or (v_raw ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
          and u.id = v_raw::uuid)
    )
  order by
    -- Whitelisted sort arms: nothing user-controlled reaches the SQL text.
    case when v_sort = 'unit_number' and v_dir = 'asc'  then u.unit_number end asc nulls last,
    case when v_sort = 'unit_number' and v_dir = 'desc' then u.unit_number end desc nulls last,
    case when v_sort = 'received' and v_dir = 'asc'  then u.created_at end asc nulls last,
    case when v_sort = 'received' and v_dir = 'desc' then u.created_at end desc nulls last,
    case when v_dir = 'asc' and v_sort = 'sku' then p.sku end asc nulls last,
    case when v_dir = 'desc' and v_sort = 'sku' then p.sku end desc nulls last,
    case when v_dir = 'asc' and v_sort = 'item_name' then p.item_name end asc nulls last,
    case when v_dir = 'desc' and v_sort = 'item_name' then p.item_name end desc nulls last,
    case when v_dir = 'asc' and v_sort = 'location' then st.name end asc nulls last,
    case when v_dir = 'desc' and v_sort = 'location' then st.name end desc nulls last,
    case when v_dir = 'asc' and v_sort = 'status' then u.status::text end asc nulls last,
    case when v_dir = 'desc' and v_sort = 'status' then u.status::text end desc nulls last,
    case when v_dir = 'asc' and v_sort = 'customer'
      then nullif(trim(concat_ws(' ', c.first_name, c.last_name)), '') end asc nulls last,
    case when v_dir = 'desc' and v_sort = 'customer'
      then nullif(trim(concat_ws(' ', c.first_name, c.last_name)), '') end desc nulls last,
    case when v_dir = 'asc' and v_sort = 'journey_number' then sj.journey_number end asc nulls last,
    case when v_dir = 'desc' and v_sort = 'journey_number' then sj.journey_number end desc nulls last,
    u.unit_number desc
  limit v_limit
  offset p_offset;
end;
$$;

comment on function public.list_units(text, text, uuid, boolean, boolean, text, text, integer, integer) is
  'One-call unit list for the Units screen: search, filters, sort and
   paging, with customer order info on held units. Returns total_count
   alongside each row so the UI can page without a second call.
   ILIKE over joined customer names will need pg_trgm indexes for PERF,
   deferred, not part of this slice.';

grant execute on function public.list_units(text, text, uuid, boolean, boolean, text, text, integer, integer) to authenticated;
revoke execute on function public.list_units(text, text, uuid, boolean, boolean, text, text, integer, integer) from public, anon;

select
  has_function_privilege('authenticated', 'public.list_units(text,text,uuid,boolean,boolean,text,text,integer,integer)', 'execute') as auth_ok,
  has_function_privilege('anon', 'public.list_units(text,text,uuid,boolean,boolean,text,text,integer,integer)', 'execute') as anon_ok;
