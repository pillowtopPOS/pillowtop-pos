# Unit ID, S1 Stage 2: close out S1 and build the Units page

Branch: keep working on `unit-s1`. Do not touch migration 101 (it is installed in Supabase and verified). Zach runs every migration, so you only write files.

## Where S1 stands
Migration 101 is installed. I ran an 81-check real-database test against it: all pass. It found one bug (below). Fix is installed in Supabase already; the repo needs the file.

## Part 1: repo housekeeping (small)
1. Add `supabase/migrations/102_unit_consistency_company_scope.sql` with EXACTLY this content (it is already installed; the repo must match):

```sql
-- 102: scope check_unit_consistency to the requested company.
-- 101 compared the requested company's units against inventory_positions of
-- EVERY company's tracked products, so one company's discrepancy report could
-- list another company's products and stock. Same signature, same behavior,
-- plus a company filter on the tracked-product list.

create or replace function public.check_unit_consistency(p_company_id uuid)
returns table (
  product_id uuid,
  location_id uuid,
  disposition public.disposition,
  units_on_hand bigint,
  mirror_on_hand integer,
  units_reserved bigint,
  mirror_committed integer
)
language sql
stable
security definer
set search_path = public
as $$
  with tracked_products as (
    select p.id
    from public.products p
    where p.company_id = p_company_id
      and public.is_unit_tracked(p.id)
  ),
  unit_counts as (
    select u.product_id, u.location_id, u.disposition,
      count(*) filter (where u.status in
        ('STOCK','RESERVED','STAGED','QUARANTINE','DAMAGED','RETURNED'))
        as on_hand_units,
      count(*) filter (where u.status = 'RESERVED') as reserved_units
    from public.units u
    where u.company_id = p_company_id
      and u.status <> 'VOID'
      and u.product_id in (select id from tracked_products)
    group by u.product_id, u.location_id, u.disposition
  ),
  mirror_counts as (
    select ip.variant_id as product_id, ip.location_id, ip.disposition,
      ip.on_hand_quantity, ip.committed_quantity
    from public.inventory_positions ip
    where ip.variant_id in (select id from tracked_products)
  )
  select
    coalesce(u.product_id, m.product_id) as product_id,
    coalesce(u.location_id, m.location_id) as location_id,
    coalesce(u.disposition, m.disposition) as disposition,
    coalesce(u.on_hand_units, 0) as units_on_hand,
    coalesce(m.on_hand_quantity, 0) as mirror_on_hand,
    coalesce(u.reserved_units, 0) as units_reserved,
    coalesce(m.committed_quantity, 0) as mirror_committed
  from unit_counts u
  full outer join mirror_counts m
    on m.product_id = u.product_id
    and m.location_id = u.location_id
    and m.disposition = u.disposition
  where coalesce(u.on_hand_units, 0) <> coalesce(m.on_hand_quantity, 0)
     or coalesce(u.reserved_units, 0) <> coalesce(m.committed_quantity, 0);
$$;

revoke execute on function public.check_unit_consistency(uuid)
  from authenticated, anon, public;
```

Why: `check_unit_consistency` in 101 compared one company's units against stock for every company's tracked products, so company A's discrepancy report could list company B's products and quantities. The only change is the `p.company_id = p_company_id` filter.

2. Zach attaches `unit_s1_check.sql` to this prompt. Save it as `scripts/unit_s1_check.sql` and delete `scripts/unit_s1_verify.sql` (it was never run and is replaced). Do not edit the check script.

3. New migration `103_unit_events_clock_timestamp.sql`: one statement, `alter table public.unit_events alter column created_at set default clock_timestamp();`, plus a comment explaining why: now() is the transaction start, so several moves inside one transaction got identical timestamps and the history order was ambiguous. End the file with one select that returns the column default text from information_schema so Zach can confirm it installed. Do not rewrite existing rows.

## Part 2: the Units page (UI only, no new RPCs)
Nothing creates units yet (that is S2), so this page will be empty in real use until then. Build it so every empty state reads as correct, not broken.

Route: `/units`, linked from the main navigation next to Inventory. Visible to every signed-in employee (units are readable company-wide by RLS).

