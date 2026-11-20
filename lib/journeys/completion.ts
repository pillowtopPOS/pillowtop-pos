import { localTodayISO } from "@/lib/dates";
import {
  STATE_TRANSITIONS,
  transitionAppliesToFulfillment,
  type StateTransition,
} from "@/lib/journeys/state";
import type { SleepJourneyState } from "@/lib/constants";

// Completion (Mark Delivered / Mark Picked Up) goes through the
// complete_journey_fulfillment RPC, never a raw journey_events insert.
// These helpers keep the dialog's date/reason decisions pure so they
// can be unit tested without a browser or database.

// The date field only exists for users holding orders.backdate_fulfillment.
export function completionShowsDateField(canBackdate: boolean): boolean {
  return canBackdate;
}

// A reason is required only when the chosen date is earlier than today.
// Dates compare as YYYY-MM-DD strings, which sort chronologically.
export function completionNeedsReason(
  completedOn: string,
  today: string
): boolean {
  return !!completedOn && completedOn !== today && completedOn < today;
}

// complete_journey_fulfillment requires a backdate reason of at least
// 3 trimmed characters. The Confirm button and buildCompletionRequest
// share this one rule so they can never disagree.
export const COMPLETION_REASON_MIN = 3;

export function completionReasonMet(
  reason: string | null | undefined
): boolean {
  return (reason ?? "").trim().length >= COMPLETION_REASON_MIN;
}

export type CompletionRequest = {
  // Null means "today in the store's time zone"; the RPC resolves it.
  completedOn: string | null;
  reason: string | null;
  error?: string;
};

// Decides what to send to complete_journey_fulfillment. A date is sent
// only when the user picked one that differs from today; today is always
// null so the store's time zone decides. The database re-checks every
// rule and its plain-English errors are shown as returned, so this only
// guards the reason requirement and the no-permission case.
export function buildCompletionRequest(opts: {
  canBackdate: boolean;
  today?: string;
  completedOn?: string | null;
  reason?: string | null;
}): CompletionRequest {
  const today = opts.today ?? localTodayISO();
  const chosen = (opts.completedOn ?? "").trim();
  const reason = (opts.reason ?? "").trim();

  if (!chosen || chosen === today) {
    return { completedOn: null, reason: null };
  }
  if (!opts.canBackdate) {
    return {
      completedOn: null,
      reason: null,
      error:
        "Only an owner, admin or manager can record an earlier date. Use today's date.",
    };
  }
  if (chosen < today && !completionReasonMet(reason)) {
    return {
      completedOn: null,
      reason: null,
      error: "Enter a reason for the earlier date.",
    };
  }
  return { completedOn: chosen, reason: reason || null };
}

// ---------------------------------------------------------------------------
// Slice 1.5: completion lives inside the order panel. The board card button
// and drag path are gone; these helpers decide which completion control the
// panel may show and what the dialog lists. Pure so they unit test cleanly.
// ---------------------------------------------------------------------------

export const COMPLETION_DRAG_MESSAGE =
  "Open the order and use its button to mark it picked up or delivered.";
export const DELIVERY_FINALIZE_NOTE =
  "Deliveries are finalized by the warehouse team";
export const OTHER_ITEMS_STAY_OPEN_NOTE =
  "The other items on this order stay open.";
export const COMPLETION_COMPLETED_MESSAGE =
  "Done. This order has no sleep trial, so it is complete and has left the board.";
export const COMPLETION_NOT_IN_STOCK_LINE =
  "Some items are not in stock yet. This cannot be completed until they are.";

export type CompletionLineItem = {
  id?: string;
  quantity?: number;
  fulfillment_type_override?: "delivery" | "pickup" | null;
  pickup_location_id?: string | null;
};

// Units left to hand over on a line. Callers pass the fulfillment
// summary's byLine map; an absent map means nothing is known handed
// over yet (pre-slice-2a callers).
export function remainingUnits(
  item: CompletionLineItem,
  handed?: Record<string, number>
): number {
  const qty = item.quantity ?? 1;
  const out = item.id ? handed?.[item.id] ?? 0 : 0;
  return Math.max(qty - out, 0);
}

