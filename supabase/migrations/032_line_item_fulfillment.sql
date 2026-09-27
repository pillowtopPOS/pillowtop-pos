-- PillowTop POS: per-line-item fulfillment overrides and customer addresses

alter table public.customers
  add column if not exists street_address text,
  add column if not exists city text,
  add column if not exists state text,
  add column if not exists zip_code text;

alter table public.journey_line_items
  add column if not exists fulfillment_type_override public.fulfillment_type,
  add column if not exists pickup_location_id uuid references public.stores(id) on delete set null;

-- Pickup locations must be in the Journey's company and be a STORE or WAREHOUSE.
create or replace function public.validate_line_item_fulfillment()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_journey_company uuid; v_location public.stores%rowtype;
begin
  if new.pickup_location_id is null then return new; end if;
  if new.fulfillment_type_override is distinct from 'pickup' then
    raise exception 'pickup_location_id is only valid for pickup line items';
  end if;
  select s.company_id into v_journey_company
  from public.sleep_journeys sj join public.stores s on s.id = sj.store_id
  where sj.id = new.journey_id;
  select * into v_location from public.stores where id = new.pickup_location_id;
  if not found or v_location.location_type not in ('STORE', 'WAREHOUSE') then
    raise exception 'Pickup location must be a STORE or WAREHOUSE';
  end if;
  if v_location.company_id is distinct from v_journey_company then
    raise exception 'Pickup location must belong to the Journey company';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_validate_line_item_fulfillment on public.journey_line_items;
create trigger trg_validate_line_item_fulfillment
before insert or update of fulfillment_type_override, pickup_location_id, journey_id
on public.journey_line_items for each row
execute function public.validate_line_item_fulfillment();

-- Rebuild existing active reservations when a line item's effective sourcing
-- fields change. This deliberately rebuilds every active requirement,
-- including items whose effective location did not change. Release-then-
-- re-reserve nets out safely in this transaction; the tradeoff is minor
-- audit-history churn in exchange for simpler code. Old requirements are
-- preserved as superseded.
create or replace function public.rebuild_journey_inventory_reservations(p_journey_id uuid)
returns void language plpgsql security definer set search_path = public
as $$
declare r record;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_journey_id::text, 7137));
  for r in select * from public.journey_inventory_requirements where journey_id = p_journey_id and status in ('pending','ready') order by variant_id, location_id for update loop
    if r.quantity_reserved > 0 then
      perform pg_advisory_xact_lock(hashtextextended(r.variant_id::text || ':' || r.location_id::text || ':Prime', 7137));
      update public.inventory_positions set committed_quantity = committed_quantity - r.quantity_reserved, updated_at = now()
      where variant_id = r.variant_id and location_id = r.location_id and disposition = 'Prime' and sublocation_id is null;
    end if;
    update public.journey_inventory_requirements set status = 'superseded' where id = r.id;
  end loop;
  perform public.evaluate_journey_inventory(p_journey_id);
end;
$$;
revoke execute on function public.rebuild_journey_inventory_reservations(uuid) from authenticated, anon;

create or replace function public.line_item_fulfillment_hook()
returns trigger language plpgsql security definer set search_path = public
as $$
begin
  perform public.rebuild_journey_inventory_reservations(coalesce(new.journey_id, old.journey_id));
  return coalesce(new, old);
end;
$$;
revoke execute on function public.line_item_fulfillment_hook() from authenticated, anon;

drop trigger if exists trg_line_item_fulfillment_rebuild on public.journey_line_items;
create trigger trg_line_item_fulfillment_rebuild
after update of fulfillment_type_override, pickup_location_id on public.journey_line_items
for each row execute function public.line_item_fulfillment_hook();

-- INSERT intentionally does not rebuild existing reservations. The earlier
-- journey_inventory_line_item_hook evaluates the Journey for order_creation
-- without releasing correct reservations. Only an override/pickup-location
-- UPDATE rebuilds all active requirements, which is noisier but preserves the
-- simple release-then-re-reserve behavior for effective-location changes.
