-- PillowTop POS: require a customer address for Delivery fulfillment

alter table public.customers
  add column if not exists street_address_line_2 text;

-- Customer-level address removal is blocked while any active Journey depends
-- on delivery. Pickup-only Journeys remain unaffected.
create or replace function public.validate_customer_delivery_address_removal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if trim(coalesce(new.street_address, '')) = ''
    and exists (
      select 1
      from public.sleep_journeys sj
      where sj.customer_id = new.id
        and sj.cancelled_at is null
        and (
          sj.fulfillment_type = 'delivery'
          or exists (
            select 1
            from public.journey_line_items jli
            where jli.journey_id = sj.id
              and coalesce(jli.fulfillment_type_override, sj.fulfillment_type) = 'delivery'
          )
        )
    )
  then
    raise exception 'Cannot remove this address while an active delivery depends on it. Change those Journeys to Pickup or cancel them first.';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_customer_delivery_address on public.customers;
create trigger trg_validate_customer_delivery_address
before update of street_address, street_address_line_2, city, state, zip_code
on public.customers
for each row
execute function public.validate_customer_delivery_address_removal();

-- The address editor needs an UPDATE policy. Returning the updated id in the
-- client helper also lets it detect an RLS-filtered zero-row update.
grant update on public.customers to authenticated;
drop policy if exists "Customers updatable for visible journeys" on public.customers;
create policy "Customers updatable for visible journeys"
  on public.customers for update
  to authenticated
  using (
    exists (
      select 1
      from public.sleep_journeys sj
      where sj.customer_id = customers.id
        and public.is_journey_visible(sj.id)
    )
  )
  with check (true);

-- A Journey may use Delivery only when its customer has a non-empty street
-- address. This watches only user-facing fulfillment/customer columns; system
-- reservation functions update state and inventory fields, not these columns.
create or replace function public.validate_journey_delivery_address()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.fulfillment_type = 'delivery'
    and not exists (
      select 1
      from public.customers c
      where c.id = new.customer_id
        and trim(coalesce(c.street_address, '')) <> ''
    )
  then
    raise exception 'A customer street address is required for Delivery fulfillment';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_journey_delivery_address on public.sleep_journeys;
create trigger trg_validate_journey_delivery_address
before insert or update of fulfillment_type, customer_id
on public.sleep_journeys
for each row
execute function public.validate_journey_delivery_address();

-- A line item's effective fulfillment is its override, falling back to the
-- Journey default. Pickup locations do not require an address.
create or replace function public.validate_line_item_delivery_address()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_id uuid;
  v_journey_fulfillment public.fulfillment_type;
begin
  select customer_id, fulfillment_type
  into v_customer_id, v_journey_fulfillment
  from public.sleep_journeys
  where id = new.journey_id;

  if coalesce(new.fulfillment_type_override, v_journey_fulfillment) = 'delivery'
    and not exists (
      select 1
      from public.customers c
      where c.id = v_customer_id
        and trim(coalesce(c.street_address, '')) <> ''
    )
  then
    raise exception 'A customer street address is required for Delivery fulfillment';
  end if;

  return new;
end;
$$;

drop trigger if exists trg_validate_line_item_delivery_address on public.journey_line_items;
create trigger trg_validate_line_item_delivery_address
before insert or update of fulfillment_type_override, pickup_location_id, journey_id
on public.journey_line_items
for each row
execute function public.validate_line_item_delivery_address();
