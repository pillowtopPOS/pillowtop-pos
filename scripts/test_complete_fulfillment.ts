// Pure-logic checks for safe completion (m147 client slice):
// date-field visibility, backdate reason requirement, which action
// label applies per fulfillment type and state, and the activity-feed
// wording for delivery_completed events. No database needed.
// Run: npx tsx scripts/test_complete_fulfillment.ts
import {
  anyRequirementPending,
  buildCompletionRequest,
  completionButtonDecision,
  completionControls,
  completionDestination,
  completionNeedsReason,
  completionReasonMet,
  completionShowsDateField,
  completionStockTag,
  completionTransitionFor,
  COMPLETION_COMPLETED_MESSAGE,
  COMPLETION_DRAG_MESSAGE,
  COMPLETION_NO_TRIAL_LINE,
  DELIVERY_FINALIZE_NOTE,
  effectiveLineFulfillment,
  joinLocationNames,
  linePickupLocationId,
  MIXED_ORDER_NOTE,
  pickupLocationIds,
  STOCK_TAG_LABEL,
} from "../lib/journeys/completion";
import { STATE_TRANSITIONS, transitionAppliesToFulfillment } from "../lib/journeys/state";
import { deliveryCompletedActivityText } from "../lib/journeys/activityLabels";
import type { SleepJourneyState } from "../lib/constants";

let failures = 0;
function check(name: string, ok: boolean, detail = "") {
  console.log(`${ok ? "PASS" : "FAIL"} ${name}${detail ? `: ${detail}` : ""}`);
  if (!ok) failures += 1;
}

const TODAY = "2025-11-20";

// ---- date field visibility ----
check("date field hidden without backdate permission",
  completionShowsDateField(false) === false);
check("date field shown with backdate permission",
  completionShowsDateField(true) === true);

// ---- buildCompletionRequest ----
// No permission: any picked date is refused, nothing is sent.
const noPerm = buildCompletionRequest({
  canBackdate: false, today: TODAY, completedOn: "2025-11-19", reason: "customer asked",
});
check("no backdate permission sends null date",
  noPerm.completedOn === null && noPerm.reason === null);
check("no backdate permission returns permission error",
  !!noPerm.error && noPerm.error.includes("owner, admin or manager"));

// Permission, untouched field: today is sent as null.
const untouched = buildCompletionRequest({ canBackdate: true, today: TODAY });
check("untouched date sends null (today resolved server-side)",
  untouched.completedOn === null && untouched.reason === null && !untouched.error);

const sameDay = buildCompletionRequest({
  canBackdate: true, today: TODAY, completedOn: TODAY,
});
check("picked today sends null",
  sameDay.completedOn === null && !sameDay.error);

// Earlier date without a long-enough reason: blocked client-side.
const noReason = buildCompletionRequest({
  canBackdate: true, today: TODAY, completedOn: "2025-11-19", reason: "",
});
check("earlier date without reason is blocked",
  !!noReason.error && noReason.error === "Enter a reason for the earlier date.");

const shortReason = buildCompletionRequest({
  canBackdate: true, today: TODAY, completedOn: "2025-11-19", reason: "ok",
});
check("reason under 3 chars is blocked",
  !!shortReason.error);

// The Confirm button and buildCompletionRequest share completionReasonMet:
// 0, 1 and 2 trimmed chars fail, 3 pass.
check("reason helper rejects 0 chars",
  completionReasonMet("") === false && completionReasonMet(null) === false);
check("reason helper rejects 1 char",
  completionReasonMet("a") === false);
check("reason helper rejects 2 chars",
  completionReasonMet("ab") === false);
check("reason helper accepts 3 chars",
  completionReasonMet("abc") === true);
check("reason helper trims before counting",
  completionReasonMet("  ab  ") === false &&
  completionReasonMet("  abc  ") === true);
for (const [len, reason] of [[0, ""], [1, "a"], [2, "ab"], [3, "abc"]] as const) {
  const req = buildCompletionRequest({
    canBackdate: true, today: TODAY, completedOn: "2025-11-19", reason,
  });
  check(`buildCompletionRequest reason length ${len}`,
    len < 3 ? !!req.error : !req.error && req.reason === reason);
}

const backdated = buildCompletionRequest({
  canBackdate: true, today: TODAY,
  completedOn: "2025-11-19", reason: "  Delivered a day late  ",
});
check("earlier date with reason sends date and trimmed reason",
  backdated.completedOn === "2025-11-19" &&
  backdated.reason === "Delivered a day late" && !backdated.error);

