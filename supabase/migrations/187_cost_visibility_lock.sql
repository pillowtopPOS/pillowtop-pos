-- ============================================================================
-- 187: cost visibility lock for journey line items
--
-- journey_line_items carries two cost snapshots captured when a line is
-- sold. Table-level SELECT on the base table would expose those columns to
-- every authenticated employee who can see the journey through RLS, so this
-- migration replaces table-level SELECT with explicit column grants.
--
-- Important for future migrations: columns added to journey_line_items
-- later are NOT readable by authenticated until a later migration grants
-- them by name. That is intentional. Column grants do not automatically
-- cover future columns once table-level SELECT is revoked, and cost-like
-- fields must be a conscious grant decision instead of leaking by default.
--
-- INSERT, UPDATE and DELETE privileges and every RLS policy are unchanged.
-- The browser can still write lines through the existing direct table
-- writes, and security definer snapshot triggers can still maintain the
-- protected columns.
--
-- Re-runnable: REVOKE and GRANT are idempotent here, and the column list is
-- rebuilt from the live catalog each run.
-- ============================================================================

revoke select on public.journey_line_items from authenticated, anon, public;

do $$
declare
  v_cols text;
begin
  select string_agg(format('%I', c.column_name), ', ' order by c.ordinal_position)
    into v_cols
  from information_schema.columns c
  where c.table_schema = 'public'
    and c.table_name = 'journey_line_items'
    and c.column_name not in (
      'unit_cost_snapshot',
      'unit_commission_cost_snapshot'
    );

  if v_cols is null then
    raise exception 'journey_line_items columns not found';
  end if;

  execute format(
    'grant select (%s) on public.journey_line_items to authenticated',
    v_cols
  );
end;
$$;

-- Expected booleans, in order:
-- false, false, true, true, true, true, true.
select
  has_column_privilege(
    'authenticated', 'public.journey_line_items',
    'unit_cost_snapshot', 'select'
  ) as unit_cost_snapshot_select,
  has_column_privilege(
    'authenticated', 'public.journey_line_items',
    'unit_commission_cost_snapshot', 'select'
  ) as unit_commission_cost_snapshot_select,
  has_column_privilege(
    'authenticated', 'public.journey_line_items',
    'item_name', 'select'
  ) as item_name_select,
  has_column_privilege(
    'authenticated', 'public.journey_line_items',
    'quantity', 'select'
  ) as quantity_select,
  has_table_privilege(
    'authenticated', 'public.journey_line_items', 'insert'
  ) as insert_allowed,
  has_table_privilege(
    'authenticated', 'public.journey_line_items', 'update'
  ) as update_allowed,
  has_table_privilege(
    'authenticated', 'public.journey_line_items', 'delete'
  ) as delete_allowed;
