# Unit ID S1 Stage 2: review fixes (branch unit-s1, on top of 8242576)

Migrations 102 and 103 and the page structure are fine. Fix the items below. Do not merge. Do not start S2.

## A. Three files attached to this message: save them verbatim, do not edit
- `scripts/unit_s1_check.sql` (the 81-check real-database test; new file)
- `scripts/unit_s1_seed_demo.sql` (replaces yours)
- `scripts/unit_s1_seed_demo_cleanup.sql` (replaces yours)

Why I replaced the seed scripts: yours kept the demo ids in a temp table, which does not survive between two separate Supabase editor runs, so the cleanup could not have worked. It also picked a real product and added 3 to real stock. The replacements use their own throwaway product (sku DEMO-UNIT-1), touch nothing real, and the cleanup also resets the unit number counter so TBM numbering does not start at 4. They are tested.

## B. Units page fixes (`app/units/page.tsx`, `components/Sidebar.tsx`)
1. **No nav link exists.** Your Sidebar diff only imports the `Tag` icon. Add the actual "Units" item linking to `/units`, placed next to Inventory, visible to every signed-in employee.
2. **History flashes "No history yet." while loading and hides errors.** Give history its own keyed state (loading / ready / failed). Loading shows "Loading history..." only. A failed fetch shows "History could not be loaded." with a Retry button. "No history yet." only after a successful empty load. Check `error` on every query in `loadEvents` and the follow-up lookups (customer, purchase order, voided-by name); a failure in one of these must not break the card, just omit that line.
3. **Same-status events read badly** ("In stock to In stock"). In `eventLine`, when `from_status === to_status` on UNIT_MOVED, say "Condition or version changed" plus the location. Keep the raw-type fallback for unknown types.
4. **Stale lookup race.** A barcode scanner can fire two lookups fast. Add a request counter ref; every async continuation of `runLookup` (and `loadEvents`) must check it is still the latest before setting state.
5. **Input guard.** Add `maxLength={15}` to the unit number input so very long numbers cannot lose precision in `Number()` or error as out of range.
6. **Discrepancies section:**
   - Highlight the Reserved cell in amber when `units_reserved !== mirror_committed` (right now a row can show Difference 0 with nothing flagged).
   - On a failed load, show a Retry button that re-runs the fetch; reopening the section after a failure must also retry.
   - If `companyId` is null, show "Your account could not be matched to a company." instead of staying silent.
   - Use the existing `hasPermission(key)` helper from `lib/inventory/queries.ts` for the `units.manage_settings` gate instead of a raw rpc call in the page.

## Report back
Commit hash, `git diff --stat`, and a plain-text list of what changed per item above. Say plainly what you could not verify in a browser.
