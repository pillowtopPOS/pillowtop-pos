-- PillowTop POS: tighten PO line-item update policy
--
-- The update policy on purchase_order_line_items previously had
-- `with check (true)` — the USING clause restricted *which rows* could be
-- touched (draft POs only) but placed no constraint on the *new values*.
-- A privileged user could write quantity_received directly via a raw client
-- update, bypassing receive_purchase_order_line() and its ledger/audit trail.
--
-- Draft lines legitimately always have quantity_received = 0: receiving only
-- exists via the security-definer RPC on submitted/partially_received POs,
-- and security-definer code bypasses RLS anyway, so this check cannot break
-- the real receiving path.

drop policy if exists "PO lines updatable by owner admin manager"
  on public.purchase_order_line_items;

create policy "PO lines updatable by owner admin manager"
  on public.purchase_order_line_items
  for update to authenticated
  using (
    exists (
      select 1 from public.purchase_orders po
      where po.id = purchase_order_id
        and po.status = 'draft'
        and public.current_employee_role()::text in ('owner','admin','manager')
        and public.is_store_visible(po.destination_location_id)
    )
  )
  with check (quantity_received = 0);
