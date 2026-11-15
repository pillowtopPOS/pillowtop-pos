-- T112 seed v2: 4 unit-tracked demo products cloned from DEMO-UNIT-1.
-- Skips generated columns (e.g. search_text). Zero stock everywhere
-- (no inventory_positions inserted). Safe to run twice.
begin;

do $$
declare
  cols text;
begin
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position)
    into cols
  from information_schema.columns
  where table_schema = 'public'
    and table_name = 'products'
    and is_generated = 'NEVER';

  execute format($f$
    insert into public.products (%1$s)
    select %1$s
    from (
      select (jsonb_populate_record(
               null::public.products,
               (to_jsonb(src) - 'id')
                 || jsonb_build_object(
                      'id',        gen_random_uuid(),
                      'sku',       n.sku,
                      'item_name', n.item_name,
                      'price',     1.00)
             )).*
      from public.products src
      cross join (values
        ('DEMO-T112-A', 'T112 Tracked A'),
        ('DEMO-T112-B', 'T112 Tracked B'),
        ('DEMO-T112-C', 'T112 Tracked C'),
        ('DEMO-T112-D', 'T112 Tracked D')
      ) as n(sku, item_name)
      where src.sku = 'DEMO-UNIT-1'
        and not exists (
          select 1 from public.products e
          where e.company_id = src.company_id
            and e.sku = n.sku
        )
    ) x
  $f$, cols);
end $$;

-- verification: tracked flag must be true, on-hand stock must be 0
select p.sku,
       p.item_name,
       public.is_unit_tracked(p.id) as is_unit_tracked,
       (select count(*) from public.inventory_positions ip
         where ip.variant_id = p.id
           and ip.on_hand_quantity > 0) as positions_with_stock
from public.products p
where p.sku in ('DEMO-T112-A','DEMO-T112-B','DEMO-T112-C','DEMO-T112-D')
order by p.sku;

commit;