export function effectiveLineFulfillment(
  item: CompletionLineItem,
  orderFulfillment: "delivery" | "pickup"
): "delivery" | "pickup" {
  return item.fulfillment_type_override ?? orderFulfillment;
}

// Pickup location of one line: its own pickup_location_id, else the
// order's store (mirrors the RPC's coalesce(li.pickup_location_id, store_id)).
export function linePickupLocationId(
  item: CompletionLineItem,
  journeyStoreId: string
): string {
  return item.pickup_location_id ?? journeyStoreId;
}

// Distinct pickup locations across the order's pickup-effective lines.
// With no pickup-effective lines the order's own store is the place,
// matching the RPC's union fallback for empty orders.
export function pickupLocationIds(
  items: CompletionLineItem[],
  journey: { store_id: string; fulfillment_type: "delivery" | "pickup" }
): string[] {
  const ids = new Set<string>();
  for (const item of items) {
    if (
      effectiveLineFulfillment(item, journey.fulfillment_type) === "pickup"
    ) {
      ids.add(linePickupLocationId(item, journey.store_id));
    }
  }
  if (ids.size === 0) ids.add(journey.store_id);
  return Array.from(ids);
}

// "A", "A and B", "A, B and C", same joining style as pickupCollectionLabel.
export function joinLocationNames(names: string[]): string {
  if (names.length <= 1) return names[0] ?? "";
  return `${names.slice(0, -1).join(", ")} and ${names[names.length - 1]}`;
}

// Shown whenever a pickup line belongs to a location the signed-in user
// is not working in today. completionButtonDecision and the per-item
// handover dialog share this exact wording.
export function pickupLocationNote(names: string[]): string {
  return `Set for pickup at ${joinLocationNames(names)}. Only employees at that location can mark it picked up.`;
}

export type CompletionButtonDecision =
  | { kind: "button"; fulfillment: "pickup" | "delivery" }
  | { kind: "note"; text: string }
  | { kind: "hidden" };

// Which completion control the order panel shows. Mirrors m149:
//   delivery -> can_finalize_delivery() only (store staff never finalize);
//   pickup   -> orders.mark_fulfilled, plus every pickup line leaving the
//               active location unless orders.pickup_any_location.
// Slice 2a: the button hands over every REMAINING unit on the lines whose
// effective method equals the order's type (the wrapper RPC's selection).
// Lines of the other method never block the button, and an order with no
// same-method units left shows no control at all.
export function completionButtonDecision(opts: {
  // The method this control would act on.
  fulfillment: "delivery" | "pickup";
  // The order's own fulfillment type, which supplies the default effective
  // method for lines without an override. Defaults to `fulfillment`,
  // which covers orders evaluated for their own method.
  orderFulfillment?: "delivery" | "pickup";
  canMarkFulfilled: boolean;
  canPickupAnyLocation: boolean;
  canFinalizeDelivery: boolean;
  // user_metadata.active_store_id falling back to the employee's home store,
  // resolved by the caller exactly like the RPC does.
  activeStoreId: string | null;
  items: CompletionLineItem[];
  journeyStoreId: string;
  storeName: (id: string) => string | null;
  // Units already handed over, keyed by line_item_id
  // (fetchJourneyFulfillmentSummary's byLine). Omitted means "none handed
  // over yet".
  handed?: Record<string, number>;
}): CompletionButtonDecision {
  const orderType = opts.orderFulfillment ?? opts.fulfillment;
  const openLines = opts.items.filter(
    (i) => remainingUnits(i, opts.handed) > 0
  );
  const sameMethodOpen = openLines.filter(
    (i) => effectiveLineFulfillment(i, orderType) === opts.fulfillment
  );
  // Nothing left to hand over on the order's own method: no button, no
  // note. Other-method remnants belong to the handover dialog. An order
  // with no lines at all keeps its control: the wrapper delegates to the
  // legacy whole-order function for those.
  if (opts.items.length > 0 && sameMethodOpen.length === 0) {
    return { kind: "hidden" };
  }

  if (opts.fulfillment === "delivery") {
    return opts.canFinalizeDelivery
      ? { kind: "button", fulfillment: "delivery" }
      : { kind: "note", text: DELIVERY_FINALIZE_NOTE };
  }

  if (!opts.canMarkFulfilled) return { kind: "hidden" };

  const journey = {
    store_id: opts.journeyStoreId,
    fulfillment_type: orderType,
  };
  const locIds = pickupLocationIds(openLines, journey);

  if (!opts.canPickupAnyLocation) {
    const active = opts.activeStoreId;
    if (!active || locIds.some((id) => id !== active)) {
      const names = locIds
        .map((id) => opts.storeName(id))
        .filter((n): n is string => !!n);
      return {
        kind: "note",
        text: pickupLocationNote(names),
      };
    }
  }

  return { kind: "button", fulfillment: "pickup" };
}

