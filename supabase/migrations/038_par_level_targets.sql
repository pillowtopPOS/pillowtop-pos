-- PillowTop POS: separate par-level reorder point and target quantity

-- Existing minimum_quantity values were being used as the restock target.
-- Rename them so existing data is preserved without modification.
alter table public.par_levels
  rename column minimum_quantity to target_quantity;

-- Existing rows receive 0. No reorder automation exists in this phase, so
-- reorder points must be set manually before future automation can act.
alter table public.par_levels
  add column reorder_point integer not null default 0
  check (reorder_point >= 0);

alter table public.par_levels
  add constraint par_levels_reorder_point_lte_target
  check (reorder_point <= target_quantity);
