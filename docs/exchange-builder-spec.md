# Devin Handoff: PillowTop Exchange Builder (MVP), v2

**Status:** DESIGN APPROVED by Zach (Oct 8, 2026, evening). v2 replaces the earlier draft. Build in the phases in Section 17, one phase per prompt. Devin cannot run SQL: every migration is read by Claude and run by Zach in Supabase, and every phase ends with a written hand-test.
**Builds on:** `docs/sleep-trial-engine.md` (ST-1 to ST-6, done), especially Section 21 (the action contract), Section 15 (exceptions), Section 17 (replacement trial rules). Where this document is more specific for exchange and return execution, it wins; where it conflicts with the Sleep Trial spec, stop and flag it.
**Not built here:** the Pricing/Tax engine (Phase 7e), the Delivery module (Phase 8), the real Refunds domain (Phase 10), reports, commissions. This MVP records the data those will need and stubs the rest on purpose.

---

## 1. Purpose

Make an eligible (or exception-approved) exchange or return actually happen, end to end, for a real customer, with correct inventory, a correct trial lineage, correct dollars on record, and a paper trail:

**The old mattress comes back, the replacement goes out as a new sale, money is settled, the old mattress is inspected and dispositioned.**

Today nothing executes: Start Exchange and Start Return are permanently disabled placeholders, approved exceptions have nothing to consume them, and neither the returned unit nor a replacement touches inventory.

## 2. Locked decisions (Zach)

| # | Decision |
|---|---|
| X1 | MVP scope. Tax is handled manually; the Pricing engine plugs in later. |
| X2 | Anyone with `sleep_trial.start_exchange` (all roles today) can start an exchange. |
| X3 | Completing needs a new permission `sleep_trial.complete_exchange`. Default grants: owner, admin. Toggleable per role in Company Settings. |
| X4 | The original mattress goes to the quarantine warehouse (Returned disposition), never directly to sellable stock. |
| X5 | Returned mattresses go through an inspection checklist, done by a warehouse employee, warehouse manager, admin, or owner. |
| X6 | Checklist steps are customizable per retailer, completed in order, with who/when recorded per step. A locked minimum cannot be removed. |
| X7 | Outcomes: sell as pre-owned, damaged or write-off, donate, dispose. |
| X8 | "Correct trial start date" is per mattress (EB-0, separate small build). |
| X9 | Exchange and return share one lifecycle. |
| X10 | Committing an exchange ends the original sleep trial: the original is treated as done whether it was night 2 or the last night. If the exchange is cancelled before the old mattress is received, the original trial reopens with its days intact. After the old mattress is received, cancel is no longer allowed. |
| X11 | The replacement is a NEW SALE: a child journey linked to the original, tagged `Exchange Sale`. It appears as its own card in the normal board stages with an "Exchange" badge and a link back. No new board state. |
| X12 | The replacement's sleep trial follows the existing replacement rule in the policy (FULL_NEW, REMAINING, FIXED, NONE). Zach's default for retailers is NONE (no new trial). EB-2 must check what TBM's published policy says and report it. |
| X13 | Commission can be earned on an exchange sale, and can be negative. MVP captures the salesperson and signed dollar amounts as data only; no commission engine exists. |
| X14 | A pre-owned mattress is its own product variant: same base SKU plus `-PO`, system-created, linked to the base product, sold from normal Prime stock. Clearance is not used. |
| X15 | Money: the old mattress's credit is a negative line on the child journey (capped so the journey never goes below zero); any credit left over is recorded as "refund owed" and paid outside the system. |
| X16 | Reports and commission calculation are NOT built. The tag, dollars, and attribution are captured so they can be. |

## 3. Responsibilities

| Sleep Trial engine (done) | Exchange Builder (this spec) |
|---|---|
| Is it allowed, fee window, fee amount, exceptions, replacement trial rule | Create the replacement sale, close the old trial, record the dollars |
| Locks the evaluation at commit | Receive the old unit into quarantine, inspect it, disposition it |
| Audit of exceptions | Milestones, My Work items, cancel and completion rules |

The engine never moves stock or money. The Exchange Builder never decides eligibility; it calls the evaluator.

---

## 4. Design

Two pieces, tied together:

- **Exchange record** (`sleep_trial_actions`): owns the old-mattress side (trial item, receiving, inspection), the dollars, the link to the child journey, and the audit trail.
- **Child journey**: owns the replacement side as an ordinary journey (reservation, delivery, trial creation, board card, My Work). Devin's investigation confirmed these all work on a second journey unchanged.