// Lines whose units the completion button hands over now: order's own
// method with at least one unit left. Mirrors the m157 wrapper's line
// selection.
export function completionHandoverLines<T extends CompletionLineItem>(opts: {
  fulfillment: "delivery" | "pickup";
  items: T[];
  handed?: Record<string, number>;
}): T[] {
  return opts.items.filter(
    (i) =>
      effectiveLineFulfillment(i, opts.fulfillment) === opts.fulfillment &&
      remainingUnits(i, opts.handed) > 0
  );
}

// Whether this completion closes the order: every remaining unit on the
// order is in the same-method set being handed over now. False means
// other-method units stay open and the journey keeps its current state.
export function completionClosesOrder(opts: {
  fulfillment: "delivery" | "pickup";
  items: CompletionLineItem[];
  handed?: Record<string, number>;
}): boolean {
  return opts.items.every(
    (i) =>
      effectiveLineFulfillment(i, opts.fulfillment) === opts.fulfillment ||
      remainingUnits(i, opts.handed) === 0
  );
}

// Per-line state for the pickup steppers in the completion dialog. A
// line is editable only when the signed-in employee may take units from
// its pickup location and its requirement is not still pending. Locked
// and out-of-stock lines count as zero everywhere: the stepper, the
// total, and the payload sent to the RPC.
export type CompletionStepperLine = {
  remaining: number;
  locId: string;
  locationLocked: boolean;
  outOfStock: boolean;
  editable: boolean;
};

export function completionStepperLine(
  item: CompletionLineItem & { product_id?: string | null },
  journeyStoreId: string,
  opts: {
    handed?: Record<string, number>;
    reqStatus: Record<string, string>;
    canPickupAnyLocation: boolean;
    activeStoreId: string | null;
  }
): CompletionStepperLine {
  const remaining = remainingUnits(item, opts.handed);
  const locId = linePickupLocationId(item, journeyStoreId);
  const locationLocked =
    !opts.canPickupAnyLocation && locId !== opts.activeStoreId;
  const tag = item.product_id
    ? completionStockTag(opts.reqStatus[item.product_id])
    : null;
  const outOfStock = tag === "not_in_stock";
  return {
    remaining,
    locId,
    locationLocked,
    outOfStock,
    editable: !locationLocked && !outOfStock,
  };
}

// Lines of the dialog's method with units still left to hand over, on
// an order of type `orderFulfillment`. completionHandoverLines takes a
// single type; this variant separates the order's default method from
// the method being acted on so mixed orders are handled correctly.
export function completionMethodLines<T extends CompletionLineItem>(opts: {
  orderFulfillment: "delivery" | "pickup";
  method: "delivery" | "pickup";
  items: T[];
  handed?: Record<string, number>;
}): T[] {
  return opts.items.filter(
    (i) =>
      effectiveLineFulfillment(i, opts.orderFulfillment) === opts.method &&
      remainingUnits(i, opts.handed) > 0
  );
}

// Lines with remaining units whose effective method (under the order's
// own type) differs from the method the dialog is acting on. While this
// is true the dialog shows OTHER_ITEMS_STAY_OPEN_NOTE.
export function otherMethodItemsRemain(opts: {
  orderFulfillment: "delivery" | "pickup";
  method: "delivery" | "pickup";
  items: CompletionLineItem[];
  handed?: Record<string, number>;
}): boolean {
  return opts.items.some(
    (i) =>
      effectiveLineFulfillment(i, opts.orderFulfillment) !== opts.method &&
      remainingUnits(i, opts.handed) > 0
  );
}