// Future date passes through to the RPC, which refuses it with its own
// message (client does not re-implement that check).
const future = buildCompletionRequest({
  canBackdate: true, today: TODAY, completedOn: "2025-11-21",
});
check("future date is passed to the RPC untouched",
  future.completedOn === "2025-11-21" && !future.error);

// ---- completionNeedsReason ----
check("reason needed only for earlier dates",
  completionNeedsReason("2025-11-19", TODAY) === true &&
  completionNeedsReason(TODAY, TODAY) === false &&
  completionNeedsReason("2025-11-21", TODAY) === false &&
  completionNeedsReason("", TODAY) === false);

// ---- action labels per fulfillment and state ----
function labelFor(state: SleepJourneyState, fulfillment: "delivery" | "pickup") {
  const journey = {
    current_state: state,
    fulfillment_type: fulfillment,
    cancelled_at: null,
    delivered_at: null,
  };
  return completionTransitionFor(journey)?.label ?? null;
}

check("delivery Scheduled offers Mark Delivered",
  labelFor("Scheduled", "delivery") === "Mark Delivered");
check("delivery Sold offers nothing",
  labelFor("Sold", "delivery") === null);
check("delivery Ready to Schedule offers nothing",
  labelFor("Ready to Schedule", "delivery") === null);
check("pickup Sold offers Mark Picked Up",
  labelFor("Sold", "pickup") === "Mark Picked Up");
check("pickup Ready to Schedule offers Mark Picked Up",
  labelFor("Ready to Schedule", "pickup") === "Mark Picked Up");
check("pickup Scheduled offers nothing",
  labelFor("Scheduled", "pickup") === null);
check("pickup Sleep Trial offers nothing",
  labelFor("Sleep Trial", "pickup") === null);
check("cancelled pickup offers nothing",
  completionTransitionFor({
    current_state: "Ready to Schedule",
    fulfillment_type: "pickup",
    cancelled_at: "2025-11-01T00:00:00Z",
    delivered_at: null,
  }) === null);
check("already delivered pickup offers nothing",
  completionTransitionFor({
    current_state: "Sleep Trial",
    fulfillment_type: "pickup",
    cancelled_at: null,
    delivered_at: "2025-11-10",
  }) === null);

// STATE_TRANSITIONS filtering: a delivery order in Sold must not see
// the pickup action and vice versa.
const soldTransitions = STATE_TRANSITIONS.Sold.filter((t) =>
  transitionAppliesToFulfillment(t, "delivery")
);
check("delivery order in Sold sees no completion action",
  !soldTransitions.some((t) => t.event === "delivery_completed"));
const readyPickup = STATE_TRANSITIONS["Ready to Schedule"].filter((t) =>
  transitionAppliesToFulfillment(t, "pickup")
);
check("pickup order in Ready to Schedule sees Mark Picked Up",
  readyPickup.length === 1 && readyPickup[0].label === "Mark Picked Up");
const readyDelivery = STATE_TRANSITIONS["Ready to Schedule"].filter((t) =>
  transitionAppliesToFulfillment(t, "delivery")
);
check("delivery order in Ready to Schedule sees no completion action",
  !readyDelivery.some((t) => t.event === "delivery_completed"));

// ---- activity wording ----
check("new delivery event reads Delivered with actor",
  deliveryCompletedActivityText({
    method: "delivery", delivered_at: "2025-11-16",
    recorded_by_name: "Jane Doe",
  }) === "Delivered Nov 16, 2025 by Jane Doe");
check("new pickup event reads Picked up",
  deliveryCompletedActivityText({
    method: "pickup", delivered_at: "2025-11-16",
    recorded_by_name: "Jane Doe",
  }) === "Picked up Nov 16, 2025 by Jane Doe");
check("backdated event adds entered-late note",
  deliveryCompletedActivityText({
    method: "pickup", delivered_at: "2025-11-16",
    recorded_by_name: "Jane Doe", backdated: true,
    backdate_reason: "Customer picked up late",
  }) === "Picked up Nov 16, 2025 by Jane Doe (entered late: Customer picked up late)");
check("missing actor omits by-clause",
  deliveryCompletedActivityText({ method: "delivery", delivered_at: "2025-11-16" }) ===
    "Delivered Nov 16, 2025");
check("legacy event without method returns undefined",
  deliveryCompletedActivityText({ delivered_at: "2025-11-16" }) === undefined);
check("empty event returns undefined",
  deliveryCompletedActivityText({}) === undefined);

// ---- Slice 1.5: panel completion gating (pure logic) ----
const NAMES: Record<string, string> = {
  storeA: "Main Street",
  storeB: "Westside",
  wh1: "Denver Warehouse",
};
const storeName = (id: string) => NAMES[id] ?? null;
const basePickup = {
  fulfillment: "pickup" as const,
  canMarkFulfilled: true,
  canPickupAnyLocation: false,
  canFinalizeDelivery: false,
  activeStoreId: "storeA",
  items: [] as { fulfillment_type_override?: "delivery" | "pickup" | null; pickup_location_id?: string | null }[],
  journeyStoreId: "storeA",
  storeName,
};