| # | Decision | Why |
|---|---|---|
| B1 | The original journey is never edited (its line items are frozen after delivery). | Migration 076. |
| B2 | The replacement is created by a security-definer RPC as a new row in `sleep_journeys` for the same customer, with new columns `parent_journey_id`, `exchange_action_id`, and `sale_kind` (`STANDARD` default, `EXCHANGE`). | No journey type or link exists today. The tag is queryable by future reports. |
| B3 | No new journey_state and no new board column. | A new state means editing about a dozen hardcoded state lists (trial binding, balance logic, shortage release, list_ready_journeys, trial auto-complete). Too risky for no gain: the card already moves through the real stages. |
| B4 | Never use `delivery_completed` or `delivered_at` on the ORIGINAL journey. The child journey uses them normally. | The delivered_at trigger recomputes trial items on its own journey. |
| B5 | Commit holds stock because the child is created as Sold and the existing reservation engine reserves it. Every held exchange shows in My Work and flags when stale. | "Anyone can start" must not strand stock. |
| B6 | Money is stored as signed integer cents fields on the exchange record, mirrored by lines on the child journey. | Reports need real numbers, not notes. |
| B7 | The inspection checklist is a company process setting, snapshotted per inspection. It supersedes the unused `inspection.*` policy fields. | Not part of the customer's deal. |
| B8 | The returned unit leaves quarantine ONLY through the inspection Finish RPC. | Closes the Returned to Clearance to Prime path in practice (see 11.6). |

---

## 5. Lifecycle

### 5.1 Exchange record states

```
DRAFT --commit--> COMMITTED --(milestones)--> COMPLETED
DRAFT --discard--> CANCELLED
COMMITTED --cancel (only before original received AND before replacement delivered)--> CANCELLED
```

### 5.2 Milestones (exchange)

| Milestone | How it is set |
|---|---|
| Replacement reserved | Derived from the child journey's requirement (ready) |
| Replacement delivered | Derived from the child journey's `delivered_at` (normal Mark Delivered) |
| Original received | `receive_returned_unit` (Section 10) |
| Money settled | Derived: child journey paid in full (if it has a balance), AND, if `refund_owed_cents` > 0, a refund record exists (Section 8) |

All of "Replacement delivered", "Original received", "Money settled" are required to Complete. "Reserved" is informational. Order does not matter.

Returns (no replacement): milestones are "Original received" and "Money settled" (refund recorded).

### 5.3 Trial item effects

| Event | Original trial item | Replacement |
|---|---|---|
| Commit | ACTIVE to EXCHANGE_IN_PROGRESS (RETURN_IN_PROGRESS for returns). The trial counts as done from this moment. | Child journey created at Sold. Line item flagged so the ordinary SALE trial binding does NOT fire (B-trial rule, Section 7.4). |
| Cancel (before original received) | back to ACTIVE; clock never stopped because it derives from `started_on`; consumed exception NOT restored | child journey cancelled through the normal cancel path; stock released |
| Child delivered | unchanged | if the replacement rule gives a trial: trial item created via bound_reason REPLACEMENT with `lineage_root_id`, `predecessor_item_id`, `exchange_sequence + 1`, `started_on` = child delivery date, `fee_basis_cents` = replacement price. If the rule is NONE: no trial item, line marked `trial_ineligible_reason` (EXCHANGE_NO_NEW_TRIAL). |
| Complete | CLOSED, close_reason EXCHANGED (RETURNED for returns) | stays as is |

If the REMAINING rule applies, the remaining nights are frozen at commit.

### 5.4 Definitions

- **Start** (anyone with `sleep_trial.start_exchange`): open the Exchange Builder, pick the replacement, preview money. Creates a DRAFT. Nothing reserved, nothing created on the board.
- **Commit** (same permission): calls `commit_sleep_trial_action`. Re-evaluates, verifies the exception, locks evaluation and fee, moves the trial item to EXCHANGE_IN_PROGRESS, creates the child journey.
- **Complete** (`sleep_trial.complete_exchange`, default owner and admin): all required milestones done; closes the original item; finishes lineage.

Returns use `sleep_trial.start_return` to start and commit and the same `complete_exchange` permission to complete (rename the label to "Complete exchanges and returns").

### 5.5 What happens to the original journey

The original journey stays in its current state while the exchange is in progress. When the original item closes at Complete and no other active trial items remain, the journey completes normally. The trial auto-complete job (Sleep Trial to Completed when nights are up) must not break an in-progress exchange: RPCs must not require the original journey to be in Sleep Trial state. Devin reports how the auto-complete interacts with an EXCHANGE_IN_PROGRESS item before coding.

---

## 6. Exceptions integration

- Commit consumes the exception through `stv_consume_trial_item_exception` (types such as EARLY_EXCHANGE, EXPIRED_EXCHANGE, EXTRA_EXCHANGE, FEE_WAIVER, RETURN_NOT_ALLOWED, RETURN_APPROVAL, EXPIRED_RETURN). Today it is only called for EXTEND_TRIAL; EB-1 wires it for exchange and return.
- Staleness: the facts hash is recomputed at commit. A changed fee basis, or a replacement the approver limited to another product, returns STALE and blocks commit with the re-request message.
- A fee waiver changes `locked_fee_cents`; `financial_impact_cents` is written on the exception at consumption.
- Cancel never restores a consumed exception. The user is told this before cancelling.