// Whether the chosen quantities close the order: no other-method units
// remain and every same-method line is leaving in full. A partial pickup
// choice keeps the order open. For delivery the chosen map is always the
// full remaining set, matching completionClosesOrder.
export function completionClosesWithChoice(opts: {
  orderFulfillment: "delivery" | "pickup";
  method: "delivery" | "pickup";
  items: CompletionLineItem[];
  handed?: Record<string, number>;
  // Units the dialog will hand over per line id.
  chosen: Record<string, number>;
}): boolean {
  return opts.items.every((i) => {
    const rem = remainingUnits(i, opts.handed);
    if (rem === 0) return true;
    if (effectiveLineFulfillment(i, opts.orderFulfillment) !== opts.method) {
      return false;
    }
    return (i.id ? opts.chosen[i.id] ?? 0 : 0) >= rem;
  });
}

// Per-line status text for the order summary. "done" renders green,
// "part" plain, "open" amber. Returns null when nothing should render:
// the line is untouched and no unit on the order has left yet.
export function lineStatusText(opts: {
  handed: number;
  quantity: number;
  method: "pickup" | "delivery";
  // Pre-formatted short date like "Nov 19", from the line's latest
  // fulfillment record.
  dateLabel?: string | null;
  // Whether any unit on the order has left. Gates "Still here".
  anyOutOnOrder: boolean;
  // Units on the line that came back or are in the return pipeline
  // (trial items RETURN_IN_PROGRESS or CLOSED as RETURNED). Returned
  // wording replaces the pickup/delivery wording for those units; the
  // denominator counts the units that left (handed), matching the
  // order-level pill.
  returned?: number;
  // Pre-formatted short date of the latest returned unit.
  returnedDateLabel?: string | null;
}): { text: string; tone: "done" | "part" | "open" | "returned" } | null {
  const returned = opts.returned ?? 0;
  if (returned > 0) {
    const out = Math.max(opts.handed, returned);
    if (returned >= out && out > 0) {
      return {
        text: opts.returnedDateLabel
          ? `Returned ${opts.returnedDateLabel}`
          : "Returned",
        tone: "returned",
      };
    }
    return {
      text: `${returned} of ${out} returned`,
      tone: "returned",
    };
  }
  if (opts.handed >= opts.quantity && opts.handed > 0) {
    const label = opts.method === "pickup" ? "Picked up" : "Delivered";
    return {
      text: opts.dateLabel ? `${label} ${opts.dateLabel}` : label,
      tone: "done",
    };
  }
  if (opts.handed > 0) {
    const verb = opts.method === "pickup" ? "picked up" : "delivered";
    return { text: `${opts.handed} of ${opts.quantity} ${verb}`, tone: "part" };
  }
  if (opts.anyOutOnOrder) {
    return { text: "Still here", tone: "open" };
  }
  return null;
}

// Order-level "N of M pieces ..." count label used by the panel summary
// pill and the board card badge. The verb follows the lines' effective
// methods: an order whose lines are all pickup says "picked up", a mix
// of both says "pieces out", and an order with no lines falls back to
// its own fulfillment type. Per-line counts in the summary do not use
// this helper and keep their shorter wording.
export function fulfillmentCountLabel(opts: {
  out: number;
  total: number;
  method: "pickup" | "delivery";
  hasPickupLine: boolean;
  hasDeliveryLine: boolean;
}): string {
  const verb = opts.hasPickupLine && opts.hasDeliveryLine
    ? "pieces out"
    : opts.hasPickupLine
      ? "pieces picked up"
      : opts.hasDeliveryLine
        ? "pieces delivered"
        : opts.method === "pickup"
          ? "pieces picked up"
          : "pieces delivered";
  return `${opts.out} of ${opts.total} ${verb}`;
}

// The board card's gray method chip. Uses each line's effective method
// (line override, else the order's type); orders with no lines fall
// back to the order's own fulfillment type.
export function fulfillmentMethodChip(opts: {
  fulfillment: "pickup" | "delivery";
  hasPickupLine: boolean;
  hasDeliveryLine: boolean;
}): string {
  if (opts.hasPickupLine && opts.hasDeliveryLine) return "Pickup + Delivery";
  if (opts.hasPickupLine) return "Pickup";
  if (opts.hasDeliveryLine) return "Delivery";
  return opts.fulfillment === "pickup" ? "Pickup" : "Delivery";
}