**A. Lookup.** One text input, autofocused, Enter submits (a keyboard-wedge barcode scanner types the number and presses Enter, so this must work with no mouse). Accept digits only; trim whitespace. Query `units` by `unit_number` (RLS scopes to the company). States: idle, loading, found, not found ("No unit with that number."), failed (message plus a Retry button). Use a single stable input element; do not swap control types between states.

On found, show a card:
- Unit number (large), status as a plain-English badge (STOCK = "In stock", RESERVED = "Held for a customer", IN_TRANSIT = "On a transfer", STAGED = "Staged for delivery", DELIVERED = "Delivered", RETURNED = "Returned", QUARANTINE = "In quarantine", DAMAGED = "Damaged", MISSING = "Missing", VOID = "Voided"). Voided units show void reason, who, when.
- Product name and SKU, current location name, condition (disposition).
- Assigned customer: if `assigned_requirement_id` is set, follow requirement to journey to customer and show name plus a link to the journey. If DELIVERED, use `delivered_journey_id` the same way. If neither, show nothing (no "unassigned" warning; tool, not the boss).
- Purchase order link if `purchase_order_line_item_id` is set.
- History: all `unit_events` for the unit, oldest first, ordered by `created_at` then `id`. Each row: date and time (company timezone), plain-English description built from event_type, from_status, to_status, from/to location names, and actor name. Unknown event types render as the raw type, never crash. Never show raw JSON.

**B. Discrepancies.** A second section (tab or collapsible), shown ONLY if the caller has permission `units.manage_settings` (use the existing permission hook/pattern the app uses for other `has_permission` gates; do not hard-code roles). Calls `supabase.rpc('get_unit_discrepancies', { p_company_id })` with the signed-in employee's company. Columns: product name and SKU, location name, condition, "Units say" (units_on_hand), "Stock says" (mirror_on_hand), difference, and reserved units vs committed. Empty result: "Units and stock agree." plus one line: "Only products with Unit ID turned on are checked." Read-only. No fix buttons. Explain in one sentence under the title what a difference means (the unit list and the stock count disagree and someone should look), without alarming wording. Permission error from the RPC shows a calm message, not a stack trace.

**C. Rules to follow (lessons from the last two UI bugs):**
- Keyed loading / ready / failed state for every async block; no flash of the empty message before data arrives; every fetch has a catch; unmount guard on async effects.
- No control-type swaps in one JSX slot.
- Do not read `unit_counters` or call any revoked function from the client. The page may only read `units`, `unit_events`, `products`, `stores`, `employees`, `journey` tables the app already reads, and call `get_unit_discrepancies`.
- No new settings UI in this stage (tracked flag, assignment mode and set mode screens are a later slice).

## Part 3: test seed (so we can see the page)
Write `scripts/unit_s1_seed_demo.sql` as a SINGLE paste for the Supabase editor ending in ONE select:
- Picks the TBM company, one existing mattress product, one store. Marks that product `unit_tracked = true`.
- Creates 3 units with `create_unit`, mirrors the stock by inserting/incrementing the matching `inventory_positions` row by 3 (the receiving wrapper does this in S2; here we do it by hand so units and stock agree), moves one unit to RESERVED against an existing requirement if one exists (skip cleanly if none), and moves one to MISSING with the normal `move_unit` (which takes 1 off stock itself).
- Includes a clearly separated CLEANUP file `scripts/unit_s1_seed_demo_cleanup.sql` that reverses it: disables the two unit_events triggers, deletes the demo units and their events and ledger rows and counters, restores the stock numbers it changed, sets the product flag back, re-enables the triggers, ends with one select of leftover counts. The demo data must be identifiable (store the demo unit ids in a temp table inside the script and print them in the final select so Zach can note them).
- Header comment: "DEMO ONLY. Never run against a real client."

## Report back (plain text, no tables of file contents)
- `git diff --stat` and commit hash.
- Screens: describe what each state looks like (idle, found, not found, failed, discrepancy empty, discrepancy with rows).
- List every table/RPC the page reads, so I can check nothing off-limits is touched.
- Anything you could not verify. Do NOT merge. Do not start S2.