## 7. Replacement as a child journey

### 7.1 Creation (at commit, one atomic security-definer RPC)

- Same `customer_id`. `store_id` = the starter's active store. `assigned_employee_id` = the starter (this is the sale attribution for commission data).
- `fulfillment_type` from the builder (delivery or pickup). The customer already has an address if the original was a delivery; the existing delivery-address guard still applies.
- Do NOT emit `quote_sent` and do NOT create a deposit follow-up (no quote noise). The required-deposit policy must not apply to an exchange journey; Devin confirms how `calculate_required_deposit` is bypassed (the balance is the difference only).
- Line items (flagged `exchange_action_id`):
  1. Replacement mattress at `replacement_price_cents` (quantity 1; a split king pair is two lines).
  2. "Exchange fee" at `+locked_fee_cents` (only if fee > 0).
  3. "Credit: returned [item]" at `-min(original_credit_cents, replacement + fee)`. Never below zero total.
  4. "Other fees" at `+other_fees_cents` (only if > 0).
- The journey price then equals `max(0, net)`; any leftover credit is `refund_owed_cents` on the exchange record (Section 8). Line `unit_price` has no CHECK, so negative lines are allowed, but nobody has used one yet: Devin must verify the `sync_journey_price` trigger, the UI line list, and every price/balance display with a negative line, and report before relying on it.
- Created directly in Sold: if price > 0, the customer pays the difference through the normal Record Payment on the child journey; if price = 0, `reevaluate_journey_balance` moves it to Sold without a payment. Devin must report the exact safe mechanism for creating a Sold journey without a payment event (the DB does not validate event order today; do not rely on a hole; use a security-definer RPC and document it).

### 7.2 Inventory (reused, not rebuilt)

At Sold the existing reservation engine creates and reserves the requirement (all-or-nothing, FIFO, advisory locks). Wake-up on receipts (078), the shortage override and follow-ups (084), the Ready to Schedule My Work item (082/083), and deduction on delivery (081) all work on the child unchanged. The credit line has no product and creates no requirement. The 084 reconcile already handles the child because it is an undelivered journey.

### 7.3 Delivery

The child is scheduled and marked Delivered through the normal Schedule Delivery and Mark Delivered flow. No separate "mark replacement delivered" button exists. A trigger or function syncs `replacement_delivered_on` onto the exchange record for display and audit.

### 7.4 Trial binding guard (important)

The ordinary SALE binding trigger (069) fires when a journey reaches Sold and would give the replacement a brand new standard trial. Under X12 (default NONE) that is wrong. The exchange RPC must flag the replacement line (`trial_ineligible_reason`) before the journey reaches Sold, or the binding function must skip lines carrying `exchange_action_id`. When the replacement rule does give a trial, binding happens at child delivery through a new security-definer wrapper for bound_reason REPLACEMENT (the existing function is revoked from clients), governed by the ORIGINAL item's policy version, resolved against the replacement product. Devin reports which approach is safest before coding.

### 7.5 Cancel

Cancel is allowed only while COMMITTED, the original is not received, and the replacement is not delivered. It cancels the child journey through the existing cancel path (stock released). If the child already has a SUCCEEDED payment, cancel is blocked with a message (a manager resolves the payment first; there is no refund path yet). The original item returns to ACTIVE.

---

## 8. Money (MVP)

All values integer cents, stored on the exchange record. Signed: positive means the customer owes, negative means the store owes.

| Field | Source |
|---|---|
| `original_credit_cents` | `fee_basis_cents` of the original trial item (read only) |
| `exchange_fee_cents` | locked evaluation (changes only through an approved fee waiver) |
| `replacement_price_cents` | defaults to the replacement's effective price (`getEffectivePrice`, sale-aware); editable by `complete_exchange` holders with a required reason |
| `other_fees_cents` | manual, labeled |
| `net_cents` | replacement + fee + other - credit (signed) |
| `refund_owed_cents` | max(0, -net) |
| `tax_cents` | manual entry, labeled "enter manually; tax engine not built yet". Recorded on the exchange only; NOT on the journey. |
| `commission_basis_cents` | = net_cents, signed (negative on a downgrade). Captured for the future commission engine. |
| `sale_attribution_employee_id` | the starter |

- Positive difference: collected on the child journey with the normal Record Payment. The UI tells the user to collect tax separately per the tax field.
- Refund owed (cheaper replacement, or any return): the UI states "PillowTop records the refund. Issue it in your payment system." A `complete_exchange` holder records method (card, cash, check, store credit, none), amount, reference, recorded by, recorded at. This satisfies the "Money settled" milestone. There is no refund payment event.
- Downgrade handling follows policy `exchange.downgrade_difference` (refund, store credit, not refunded); shown as the instruction.
- Plug-in points are labeled for Phase 7e (tax, pricing) and Phase 10 (refunds).