export type CompletionControl =
  | { kind: "button"; fulfillment: "pickup" | "delivery" }
  | { kind: "note"; text: string };

// The panel renders exactly the controls this returns: one button or one
// note for a permitted/blocked case, none for hidden or no decision. The
// generic transition list must never also render delivery_completed, so
// this is the single source of truth for "how many completion controls".
export function completionControls(
  decision: CompletionButtonDecision | null
): CompletionControl[] {
  if (!decision || decision.kind === "hidden") return [];
  return [decision];
}

export const COMPLETION_NO_TRIAL_LINE =
  "No sleep trial on this order. It will be complete and leave the board.";

// Live trial item statuses that complete_order_without_trial() counts
// (m149): PENDING_FULFILLMENT or ACTIVE. Anything else is not a live trial.
export const LIVE_TRIAL_STATUSES = ["PENDING_FULFILLMENT", "ACTIVE"] as const;

export type CompletionDestination = "Sleep Trial" | "Completed";

// What the order's state will be right after completion, which is what
// the dialog must say instead of the transition's static "Sleep Trial"
// label. complete_order_without_trial() moves a STANDARD order that the
// state trigger put into Sleep Trial to Completed when no sleep_trial_items
// row for the journey is PENDING_FULFILLMENT or ACTIVE. Exchange journeys
// are not touched by that trigger, and stv_on_journey_delivered only
// starts or corrects items in those two statuses, so the same set is the
// right client-side read. Unknown (null) stays Sleep Trial: the trigger
// only ever moves an order away from Sleep Trial, never into it, so a
// wrong guess here can only be too cautious.
export function completionDestination(opts: {
  saleKind: "STANDARD" | "EXCHANGE" | null | undefined;
  // null means the read failed; undefined means it has not resolved yet.
  // Both are "unknown", and unknown must never promise Completed.
  liveTrialStatuses: readonly string[] | null | undefined;
}): CompletionDestination {
  if (opts.liveTrialStatuses == null) return "Sleep Trial";
  const hasLiveTrial = opts.liveTrialStatuses.some((s) =>
    (LIVE_TRIAL_STATUSES as readonly string[]).includes(s)
  );
  if (hasLiveTrial) return "Sleep Trial";
  if (opts.saleKind !== "STANDARD") return "Sleep Trial";
  return "Completed";
}

// Per-line stock tag in the completion dialog. Only the requirement's own
// status counts; anything else means we cannot tell, so no tag.
export function completionStockTag(
  status: string | null | undefined
): "in_stock" | "not_in_stock" | null {
  if (status === "ready") return "in_stock";
  if (status === "pending") return "not_in_stock";
  return null;
}

export const STOCK_TAG_LABEL: Record<"in_stock" | "not_in_stock", string> = {
  in_stock: "In stock",
  not_in_stock: "Not in stock yet",
};

export function anyRequirementPending(
  statuses: (string | null | undefined)[]
): boolean {
  return statuses.some((s) => s === "pending");
}

// The completion dialog reads line items, requirement statuses and the
// paid total fresh each time it opens. Confirm stays disabled until both
// reads have landed; a failed read never enables it.
export type CompletionReadState = "loading" | "loaded" | "failed";

export function completionConfirmReady(opts: {
  handoverState: CompletionReadState;
  paidLoaded: boolean;
}): boolean {
  return opts.handoverState === "loaded" && opts.paidLoaded;
}

// The completion transition that applies to this journey, or null when
// the order cannot be completed from its current state (cancelled,
// already delivered, wrong state for its fulfillment type).
export function completionTransitionFor(journey: {
  current_state: SleepJourneyState;
  fulfillment_type?: "delivery" | "pickup" | null;
  cancelled_at?: string | null;
  delivered_at?: string | null;
}): StateTransition | null {
  if (journey.cancelled_at || journey.delivered_at) return null;
  const candidates = STATE_TRANSITIONS[journey.current_state] ?? [];
  return (
    candidates.find(
      (t) =>
        t.event === "delivery_completed" &&
        transitionAppliesToFulfillment(t, journey.fulfillment_type)
    ) ?? null
  );
}
