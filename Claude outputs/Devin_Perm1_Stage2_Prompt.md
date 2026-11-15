# PERM-1 Stage 2: "Extra permissions" on the employee screen (UI only)

Continue on branch `perm-1` (on top of 1079f19). Migrations 104 and 105 are installed and passed a 41-check real-database test, so the database side is DONE: do not touch migrations. Do not merge. When pushed, tell me; I will say "go" before you switch the :3000 server to this branch.

## What to build
1. **Shared key list.** Extend `lib/sleepTrial/permissions.ts` (or move to a shared file if cleaner, keeping existing imports working) so it includes every key `is_valid_permission_key` accepts, each with a plain-English label and a group. Add: `units.assign` "Assign units to customer orders", `units.unassign` "Unassign units from orders", `units.override_set` "Set aside an in-stock unit for an order (override a set)", `units.swap` "Swap a unit on an order for another unit", `units.void` "Void a unit", `units.manage_settings` "Manage Unit ID settings and view the discrepancy report", `inventory.receive_po` "Receive purchase orders". Groups: Sleep trial, Inventory, Unit ID. The existing role grid (`SleepTrialPermissionsGrid`) must also show the new keys so the role defaults can be changed there; check it still renders correctly and that nothing else in the app enumerates this list in a way the new keys break.
2. **Extra permissions section** in the employee edit form (`components/EmployeeManagement.tsx`), visible only to owner/admin viewers. For the employee being edited:
   - Read their rows from `employee_permission_overrides` (RLS lets owner/admin read their company's rows) and the role's grants from `role_permission_grants` for that employee's role (the way the existing grid reads grants).
   - Show every key grouped, one row per key: the label, the role default as plain text ("Role allows" / "Role does not allow"), and a single stable `<select>` with three options: "Use role default", "Always allow", "Never allow". The select's value reflects the override (none / granted / denied). Next to a row that has an override, show a small "Custom" tag.
   - Changing a select immediately calls `supabase.rpc('set_employee_permission', { p_employee_id, p_key, p_granted })` where p_granted is `true`, `false`, or `null` for "Use role default". Disable that row's select while the call is in flight, show a short "Saved" confirmation on success, and show the database's error message under the row on failure, restoring the previous value. No optimistic update that can lie.
   - Plain-English line at the top of the section: "These apply to this person only, on top of their role. Use them when someone does a job their role does not normally cover, like receiving purchase orders."
   - If the employee being edited is an Owner, do not show the controls; show "Owners always have every permission."
   - Keyed loading / ready / failed states for the section; a fetch error shows a Retry; no flash of empty content; unmount guard on async effects; no control-type swaps in one JSX slot.
3. **Employee list badge.** In the employee list, owner/admin viewers see a small tag "N custom permissions" on any employee who has overrides (one query for the company's override rows, counted per employee). Non-admin viewers see nothing. A failed fetch must not break the list.

## Rules
- Read only `employee_permission_overrides`, `role_permission_grants`, `employees` and call only `set_employee_permission`. No writes to tables from the client.
- Do not hard-code roles for the permission gate beyond what the existing page already does for who may see employee management; the database enforces the rest.
- No new migrations. No changes to has_permission callers.

## Report back
Commit hash, `git diff --stat`, plain-text list of what changed per item, every table/RPC the new code touches, and anything you could not verify in a browser. Do not start S2 of Unit ID.
