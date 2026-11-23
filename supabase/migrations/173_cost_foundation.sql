-- ============================================================================
-- 173: Cost foundation for commission groundwork.
--
--   1. products.commission_cost: optional override cost used only by the
--      commission calculation. Null means "use cost".
--   2. journey_line_items: per-line snapshots taken at insert time so the
--      cost in effect when the item was sold survives later catalog edits.
--      unit_cost_snapshot copies products.cost;
--      unit_commission_cost_snapshot copies
--      coalesce(products.commission_cost, products.cost).
--      Lines with no product (credit and fee lines) stay null.
--   3. A product_id change refreshes both snapshots only while the journey
--      has never had a payment; once money moved, the snapshots are part
--      of the sale record and stay put.
--   4. companies.commission_cost_basis: which cost the commission
--      calculation uses. 'WHOLESALE' = the cost snapshot,
--      'COMMISSION_COST' = the commission-cost snapshot.
--
--   No backfill: existing lines keep null snapshots. No RLS, view or
--   grant changes; who can see cost is a later slice.
-- ============================================================================

alter table public.products
  add column if not exists commission_cost numeric;

comment on column public.products.commission_cost is
  'Optional commission-only cost override. Null means the commission calculation uses cost.';

alter table public.journey_line_items
  add column if not exists unit_cost_snapshot numeric,
  add column if not exists unit_commission_cost_snapshot numeric;

comment on column public.journey_line_items.unit_cost_snapshot is
  'products.cost captured when the line was added. Null for lines with no product and for pre-173 lines.';
comment on column public.journey_line_items.unit_commission_cost_snapshot is
  'coalesce(products.commission_cost, products.cost) captured when the line was added. Null for lines with no product and for pre-173 lines.';

alter table public.companies
  add column if not exists commission_cost_basis text not null default 'WHOLESALE'
    check (commission_cost_basis in ('WHOLESALE', 'COMMISSION_COST'));

comment on column public.companies.commission_cost_basis is
  'Which cost the commission calculation uses: WHOLESALE reads the unit_cost_snapshot, COMMISSION_COST reads the unit_commission_cost_snapshot.';

-- ----------------------------------------------------------------------------
-- Snapshot trigger. Fires BEFORE INSERT (fills empty snapshots from the
-- product) and BEFORE UPDATE OF product_id (refreshes snapshots from the
-- new product only while the journey has never had a payment).
-- ----------------------------------------------------------------------------
create or replace function public.journey_line_item_cost_snapshot()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_product_cost            numeric;
  v_product_commission_cost numeric;
  v_has_payment             boolean;
begin
  if tg_op = 'INSERT' then
    if new.product_id is null then
      return new;
    end if;
    if new.unit_cost_snapshot is not null
       and new.unit_commission_cost_snapshot is not null then
      return new;
    end if;
    select p.cost, p.commission_cost
      into v_product_cost, v_product_commission_cost
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

  select p.cost, p.commission_cost
    into v_product_cost, v_product_commission_cost
  from public.products p
  where p.id = new.product_id;
  if not found then
    return new;
  end if;

  new.unit_cost_snapshot := v_product_cost;
  new.unit_commission_cost_snapshot :=
    coalesce(v_product_commission_cost, v_product_cost);
  return new;
end;
$$;

drop trigger if exists trg_line_item_cost_snapshot_insert
  on public.journey_line_items;
create trigger trg_line_item_cost_snapshot_insert
  before insert on public.journey_line_items
  for each row
  execute function public.journey_line_item_cost_snapshot();

drop trigger if exists trg_line_item_cost_snapshot_product
  on public.journey_line_items;
create trigger trg_line_item_cost_snapshot_product
  before update of product_id on public.journey_line_items
  for each row
  execute function public.journey_line_item_cost_snapshot();

revoke execute on function public.journey_line_item_cost_snapshot()
  from public, anon, authenticated;