// Pickup: permission + location rules.
check("pickup button shows for permitted user at active location",
  completionButtonDecision(basePickup).kind === "button");
check("pickup hidden without orders.mark_fulfilled",
  completionButtonDecision({ ...basePickup, canMarkFulfilled: false }).kind === "hidden");
check("pickup button shows with pickup_any_location at other store",
  completionButtonDecision({
    ...basePickup, canPickupAnyLocation: true,
    items: [{ pickup_location_id: "storeB" }],
  }).kind === "button");
const wrongLoc = completionButtonDecision({
  ...basePickup,
  items: [{ pickup_location_id: "storeB" }],
});
check("pickup at other location shows login-here note",
  wrongLoc.kind === "note" &&
  wrongLoc.text === "Picked up at Westside. Log in to that location to mark it picked up.");
check("pickup note uses location names not ids",
  wrongLoc.kind === "note" && !wrongLoc.text.includes("storeB"));
check("pickup hidden when no active store resolves",
  completionButtonDecision({ ...basePickup, activeStoreId: null }).kind === "note");

// Pickup: mixed orders never get the whole-order button.
check("pickup order with a delivery line shows mixed note",
  completionButtonDecision({
    ...basePickup,
    items: [{ fulfillment_type_override: "delivery" }],
  }).kind === "note" &&
  (completionButtonDecision({
    ...basePickup,
    items: [{ fulfillment_type_override: "delivery" }],
  }) as { text: string }).text === MIXED_ORDER_NOTE);
check("pickup order leaving two locations shows mixed note",
  (completionButtonDecision({
    ...basePickup,
    items: [
      { pickup_location_id: "storeA" },
      { pickup_location_id: "storeB" },
    ],
  }) as { text: string }).text === MIXED_ORDER_NOTE);

// Delivery: gated purely on can_finalize_delivery.
const baseDelivery = { ...basePickup, fulfillment: "delivery" as const };
const ownerLike = { ...baseDelivery, canFinalizeDelivery: true, canMarkFulfilled: true, canPickupAnyLocation: true };
const warehouseManagerLike = { ...baseDelivery, canFinalizeDelivery: true, canMarkFulfilled: true, canPickupAnyLocation: false };
check("delivery button shows for delivery finalizer",
  completionButtonDecision({ ...baseDelivery, canFinalizeDelivery: true }).kind === "button");
check("delivery shows warehouse note for store staff",
  (completionButtonDecision(baseDelivery) as { text: string }).text ===
    DELIVERY_FINALIZE_NOTE);
check("delivery ignores pickup location rules",
  completionButtonDecision({
    ...baseDelivery, canFinalizeDelivery: true,
    activeStoreId: null,
    items: [{ pickup_location_id: "storeB" }],
  }).kind === "button");

// Delivery-typed order with a pickup line: mixed note for everyone,
// including owner, admin (pickup_any_location) and warehouse manager.
const mixedDeliveryLine = { fulfillment_type_override: "pickup" as const, pickup_location_id: "wh1" };
for (const [who, opts] of [
  ["owner/admin", ownerLike],
  ["warehouse manager", warehouseManagerLike],
  ["store staff", baseDelivery],
] as const) {
  const d = completionButtonDecision({ ...opts, items: [mixedDeliveryLine] });
  check(`delivery order with a pickup line shows mixed note (${who})`,
    d.kind === "note" && d.text === MIXED_ORDER_NOTE);
}
check("delivery order with pickup override and no location still mixed",
  (completionButtonDecision({ ...ownerLike, items: [{ fulfillment_type_override: "pickup" }] }) as { text: string }).text === MIXED_ORDER_NOTE);
check("delivery order with only delivery lines keeps the button",
  completionButtonDecision({ ...ownerLike, items: [{ fulfillment_type_override: "delivery" }, {}] }).kind === "button");
check("delivery order with only delivery lines keeps the staff note",
  (completionButtonDecision({ ...baseDelivery, items: [{}, {}] }) as { text: string }).text === DELIVERY_FINALIZE_NOTE);
check("pickup order with only pickup lines at one location keeps the button",
  completionButtonDecision({ ...basePickup, items: [{ pickup_location_id: "storeA" }, {}] }).kind === "button");