**Reporting note (read before building reports later):** `written_sales` is created only from a SUCCEEDED positive payment, one row per journey, with `qualifying_order_amount` = the journey price. For an exchange journey that is only the difference, and a zero or credit exchange creates no row. So future reports must read `sale_kind` and the exchange record (replacement price, credit, fee, net, commission basis), not `written_sales`, to count exchange sales and returns. No reports UI or commission code exists today.

## 9. Fulfillment

- Replacement: normal Delivery or Pickup flow on the child journey. The builder only chooses delivery vs pickup.
- Original pickup is the manual action "Mark original received" (date, location). No routing, truck, or capacity (Phase 8).
- If a customer drops the original at a store, the store records it received into that store's Returned position; a normal Transfer moves it to the quarantine warehouse. Default: the receiving location is chosen at "Mark original received".

## 10. Original mattress: receive into quarantine

`receive_returned_unit(action_id, location_id, received_on)`:
- Requires a `WAREHOUSE_QUARANTINE` sublocation at that location. If none exists, the call fails with a clear message pointing to Settings; Company Settings gets a one-click "Create quarantine area" for owner and admin (first use of the schema's quarantine type; sublocations need a `parent_location_id`).
- Upserts `inventory_positions` for (variant, location, sublocation = quarantine, disposition = `Returned`), `on_hand_quantity + 1`, committed unchanged.
- Writes a `stock_ledger_entries` row, reason `return_received`, correlation id = action id. Ledger reason is free text; no schema change.
- Creates one `returned_unit_inspections` row in AWAITING_INSPECTION.
- Idempotent per (action, unit).
- Verify in EB-4: Returned positions never count in available-to-sell (Devin found every sale-path read is Prime-only, so this should already hold).

---

## 11. Inspection checklist and pre-owned stock

### 11.1 Records

- `inspection_checklist_templates` (company): `id, company_id, outcome (ALL | PREOWNED_SELLABLE | DAMAGED_WRITEOFF | DONATE | DISPOSE), step_key, label, sort_order, required, locked, is_active`.
- `returned_unit_inspections`: `id, company_id, action_id, journey_id, trial_item_id, variant_id, location_id, sublocation_id, status (AWAITING_INSPECTION, IN_PROGRESS, COMPLETED, CANCELLED), outcome, template_snapshot jsonb, started_by/at, completed_by/at, outcome_note`.
- `returned_unit_inspection_steps`: `inspection_id, step_key, label (snapshot), sort_order, completed_by, completed_at, note`.

The template is snapshotted when the inspection starts; later edits never change history.

### 11.2 Flow

1. Step 1, always, locked: **Mattress inspection** (condition notes).
2. The inspector chooses the outcome: **Sell as pre-owned**, **Damaged or write-off**, **Donate**, **Dispose**.
3. The steps for that outcome appear. Steps must be completed in order; the server rejects out-of-order completion.
4. When all required steps are done, "Finish" applies the stock movement (11.4) and closes the inspection.

| Outcome | Default steps (locked marked L) |
|---|---|
| ALL | Mattress inspection (L) |
| PREOWNED_SELLABLE | Cleaned and sanitized (L), Tagged as pre-owned (L), optional: photos, price set |
| DAMAGED_WRITEOFF | Reason for write-off recorded (note required) |
| DONATE | Recipient recorded, optional receipt |
| DISPOSE | Method recorded |

### 11.3 Customization

`inventory.manage_inspection_checklist` (default owner, admin) can add, rename, reorder, and deactivate steps. **Locked steps cannot be deleted, deactivated, or made optional**: Mattress inspection, Cleaned and sanitized, Tagged as pre-owned. Server enforced. Reason: the paper trail that a pre-owned mattress was sanitized and labeled must not be removable (many states regulate resale of used bedding).

### 11.4 Stock movements at Finish

| Outcome | Movement |
|---|---|
| PREOWNED_SELLABLE | `-1` Returned position at quarantine; `+1` Prime on the pre-owned variant (11.5) at the warehouse that holds the quarantine area. Ledger `preowned_restock`. Requires a price (manager+). |
| DAMAGED_WRITEOFF | `-1` Returned; `+1` Damaged disposition position at the same warehouse. Ledger `damaged_writeoff` with the note. |
| DONATE | `-1` Returned; ledger `donated`, recipient in the note. |
| DISPOSE | `-1` Returned; ledger `disposed`. |

Accounting treatment of write-off, donation, and disposal is deferred; the MVP records status and reason only.

### 11.5 The pre-owned variant

- New columns on `products`: `base_product_id uuid null` (link to the base variant), `is_pre_owned boolean default false`.
- `ensure_preowned_variant(base_product_id)` (security definer, called only by Finish): finds or creates the product with SKU `<base sku>-PO` (unique per company), name `<item name> (Pre-owned)`, same brand and category, `cost` = base cost, `is_pre_owned = true`, `base_product_id` set, and `sleep_trial_eligible = false` (the per-product flag overrides the category flag). No employee ever types this SKU.
- The price is set by a manager+ at Finish and written to the product (`price`). Known MVP limit: stock is counted by quantity, not by serial unit, so two pre-owned units of the same model share one price.
- Search and ProductPicker show a "Pre-owned" badge. Reports can roll the pre-owned variant up to the base product through `base_product_id`.
- A company setting to allow a sleep trial on pre-owned is a later option (default off).
- Risk to document: the Excel import upserts on (company_id, sku); a spreadsheet row with a `-PO` SKU would overwrite the pre-owned product.

### 11.6 The quarantine guard

Devin found that the existing trigger only blocks a direct Returned to Prime update, that no code path updates dispositions, and that `adjust_inventory_position` (two calls) can still move quantity between dispositions. In this design stock leaves Returned only through Finish (a ledgered, permission-checked RPC). The two-call adjustment path is logged as a pre-launch item, not fixed here.

### 11.7 Access

An employee may inspect if they have `inventory.inspect_returns` (default owner, admin, manager) OR their home store is a warehouse (the same warehouse-based-employee rule used in Transfers). Setting the pre-owned price and Finish for PREOWNED_SELLABLE additionally need owner, admin, or manager.

### 11.8 My Work

Derived item "Mattress waiting for inspection" (no stored task), shown to employees whose active store is the unit's location plus managers, admins, and owners; disappears when the inspection completes. Older than `exchange.inspection_overdue_days` (company setting, default 7) it also appears pinned in the manager and admin view.

---

## 12. Permissions (new keys)

| Key | Label | Default grants |
|---|---|---|
| `sleep_trial.complete_exchange` | Complete exchanges and returns (settle and close) | owner, admin |
| `inventory.inspect_returns` | Inspect and disposition returned mattresses | owner, admin, manager (plus any warehouse-based employee by rule) |
| `inventory.manage_inspection_checklist` | Edit the returned mattress inspection checklist | owner, admin |

Rules: only the owner role is implicit; do not hardcode other roles; grants live in `role_permission_grants` and are toggled in Company Settings, in the "Inventory permissions" section (retitle "Inventory and exchange permissions"). `set_role_permission`'s whitelist and `seed_sleep_trial_permission_defaults` must be extended and every company backfilled, exactly as migration 085 did. Reused keys: `sleep_trial.start_exchange`, `sleep_trial.start_return`.

## 13. Data model summary (new)

- `sleep_trial_actions`: `id, company_id, journey_id, trial_item_id, action (EXCHANGE|RETURN), status, locked_evaluation jsonb, locked_fee_cents, exception_id, replacement_product_id, replacement_variant_id, replacement_quantity, replacement_price_cents, replacement_price_reason, original_credit_cents, exchange_fee_cents, other_fees_cents, tax_cents, net_cents, refund_owed_cents, commission_basis_cents, sale_attribution_employee_id, child_journey_id, fulfillment_method, replacement_delivered_on, original_received_on, original_location_id, refund_method, refund_amount_cents, refund_reference, refund_recorded_by/at, replacement_trial_item_id, concern_id, idempotency_key, created_by/at, committed_by/at, completed_by/at, cancelled_by/at, cancel_reason`.
- `sleep_journeys`: `parent_journey_id uuid null`, `exchange_action_id uuid null`, `sale_kind text not null default 'STANDARD' check in ('STANDARD','EXCHANGE')`.
- `journey_line_items.exchange_action_id uuid null` (flags the replacement, fee, credit, and other-fee lines).
- `products.base_product_id`, `products.is_pre_owned` (Section 11.5).
- `inspection_checklist_templates`, `returned_unit_inspections`, `returned_unit_inspection_steps`.
- `sleep_trial_start_corrections.trial_item_id` populated by EB-0.
- All tables tenant scoped, RLS read via existing visibility helpers, NO direct client writes; writes only through security-definer RPCs, like 062/065. New columns on existing tables must not loosen existing guards (076 frozen line items still holds for the ORIGINAL; the child's lines are created by the RPC before delivery).

## 14. RPCs (the Section 21 contract, concretely)

```
quote_sleep_trial_action(trial_item_id, action, replacement_product_id) -> evaluation + fee + replacement trial preview + money preview + stock availability (no side effects)
create_exchange_draft(trial_item_id, action, replacement_product_id, replacement_variant_id, fulfillment_method, idempotency_key) -> action_id
commit_sleep_trial_action(action_id, exception_id, idempotency_key)     -- creates the child journey for exchanges
cancel_sleep_trial_action(action_id, reason)                            -- starter or complete_exchange holder
receive_returned_unit(action_id, location_id, received_on)              -- Section 10
record_exchange_refund(action_id, method, amount_cents, reference)      -- complete_exchange holder
complete_sleep_trial_action(action_id)                                  -- complete_exchange holder
start_unit_inspection / complete_inspection_step / choose_inspection_outcome / finish_inspection / ensure_preowned_variant
```

Every RPC: checks company and visibility, checks permission server side, locks in the canonical order (journey, requirement rows, variant:location), is idempotent where marked, writes audit events, and returns a plain-English error for every blocked case. Postgres reminders: ORDER BY may reference output aliases only as bare names (the 084 bug), avoid anonymous record field access, use `array_append`, and syntax-valid is not runtime-valid.

## 15. Audit events

`EXCHANGE_DRAFT_CREATED`, `EXCHANGE_COMMITTED` (locked evaluation, fee, exception id, child journey id), `EXCHANGE_CANCELLED`, `EXCHANGE_REPLACEMENT_RESERVED`, `EXCHANGE_REPLACEMENT_DELIVERED`, `EXCHANGE_ORIGINAL_RECEIVED`, `EXCHANGE_REFUND_RECORDED`, `EXCHANGE_COMPLETED`, `EXCHANGE_PRICE_OVERRIDDEN` (old, new, reason), `RETURNED_UNIT_RECEIVED`, `INSPECTION_STEP_COMPLETED`, `INSPECTION_OUTCOME_SET`, `INSPECTION_FINISHED`, `PREOWNED_VARIANT_CREATED`, `INSPECTION_TEMPLATE_CHANGED`, `START_DATE_CORRECTED` (item level). Each also writes a short Journey Activity line on BOTH journeys ("Exchange committed by Susan R.: Purple Plus to Tempur ProAdapt, fee $359.80"). Test: for any exchange you can answer who did what, when, why, what the system originally said, and what happened to the original unit.

## 16. UX

Replaces the disabled START_EXCHANGE / START_RETURN placeholders in `SleepTrialSection.tsx`.

**Exchange Builder (side panel or modal), five steps:**
1. **Customer:** confirm the journey, the mattress (one card per trial item), the evaluator headline (night, eligible, fee).
2. **Return:** the original mattress, fee breakdown with window and source ("Why?"), exception status, protector status.
3. **Replacement:** product search (same component as elsewhere), stock at the sourcing location, replacement trial preview ("No new sleep trial under this policy" or "New 120-night trial from delivery"), size and brand rules from policy.
4. **Money:** credit, fee, replacement price, other fees, net, "customer owes" or "refund owed", tax field with the manual-entry label.
5. **Fulfillment:** delivery or pickup.
Commit is one button, disabled with the reason when blocked. The commit confirmation states plainly: "This ends the current sleep trial on this mattress. Cancel is only possible until the old mattress is received."

**Original journey:** the Sleep Trial section shows the item as "Exchange in progress" with a milestone card (Replacement reserved, Replacement delivered, Original received, Money settled, Completed), actor and date on each, and the buttons available to the current user.

**Child journey:** an ordinary board card with an "Exchange" badge and the line "Exchange of [item], Journey [link]". Its Order card shows the replacement, fee, and credit lines. It uses the normal Record Payment, Schedule Delivery, and Mark Delivered buttons.

**My Work (derived, no stored rows):** "Exchange waiting to be completed" (starter, store, managers), "Mattress waiting for inspection" (11.8), "Exchange stalled" when committed longer than `exchange.stalled_days` (company setting, default 14) with milestones unfinished. The child's Ready to Schedule and shortage items already exist and pin as today.

**Settings (Company Settings):** "Inventory and exchange permissions" grid; "Returned mattress inspection checklist" editor; "Quarantine area" status line with a one-click create; the two day-count settings.

## 17. Build sequence for Devin (one prompt each; Zach hand-tests each)

| Phase | Scope |
|---|---|
| **EB-0 Per-item start-date correction** | DONE (migration 086, main 917ee31). |
| **EB-1 Foundations (no stock, no UI)** | `sleep_trial_actions`; `sale_kind`, `parent_journey_id`, `exchange_action_id` columns; permissions seeded (and Company Settings checkboxes); `quote_sleep_trial_action`; draft create/discard; exception consumption plumbing; trial item state helpers (EXCHANGE_IN_PROGRESS, back to ACTIVE, CLOSED); audit events. Devin first reports: the TBM policy's replacement rule, how trial auto-complete interacts with EXCHANGE_IN_PROGRESS, and the mechanics from 7.1. |
| **EB-2 Commit and the child journey** | `commit_sleep_trial_action` and the child-journey RPC (lines incl. credit line, created at Sold, no quote noise, deposit bypass), trial-binding guard, replacement trial lineage at child delivery, delivered-on sync, cancel, complete (money-settled and refund record). Highest risk: line-by-line review and a full hand-test including shortage and wake-up on a child journey. |
| **EB-3 Exchange Builder UI** | Five-step builder, milestone card, board badge and link, My Work items, Complete button, Company Settings pieces. |
| **EB-4 Quarantine, receiving, inspection, pre-owned** | Quarantine creation, `receive_returned_unit`, inspection tables and RPCs, checklist editor with locked steps, outcome stock movements, `ensure_preowned_variant`, product columns and badge, inspection My Work item. |
| **EB-5 Return execution + QA** | Enable Start Return through the same lifecycle (no child journey, refund recorded), full test matrix, cross-tenant and concurrency tests. |

## 18. Acceptance criteria (GIVEN / WHEN / THEN)

**Starting and committing**
1. GIVEN an eligible mattress and a sales employee WHEN they start an exchange and choose a replacement THEN a DRAFT exists AND no journey is created AND no stock is reserved.
2. GIVEN a DRAFT WHEN committed on the last valid trial day THEN the original shows Exchange in progress AND the fee is locked AND a child journey exists in Sold with `sale_kind = EXCHANGE`.
3. GIVEN two employees commit the same item at once THEN one succeeds AND the other sees who started it.
4. GIVEN a stale approval (fee basis changed) WHEN committing THEN commit is blocked AND the approval is marked STALE.
5. GIVEN an approved fee waiver WHEN committed THEN the locked fee is 0 AND the exception records the waived amount.
6. GIVEN the evaluator returns UNKNOWN or any non-eligible status without an applied exception THEN commit is refused.
7. GIVEN a commit WHEN the original trial was on night 2 THEN the original trial is treated as done.

**Child journey and inventory**
8. GIVEN stock is available WHEN committed THEN the child's requirement is ready with `quantity_reserved = 1` AND committed increases by 1.
9. GIVEN no stock WHEN committed THEN the child shows Waiting for Inventory AND the exchange card says "Waiting for stock".
10. GIVEN a waiting exchange WHEN stock is received THEN the oldest requirement (any journey) is reserved first AND the child shows Ready to Schedule in My Work.
11. GIVEN the child is marked Delivered THEN on-hand and committed each decrease by 1 AND the ledger has a `sale_delivery` row AND the ORIGINAL journey's `delivered_at` and state are unchanged.
12. GIVEN an admin lowers stock below committed WHEN the child holds a reservation THEN the popup lists the child journey AND proceeding releases it AND creates the shortage follow-up.
13. GIVEN the replacement rule is NONE THEN the child's delivery does NOT create a sleep trial item AND no standard SALE trial was bound at Sold.
14. GIVEN the replacement rule gives a trial THEN at child delivery a trial item exists with `predecessor_item_id`, `lineage_root_id`, `exchange_sequence + 1`, and its own start date and fee basis.
15. GIVEN the REMAINING rule with 70 nights left at commit AND delivery 21 days later THEN the replacement trial is 70 nights from delivery.
16. GIVEN the child journey THEN it shows the Exchange badge AND a link to the original AND appears in the normal board stage for its state (no new column).

**Money**
17. GIVEN a more expensive replacement THEN the child journey price equals the net difference AND the customer pays it with the normal Record Payment AND the journey price is never negative.
18. GIVEN a cheaper replacement THEN a credit line caps at replacement plus fee AND `refund_owed_cents` equals the leftover AND the exchange cannot complete until a refund record exists.
19. GIVEN net is exactly zero THEN the child journey price is 0 AND it moves to Sold without a payment.
20. GIVEN an exchange THEN `net_cents`, `commission_basis_cents` (signed), `sale_attribution_employee_id`, and `sale_kind = EXCHANGE` are stored.
21. GIVEN a user without `sleep_trial.complete_exchange` THEN Complete and Record Refund are hidden or disabled with the reason.
22. GIVEN a manager and the manager checkbox on in Settings THEN Complete is available to the manager.

**Cancel and complete**
23. GIVEN a cancel before the old mattress is received THEN the child journey is cancelled AND stock is released AND the original trial item is ACTIVE with its days intact AND the consumed exception is not restored.
24. GIVEN the child has a SUCCEEDED payment WHEN cancelling THEN cancel is blocked with a message.
25. GIVEN the old mattress is received WHEN cancelling THEN cancel is refused.
26. GIVEN delivered, received, and settled all done WHEN an admin completes THEN the original item is CLOSED (EXCHANGED) AND, if no other active items remain, the original journey completes.
27. GIVEN an in-progress exchange WHEN the original journey's trial window ends THEN the auto-complete job does not break the exchange.

**Original and inspection**
28. GIVEN no quarantine area WHEN receiving the original THEN it fails with a message pointing to Settings AND an owner or admin can create the area in one click.
29. GIVEN a quarantine area WHEN the original is received THEN a Returned position increases by 1 AND the ledger has `return_received` AND an inspection exists AND the unit is not available for sale.
30. GIVEN an inspection WHEN steps are completed out of order THEN the server rejects it.
31. GIVEN the Pre-owned path WHEN Cleaned and sanitized or Tagged as pre-owned is incomplete THEN Finish is blocked.
32. GIVEN a retailer tries to delete or make optional a locked step THEN the server refuses.
33. GIVEN an inspection started with checklist version A WHEN the template is later edited THEN the inspection still shows version A.
34. GIVEN a warehouse-based employee with any role THEN they can complete a waiting inspection AND a retail-store sales employee cannot.
35. GIVEN outcome Donate or Dispose THEN the Returned position decreases by 1 AND no sellable stock is created.
36. GIVEN outcome Sell as pre-owned and a manager sets a price THEN a `-PO` product exists linked to the base product with `sleep_trial_eligible = false` AND its Prime stock increases by 1 AND the original unit left Returned AND it can be sold from the normal ProductPicker with a Pre-owned badge.
37. GIVEN a unit waiting longer than the configured days THEN it appears in the manager and admin My Work view.

**Safety**
38. GIVEN any exchange or inspection table WHEN a client writes directly THEN it is refused.
39. GIVEN cross-company ids WHEN calling any RPC THEN it is refused.
40. GIVEN a stalled committed exchange THEN it appears in My Work after the configured days.

---

## 19. Open items and defaults

Decided by Zach: everything in Section 2.

Proceed on these defaults unless Zach objects:
- Day counts: exchange "stalled" after 14 days; inspection "overdue" after 7 days; both company settings.
- Child journey `store_id` = starter's active store; assigned employee = starter.
- Replacement price defaults to the effective (sale-aware) price; editing needs `complete_exchange` and a reason.
- Tax is recorded on the exchange only, never on the child journey.
- No photo requirement on inspection in the MVP; no Return to Vendor outcome; write-off, donate, dispose affect stock and status only.
- Warranty replacements are separate and out of scope.
- Written sales for exchange journeys: leave the existing behavior; reports read the exchange record (Section 8 note).

Later: real tax and price-difference math (7e), refund payments (10), delivery routing (8), customer notifications, photos and signatures on inspection, vendor returns, per-unit pre-owned pricing, sleep trial on pre-owned as a company option, commission engine, reports and return-rate dashboards.

Pre-launch items found during this design (logged in the roadmap Go-Live Gate): (1) any authenticated user can insert most journey events directly and the database does not validate event order; (2) `adjust_inventory_position` can move quantity between dispositions in two calls; (3) the Excel import can overwrite a product with a colliding SKU.

---

## 20. Appendix: investigation facts (Devin, Oct 8, read from the repo, not the live database)

- Clearance stock is invisible to the whole sale path: `evaluate_journey_inventory`, reservations, deduction, counts, transfers, and POs read `disposition = 'Prime'` and `sublocation_id is null` only; no UI shows Clearance stock.
- `sold_condition` on line items is never written, so CONDITION policy overrides never match.
- A product variant with its own SKU works across all inventory machinery; there is no link column today (added here).
- Trial eligibility is `coalesce(product.sleep_trial_eligible, category.sleep_trial_eligible, false)`.
- No parent/child journey concept exists. Journey creation is plain client-side inserts today; payments are separate (`record_payment_event`, amount > 0). A zero-price journey moves Quoted to Sold through `reevaluate_journey_balance` but creates no `written_sales` row.
- A second journey linked to a delivered one works unchanged for reservation, delivery, delivery_completed, and trial binding. Binding reason REPLACEMENT is revoked from clients.
- Nothing sets EXCHANGE_IN_PROGRESS, CLOSED, or close_reason EXCHANGED today; the Section 21 RPCs do not exist in any migration.
- No commission code, no reports UI, no delivery calendar. The board has six fixed state columns.
- Not verified: live database state vs migration files; every comparison site for a mid-enum state addition (not needed, no new state).

## 21. Self-review

| Question | Answer |
|---|---|
| Can Devin implement without guessing a major rule? | Yes. Every decision is locked or defaulted. Devin must report specific mechanics (Section 5.5, 7.1, 7.4) before coding EB-1 and EB-2. |
| Does it protect trial history and inventory? | Yes: the original journey is never edited, original delivered_at is never touched, stock moves only through existing idempotent paths plus ledgered RPCs, every step audited. |
| Riskiest piece? | EB-2: creating a Sold journey with negative lines without a payment event, and keeping the standard trial binding from firing. Both are called out for verification before coding. |
| What is deliberately stubbed? | Tax, refund payments, commission calculation, reports, delivery routing, per-unit pre-owned pricing. |
| What would be expensive to retrofit? | Handled now: `sale_kind` and parent link, signed dollar fields, `base_product_id`, lineage on trial items, inspection snapshots, quarantine as a real location, permission keys, audit events. |
