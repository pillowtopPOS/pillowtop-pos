-- PillowTop POS: release only active inventory requirements on cancellation

-- Superseded requirements preserve quantity_reserved for audit but have
-- already released their inventory. They must never be released again.
create or replace function public.release_journey_inventory(p_journey_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  r record;
begin
  perform pg_advisory_xact_lock(hashtextextended(p_journey_id::text, 7137));

  for r in
    select *
    from public.journey_inventory_requirements
    where journey_id = p_journey_id
      and status in ('pending', 'ready')
    order by variant_id, location_id
    for update
  loop
    if r.quantity_reserved > 0 then
      perform pg_advisory_xact_lock(
        hashtextextended(
          r.variant_id::text || ':' || r.location_id::text || ':Prime',
          7137
        )
      );

      update public.inventory_positions
      set committed_quantity = committed_quantity - r.quantity_reserved,
          updated_at = now()
      where variant_id = r.variant_id
        and location_id = r.location_id
        and disposition = 'Prime'
        and sublocation_id is null;
    end if;

    update public.journey_inventory_requirements
    set status = 'cancelled'
    where id = r.id;
  end loop;
end;
$$;

revoke execute on function public.release_journey_inventory(uuid)
from authenticated, anon;