// Destination shown in the dialog must match complete_order_without_trial().
check("destination is Sleep Trial when a live trial item exists",
  completionDestination({ saleKind: "STANDARD", liveTrialStatuses: ["ACTIVE"] }) === "Sleep Trial" &&
  completionDestination({ saleKind: "STANDARD", liveTrialStatuses: ["PENDING_FULFILLMENT", "CLOSED"] }) === "Sleep Trial");
check("destination is Completed for a standard order with no live trial item",
  completionDestination({ saleKind: "STANDARD", liveTrialStatuses: [] }) === "Completed" &&
  completionDestination({ saleKind: "STANDARD", liveTrialStatuses: ["CLOSED", "VOIDED"] }) === "Completed");
check("destination is Sleep Trial when trial status cannot be read",
  completionDestination({ saleKind: "STANDARD", liveTrialStatuses: null }) === "Sleep Trial" &&
  completionDestination({ saleKind: "STANDARD", liveTrialStatuses: undefined }) === "Sleep Trial");
check("destination stays Sleep Trial for exchanges without a trial item",
  completionDestination({ saleKind: "EXCHANGE", liveTrialStatuses: [] }) === "Sleep Trial" &&
  completionDestination({ saleKind: "EXCHANGE", liveTrialStatuses: null }) === "Sleep Trial");
check("destination falls back to Sleep Trial when sale kind is unknown",
  completionDestination({ saleKind: null, liveTrialStatuses: [] }) === "Sleep Trial");
check("no-trial line text exact",
  COMPLETION_NO_TRIAL_LINE ===
    "No sleep trial on this order. It will be complete and leave the board.");

// Exactly one completion control per decision: the panel must never
// render a second button from the generic transition list.
const controlsFor = (d: ReturnType<typeof completionButtonDecision>) =>
  completionControls(d);
check("permitted pickup yields exactly one button control",
  controlsFor(completionButtonDecision(basePickup)).length === 1 &&
  controlsFor(completionButtonDecision(basePickup))[0].kind === "button");
check("permitted delivery yields exactly one button control",
  controlsFor(
    completionButtonDecision({ ...baseDelivery, canFinalizeDelivery: true })
  ).length === 1);
check("note case yields exactly one note control",
  controlsFor(wrongLoc).length === 1 &&
  controlsFor(wrongLoc)[0].kind === "note");
check("hidden case yields zero controls",
  controlsFor(
    completionButtonDecision({ ...basePickup, canMarkFulfilled: false })
  ).length === 0);
check("no decision yields zero controls",
  completionControls(null).length === 0);

// Line-level helpers.
check("effective line fulfillment prefers override",
  effectiveLineFulfillment(
    { fulfillment_type_override: "delivery" }, "pickup"
  ) === "delivery" &&
  effectiveLineFulfillment({}, "pickup") === "pickup");
check("pickup location falls back to order store",
  linePickupLocationId({}, "storeA") === "storeA" &&
  linePickupLocationId({ pickup_location_id: "wh1" }, "storeA") === "wh1");
check("pickupLocationIds unions pickup lines only",
  pickupLocationIds(
    [
      { fulfillment_type_override: "delivery", pickup_location_id: "storeB" },
      { pickup_location_id: "wh1" },
    ],
    { store_id: "storeA", fulfillment_type: "pickup" }
  ).join(",") === "wh1");
check("pickupLocationIds falls back to store for empty orders",
  pickupLocationIds([], { store_id: "storeA", fulfillment_type: "pickup" })[0] === "storeA");
check("joinLocationNames joins like pickupCollectionLabel",
  joinLocationNames(["A"]) === "A" &&
  joinLocationNames(["A", "B"]) === "A and B" &&
  joinLocationNames(["A", "B", "C"]) === "A, B and C");

// Stock tags.
check("stock tag maps ready to In stock",
  completionStockTag("ready") === "in_stock" &&
  STOCK_TAG_LABEL.in_stock === "In stock");
check("stock tag maps pending to Not in stock yet",
  completionStockTag("pending") === "not_in_stock" &&
  STOCK_TAG_LABEL.not_in_stock === "Not in stock yet");
check("stock tag hides for cancelled/unknown",
  completionStockTag("cancelled") === null &&
  completionStockTag(null) === null &&
  completionStockTag(undefined) === null);
check("anyRequirementPending only fires on pending",
  anyRequirementPending(["ready", "pending"]) === true &&
  anyRequirementPending(["ready", "cancelled", null]) === false);

// Copy constants.
check("Completed success message exact",
  COMPLETION_COMPLETED_MESSAGE ===
    "Done. This order has no sleep trial, so it is complete and has left the board.");
check("drag message exact",
  COMPLETION_DRAG_MESSAGE ===
    "Open the order and use its button to mark it picked up or delivered.");

console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
