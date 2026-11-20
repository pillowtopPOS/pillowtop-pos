// Pure-logic checks for safe completion (m147 client slice):
// date-field visibility, backdate reason requirement, which action
// label applies per fulfillment type and state, and the activity-feed
// wording for delivery_completed events. No database needed.
// Run: npx tsx scripts/test_complete_fulfillment.ts
import {
  anyRequirementPending,
  buildCompletionRequest,
  completionButtonDecision,
  completionConfirmReady,
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
  completionClosesOrder,
  completionClosesWithChoice,
  completionHandoverLines,
  completionMethodLines,
  completionStepperLine,
  fulfillmentCountLabel,
  fulfillmentMethodChip,
  lineStatusText,
  otherMethodItemsRemain,
  effectiveLineFulfillment,
  joinLocationNames,
  linePickupLocationId,
  OTHER_ITEMS_STAY_OPEN_NOTE,
  pickupLocationIds,
  pickupLocationNote,
  remainingUnits,
  STOCK_TAG_LABEL,
} from "../lib/journeys/completion";
import { STATE_TRANSITIONS, transitionAppliesToFulfillment } from "../lib/journeys/state";
import {
  pickRefundPayment,
  refundablePaymentEvents,
} from "../lib/journeys/paid";
import {
  actionCompleteBlockers,
  actionMilestoneKeys,
} from "../lib/journeys/exchange";
import {
  actionRefundBlockReason,
  allowedCreditCents,
  effectivePrice,
  heldReturnCents,
  isReturnedTrialItem,
  pendingReturnRefund,
  refundLockedAmountCents,
  returnedCreditCents,
  returnedPillText,
} from "../lib/journeys/returns";
import type { JourneyEvent } from "../lib/journeys/queries";
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
  labelFor("Scheduled", "delivery") === "Mark delivered");
check("delivery Sold offers nothing",
  labelFor("Sold", "delivery") === null);
check("delivery Ready to Schedule offers nothing",
  labelFor("Ready to Schedule", "delivery") === null);
check("pickup Sold offers Mark Picked Up",
  labelFor("Sold", "pickup") === "Mark picked up");
check("pickup Ready to Schedule offers Mark Picked Up",
  labelFor("Ready to Schedule", "pickup") === "Mark picked up");
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
  readyPickup.length === 1 && readyPickup[0].label === "Mark picked up");
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
  wrongLoc.text === "Set for pickup at Westside. Only employees at that location can mark it picked up.");
check("pickup note uses location names not ids",
  wrongLoc.kind === "note" && !wrongLoc.text.includes("storeB"));
check("pickup hidden when no active store resolves",
  completionButtonDecision({ ...basePickup, activeStoreId: null }).kind === "note");

// Pickup: other-method lines never block the button. A pickup order with
// only delivery lines left shows no control at all.
check("pickup order with only delivery lines shows no control",
  completionButtonDecision({
    ...basePickup,
    items: [{ fulfillment_type_override: "delivery" }],
  }).kind === "hidden");
check("pickup order with a delivery line keeps the button",
  completionButtonDecision({
    ...basePickup,
    items: [
      { pickup_location_id: "storeA" },
      { fulfillment_type_override: "delivery" },
    ],
  }).kind === "button");
check("pickup order leaving two locations shows the location note",
  (completionButtonDecision({
    ...basePickup,
    items: [
      { pickup_location_id: "storeA" },
      { pickup_location_id: "storeB" },
    ],
  }) as { text: string }).text ===
    pickupLocationNote(["Main Street", "Westside"]));

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

// Delivery-typed order with a pickup line: the pickup line stays open
// and the delivery button keeps its normal rules.
const mixedDeliveryLine = { fulfillment_type_override: "pickup" as const, pickup_location_id: "wh1" };
check("delivery order with a pickup line keeps the button (owner/admin)",
  completionButtonDecision({ ...ownerLike, items: [{}, mixedDeliveryLine] }).kind === "button");
check("delivery order with a pickup line keeps the button (warehouse manager)",
  completionButtonDecision({ ...warehouseManagerLike, items: [{}, mixedDeliveryLine] }).kind === "button");
check("delivery order with a pickup line keeps the staff note",
  (completionButtonDecision({ ...baseDelivery, items: [{}, mixedDeliveryLine] }) as { text: string }).text ===
    DELIVERY_FINALIZE_NOTE);
check("delivery order with only pickup lines shows no control",
  completionButtonDecision({ ...ownerLike, items: [mixedDeliveryLine] }).kind === "hidden");
check("delivery order with pickup override and no location still hidden",
  completionButtonDecision({ ...ownerLike, items: [{ fulfillment_type_override: "pickup" }] }).kind === "hidden");
check("delivery order with only delivery lines keeps the button",
  completionButtonDecision({ ...ownerLike, items: [{ fulfillment_type_override: "delivery" }, {}] }).kind === "button");
check("delivery order with only delivery lines keeps the staff note",
  (completionButtonDecision({ ...baseDelivery, items: [{}, {}] }) as { text: string }).text === DELIVERY_FINALIZE_NOTE);
check("pickup order with only pickup lines at one location keeps the button",
  completionButtonDecision({ ...basePickup, items: [{ pickup_location_id: "storeA" }, {}] }).kind === "button");

// Slice 2a: the button hands over every REMAINING same-method unit.
// handed = the fulfillment summary's byLine map.
check("no button when same-method units are all out",
  completionButtonDecision({
    ...basePickup,
    items: [{ id: "l1", quantity: 2 }],
    handed: { l1: 2 },
  }).kind === "hidden");
check("button stays when same-method units remain",
  completionButtonDecision({
    ...basePickup,
    items: [{ id: "l1", quantity: 2 }],
    handed: { l1: 1 },
  }).kind === "button");
check("empty handed map behaves like nothing handed over",
  completionButtonDecision({
    ...basePickup,
    items: [{ id: "l1", quantity: 2 }],
    handed: {},
  }).kind === "button");
check("fully handed other-method lines do not hide the button",
  completionButtonDecision({
    ...basePickup,
    items: [
      { id: "p1", quantity: 1 },
      { id: "d1", quantity: 1, fulfillment_type_override: "delivery" },
    ],
    handed: { d1: 1 },
  }).kind === "button");
check("no control when only other-method units remain",
  completionButtonDecision({
    ...ownerLike,
    items: [
      { id: "d1", quantity: 1 },
      { id: "p1", quantity: 1, fulfillment_type_override: "pickup" },
    ],
    handed: { d1: 1 },
  }).kind === "hidden");

// remainingUnits and the shared line-selection helpers.
check("remainingUnits subtracts handed and floors at zero",
  remainingUnits({ id: "l1", quantity: 3 }, { l1: 1 }) === 2 &&
  remainingUnits({ id: "l1", quantity: 3 }, { l1: 5 }) === 0 &&
  remainingUnits({ id: "l1", quantity: 3 }) === 3);
check("handover lines are same-method with units left",
  completionHandoverLines({
    fulfillment: "pickup",
    items: [
      { id: "p1", quantity: 2 },
      { id: "p2", quantity: 1 },
      { id: "d1", quantity: 1, fulfillment_type_override: "delivery" },
    ],
    handed: { p2: 1 },
  }).map((i) => i.id).join(",") === "p1");
check("closing is true when every remaining unit leaves now",
  completionClosesOrder({
    fulfillment: "pickup",
    items: [
      { id: "p1", quantity: 2 },
      { id: "d1", quantity: 1, fulfillment_type_override: "delivery" },
    ],
    handed: { p1: 1, d1: 1 },
  }) === true);
check("closing is false while other-method units remain",
  completionClosesOrder({
    fulfillment: "pickup",
    items: [
      { id: "p1", quantity: 1 },
      { id: "d1", quantity: 1, fulfillment_type_override: "delivery" },
    ],
    handed: {},
  }) === false);
check("closing stays true while same-method units remain",
  completionClosesOrder({
    fulfillment: "pickup",
    items: [
      { id: "p1", quantity: 2 },
      { id: "d1", quantity: 1, fulfillment_type_override: "delivery" },
    ],
    handed: { d1: 1 },
  }) === true);
check("other-items note exact",
  OTHER_ITEMS_STAY_OPEN_NOTE === "The other items on this order stay open.");

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

// Confirm stays disabled until both dialog reads have landed; a failed
// or in-flight read never enables it.
check("confirm not ready while handover is loading",
  completionConfirmReady({ handoverState: "loading", paidLoaded: true }) === false);
check("confirm not ready when handover read failed",
  completionConfirmReady({ handoverState: "failed", paidLoaded: true }) === false);
check("confirm not ready while balance is not loaded",
  completionConfirmReady({ handoverState: "loaded", paidLoaded: false }) === false &&
  completionConfirmReady({ handoverState: "loading", paidLoaded: false }) === false);
check("confirm ready only when both reads are loaded",
  completionConfirmReady({ handoverState: "loaded", paidLoaded: true }) === true);

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

// ---- Method-scoped lines (unified dialog) ----
// completionMethodLines separates the order's own type from the method
// the dialog acts on, so mixed orders are filtered correctly.
{
  const items = [
    { id: "l1", quantity: 1, fulfillment_type_override: "pickup" as const },
    { id: "l2", quantity: 2 },
    { id: "l3", quantity: 1 },
  ];
  check("method pickup picks only the override line on a delivery order",
    completionMethodLines({
      orderFulfillment: "delivery", method: "pickup", items, handed: {},
    })
      .map((l) => l.id)
      .join(",") === "l1");
  check("method delivery picks un-overridden lines on a delivery order",
    completionMethodLines({
      orderFulfillment: "delivery", method: "delivery", items,
      handed: { l3: 1 },
    })
      .map((l) => l.id)
      .join(",") === "l2");
  check("method pickup on a pickup order skips delivery-override lines",
    completionMethodLines({
      orderFulfillment: "pickup", method: "pickup",
      items: [
        { id: "a", quantity: 1 },
        { id: "b", quantity: 1, fulfillment_type_override: "delivery" as const },
      ],
      handed: {},
    })
      .map((l) => l.id)
      .join(",") === "a");
}

// otherMethodItemsRemain is scoped to the dialog's method under the
// order's own type.
check("otherMethodItemsRemain sees leftover pickup on delivery dialog",
  otherMethodItemsRemain({
    orderFulfillment: "delivery", method: "delivery",
    items: [{ id: "p1", quantity: 1, fulfillment_type_override: "pickup" }],
    handed: {},
  }) === true);
check("otherMethodItemsRemain sees leftover delivery on pickup dialog",
  otherMethodItemsRemain({
    orderFulfillment: "delivery", method: "pickup",
    items: [{ id: "d1", quantity: 1 }],
    handed: {},
  }) === true);
check("otherMethodItemsRemain ignores fully handed other-method lines",
  otherMethodItemsRemain({
    orderFulfillment: "delivery", method: "delivery",
    items: [{ id: "p1", quantity: 1, fulfillment_type_override: "pickup" }],
    handed: { p1: 1 },
  }) === false);
check("otherMethodItemsRemain false when all lines share the method",
  otherMethodItemsRemain({
    orderFulfillment: "pickup", method: "pickup",
    items: [{ id: "p1", quantity: 2 }],
    handed: { p1: 1 },
  }) === false);

// completionClosesWithChoice judges the chosen quantities: a partial
// pickup choice keeps the order open, other-method remnants keep it open.
{
  const items = [
    { id: "a", quantity: 2 },
    { id: "b", quantity: 1, fulfillment_type_override: "delivery" as const },
  ];
  check("full pickup choice closes when no other units remain",
    completionClosesWithChoice({
      orderFulfillment: "pickup", method: "pickup",
      items,
      handed: { b: 1 },
      chosen: { a: 2 },
    }) === true);
  check("partial pickup choice keeps the order open",
    completionClosesWithChoice({
      orderFulfillment: "pickup", method: "pickup",
      items,
      handed: { b: 1 },
      chosen: { a: 1 },
    }) === false);
  check("remaining other-method units keep the order open",
    completionClosesWithChoice({
      orderFulfillment: "pickup", method: "pickup",
      items,
      handed: {},
      chosen: { a: 2 },
    }) === false);
  check("delivery choice is always the full remaining set",
    completionClosesWithChoice({
      orderFulfillment: "pickup", method: "delivery",
      items,
      handed: {},
      chosen: { b: 1 },
    }) === false &&
    completionClosesWithChoice({
      orderFulfillment: "delivery", method: "delivery",
      items: [{ id: "b", quantity: 1 }],
      handed: {},
      chosen: { b: 1 },
    }) === true);
  check("empty order closes (legacy path)",
    completionClosesWithChoice({
      orderFulfillment: "pickup", method: "pickup",
      items: [],
      handed: {},
      chosen: {},
    }) === true);
}

// completionButtonDecision orderFulfillment: the pickup decision on a
// delivery order only counts pickup-effective lines.
{
  const items = [{ id: "d1", quantity: 1 }];
  const d = completionButtonDecision({
    fulfillment: "pickup",
    orderFulfillment: "delivery",
    canMarkFulfilled: true,
    canPickupAnyLocation: true,
    canFinalizeDelivery: false,
    activeStoreId: "s1",
    items,
    journeyStoreId: "s1",
    storeName: () => null,
    handed: {},
  });
  check("pickup decision hidden when only delivery lines remain",
    d.kind === "hidden");
  const d2 = completionButtonDecision({
    fulfillment: "pickup",
    orderFulfillment: "delivery",
    canMarkFulfilled: true,
    canPickupAnyLocation: true,
    canFinalizeDelivery: false,
    activeStoreId: "s1",
    items: [...items, { id: "p1", quantity: 1, fulfillment_type_override: "pickup" as const }],
    journeyStoreId: "s1",
    storeName: () => null,
    handed: {},
  });
  check("pickup decision shows when pickup units remain on delivery order",
    d2.kind === "button" && d2.fulfillment === "pickup");
}

// completionStepperLine: a pickup row is editable only at the employee's
// location with stock ready; locked and out-of-stock lines count as zero.
{
  const item = {
    id: "s1",
    quantity: 3,
    product_id: "v1",
    pickup_location_id: null as string | null,
  };
  const base = {
    handed: { s1: 1 } as Record<string, number>,
    reqStatus: { v1: "ready" },
    canPickupAnyLocation: false,
    activeStoreId: "storeA",
  };
  const ok = completionStepperLine(item, "storeA", base);
  check("stepper line editable at own location with stock ready",
    ok.editable === true && ok.remaining === 2 && ok.locId === "storeA");
  const locked = completionStepperLine(
    { ...item, pickup_location_id: "storeB" },
    "storeA",
    base
  );
  check("stepper line locked at another location",
    locked.editable === false && locked.locationLocked === true);
  const anyLoc = completionStepperLine(
    { ...item, pickup_location_id: "storeB" },
    "storeA",
    { ...base, canPickupAnyLocation: true }
  );
  check("pickup_any_location unlocks other locations",
    anyLoc.editable === true && anyLoc.locationLocked === false);
  const out = completionStepperLine(item, "storeA", {
    ...base,
    reqStatus: { v1: "pending" },
  });
  check("pending requirement makes the line out of stock",
    out.editable === false && out.outOfStock === true);
  const noStock = completionStepperLine(item, "storeA", {
    ...base,
    reqStatus: {},
  });
  check("unknown requirement keeps the line editable",
    noStock.editable === true && noStock.outOfStock === false);
}

// ---- Per-line order summary status + count labels ----
// lineStatusText: full line gets "Picked up/Delivered <date>", partial
// "N of M picked up/delivered", untouched lines get "Still here" only
// once something on the order has left.
check("full pickup line reads Picked up with date",
  lineStatusText({
    handed: 2, quantity: 2, method: "pickup",
    dateLabel: "Nov 19", anyOutOnOrder: true,
  })?.text === "Picked up Nov 19");
check("full delivery line reads Delivered with date",
  lineStatusText({
    handed: 1, quantity: 1, method: "delivery",
    dateLabel: "Nov 19", anyOutOnOrder: true,
  })?.text === "Delivered Nov 19");
check("full line without record date keeps the verb alone",
  lineStatusText({
    handed: 1, quantity: 1, method: "pickup",
    dateLabel: null, anyOutOnOrder: true,
  })?.text === "Picked up");
check("partial pickup line counts units",
  lineStatusText({
    handed: 1, quantity: 2, method: "pickup",
    anyOutOnOrder: true,
  })?.text === "1 of 2 picked up");
check("partial delivery line counts units",
  lineStatusText({
    handed: 1, quantity: 3, method: "delivery",
    anyOutOnOrder: true,
  })?.text === "1 of 3 delivered");
check("untouched line shows Still here once order is partly out",
  lineStatusText({
    handed: 0, quantity: 1, method: "pickup",
    anyOutOnOrder: true,
  })?.text === "Still here" &&
  lineStatusText({
    handed: 0, quantity: 1, method: "pickup",
    anyOutOnOrder: true,
  })?.tone === "open");
check("untouched line shows nothing on an untouched order",
  lineStatusText({
    handed: 0, quantity: 1, method: "pickup",
    anyOutOnOrder: false,
  }) === null);
check("done tone is done",
  lineStatusText({
    handed: 1, quantity: 1, method: "delivery", anyOutOnOrder: true,
  })?.tone === "done");
// isReturnedTrialItem: only CLOSED + RETURNED counts. RETURN_IN_PROGRESS
// is shared with committed exchanges and a return can still be cancelled.
check("closed returned item counts as returned",
  isReturnedTrialItem("CLOSED", "RETURNED") === true);
check("return in progress never counts",
  isReturnedTrialItem("RETURN_IN_PROGRESS", null) === false);
check("closed exchanged item is not a return",
  isReturnedTrialItem("CLOSED", "EXCHANGED") === false);
check("active and voided items are not returned",
  isReturnedTrialItem("ACTIVE", null) === false &&
    isReturnedTrialItem("VOIDED", "VOIDED") === false);
check("all handed units back reads Returned with date",
  lineStatusText({
    handed: 2, quantity: 2, method: "pickup", anyOutOnOrder: true,
    returned: 2, returnedDateLabel: "Nov 19",
  })?.text === "Returned Nov 19" &&
  lineStatusText({
    handed: 2, quantity: 2, method: "pickup", anyOutOnOrder: true,
    returned: 2,
  })?.tone === "returned");
check("partial return counts against handed, not quantity",
  lineStatusText({
    handed: 2, quantity: 2, method: "delivery", anyOutOnOrder: true,
    returned: 1,
  })?.text === "1 of 2 returned" &&
  lineStatusText({
    handed: 1, quantity: 3, method: "pickup", anyOutOnOrder: true,
    returned: 1,
  })?.text === "Returned");

// fulfillmentCountLabel: the verb follows the lines' effective methods,
// falling back to the order type when there are no lines.
check("count label for an all-pickup order",
  fulfillmentCountLabel({
    out: 1, total: 2, method: "pickup",
    hasPickupLine: true, hasDeliveryLine: false,
  }) === "1 of 2 pieces picked up");
check("count label for an all-delivery order",
  fulfillmentCountLabel({
    out: 1, total: 2, method: "delivery",
    hasPickupLine: false, hasDeliveryLine: true,
  }) === "1 of 2 pieces delivered");
check("count label for a mixed order",
  fulfillmentCountLabel({
    out: 1, total: 2, method: "delivery",
    hasPickupLine: true, hasDeliveryLine: true,
  }) === "1 of 2 pieces out");
check("count label for a pickup-only order typed delivery",
  fulfillmentCountLabel({
    out: 1, total: 2, method: "delivery",
    hasPickupLine: true, hasDeliveryLine: false,
  }) === "1 of 2 pieces picked up");
check("count label falls back to order type with no lines",
  fulfillmentCountLabel({
    out: 1, total: 2, method: "delivery",
    hasPickupLine: false, hasDeliveryLine: false,
  }) === "1 of 2 pieces delivered" &&
  fulfillmentCountLabel({
    out: 1, total: 2, method: "pickup",
    hasPickupLine: false, hasDeliveryLine: false,
  }) === "1 of 2 pieces picked up");

// fulfillmentMethodChip: the gray card chip.
check("chip says Pickup for all-pickup lines",
  fulfillmentMethodChip({
    fulfillment: "pickup", hasPickupLine: true, hasDeliveryLine: false,
  }) === "Pickup");
check("chip says Delivery for all-delivery lines",
  fulfillmentMethodChip({
    fulfillment: "delivery", hasPickupLine: false, hasDeliveryLine: true,
  }) === "Delivery");
check("chip says Pickup + Delivery for mixed lines",
  fulfillmentMethodChip({
    fulfillment: "delivery", hasPickupLine: true, hasDeliveryLine: true,
  }) === "Pickup + Delivery");
check("chip falls back to the order type with no lines",
  fulfillmentMethodChip({
    fulfillment: "delivery", hasPickupLine: false, hasDeliveryLine: false,
  }) === "Delivery" &&
  fulfillmentMethodChip({
    fulfillment: "pickup", hasPickupLine: false, hasDeliveryLine: false,
  }) === "Pickup");
check("chip uses line methods, not the order type",
  fulfillmentMethodChip({
    fulfillment: "delivery", hasPickupLine: true, hasDeliveryLine: false,
  }) === "Pickup");

// Copy constants.
check("Completed success message exact",
  COMPLETION_COMPLETED_MESSAGE ===
    "Done. This order has no sleep trial, so it is complete and has left the board.");
check("drag message exact",
  COMPLETION_DRAG_MESSAGE ===
    "Open the order and use its button to mark it picked up or delivered.");

// ---- refund payment picking (credit-due Record refund) ----
function ev(
  id: string,
  eventType: string,
  amount: number,
  createdAt: string,
  extra: Record<string, unknown> = {},
  outcome = "SUCCEEDED"
): JourneyEvent {
  return {
    id,
    journey_id: "j1",
    event_type: eventType,
    event_data: { amount, ...extra },
    outcome,
    triggered_by: "test",
    created_at: createdAt,
  };
}
const payOld = ev("p1", "payment_completed", 100, "2025-11-01T10:00:00Z");
const payNew = ev("p2", "deposit_received", 50, "2025-11-02T10:00:00Z");
const payUnknown = ev("p3", "payment_completed", 999, "2025-11-03T10:00:00Z", {}, "UNKNOWN");
const feed = [payOld, payNew, payUnknown];
const refundable = refundablePaymentEvents(feed);

check("refundable payments are succeeded only, newest first",
  refundable.length === 2 && refundable[0].id === "p2" && refundable[1].id === "p1");
check("pick prefers the newest payment that covers the credit",
  pickRefundPayment(refundable, feed, 4000).payment?.id === "p2" &&
  pickRefundPayment(refundable, feed, 4000).amountCents === 4000);
check("pick skips newer payments too small to cover",
  pickRefundPayment(refundable, feed, 8000).payment?.id === "p1" &&
  pickRefundPayment(refundable, feed, 8000).amountCents === 8000);
check("pick caps the amount when nothing covers the credit",
  (() => {
    const pick = pickRefundPayment(refundable, feed, 20000);
    return pick.payment?.id === "p1" && pick.amountCents === 10000;
  })());
check("a payment already refunded is skipped",
  (() => {
    const refund = ev("r1", "payment_refunded", 100, "2025-11-04T10:00:00Z", { refunds_payment_id: "p1" });
    const feed2 = [...feed, refund];
    const payments = refundablePaymentEvents(feed2);
    const pick = pickRefundPayment(payments, feed2, 2000);
    return payments.length === 1 && pick.payment?.id === "p2" && pick.amountCents === 2000;
  })());
check("no refundable payments returns null",
  pickRefundPayment([], feed, 500).payment === null &&
  pickRefundPayment([], feed, 500).amountCents === 0);

// 161: return actions have no replacement milestones.
check("return milestones skip the replacement rows",
  actionMilestoneKeys("RETURN").join(",") ===
    "original_received,money_settled,completed");
check("exchange milestones keep all five rows",
  actionMilestoneKeys("EXCHANGE").length === 5 &&
    actionMilestoneKeys("EXCHANGE")[0] === "replacement_reserved");
check("return complete blockers drop replacement text",
  actionCompleteBlockers(
    [
      "The replacement order has not been delivered yet",
      "The original mattress has not been marked received yet",
    ],
    "RETURN"
  ).join("|") === "The original mattress has not been marked received yet");
check("exchange complete blockers pass through",
  actionCompleteBlockers(["a", "b"], "EXCHANGE").join("|") === "a|b" &&
    actionCompleteBlockers(null, "EXCHANGE").length === 0);

// Slice 2b: a committed/completed return lowers the effective total by
// refund_owed_cents; balance and credit derive from that, not the price.
const returnWithFee = [
  { action: "RETURN", status: "COMMITTED", refund_owed_cents: 90000 },
];
check("returned credit sums committed returns",
  returnedCreditCents(returnWithFee) === 90000);
check("effective price subtracts the refund owed",
  effectivePrice(1000, returnWithFee) === 100);
check("credit due before the refund is recorded",
  100000 - effectivePrice(1000, returnWithFee) * 100 === 90000);
check("balance zero after the refund lands in paid",
  effectivePrice(1000, returnWithFee) - 100 === 0 &&
    Math.max(0, 10000 - effectivePrice(1000, returnWithFee) * 100) === 0);
const returnNoFee = [
  { action: "RETURN", status: "COMPLETED", refund_owed_cents: 100000 },
];
check("no-fee completed return zeroes the effective price",
  effectivePrice(1000, returnNoFee) === 0);
check("cancelled and draft returns change nothing",
  effectivePrice(1000, [
    { action: "RETURN", status: "CANCELLED", refund_owed_cents: 90000 },
    { action: "RETURN", status: "DRAFT", refund_owed_cents: 5000 },
  ]) === 1000);
check("exchange actions are not return credit",
  returnedCreditCents([
    { action: "EXCHANGE", status: "COMMITTED", refund_owed_cents: 40000 },
  ]) === 0);
check("returned pill wording",
  returnedPillText(0, 2) === null &&
    returnedPillText(1, 2) === "1 of 2 returned" &&
    returnedPillText(2, 2) === "Fully returned");

// A committed return awaiting its refund must capture every refund entry
// point; the helper finds it so callers can pass p_action_id.
const retA = {
  action_id: "ra1",
  trial_item_id: "ti1",
  action: "RETURN",
  status: "COMMITTED",
  refund_owed_cents: 90000,
  refund_recorded_at: null,
  committed_at: "2025-11-10T10:00:00Z",
};
check("pending return refund finds the un-refunded committed return",
  pendingReturnRefund([retA])?.action_id === "ra1");
check("completed, cancelled, draft, exchange, and refunded actions are ignored",
  pendingReturnRefund([
    { ...retA, action_id: "x1", status: "COMPLETED" },
    { ...retA, action_id: "x2", status: "CANCELLED" },
    { ...retA, action_id: "x3", status: "DRAFT" },
    { ...retA, action_id: "x4", action: "EXCHANGE" },
    { ...retA, action_id: "x5", refund_recorded_at: "2025-11-11T00:00:00Z" },
    { ...retA, action_id: "x6", refund_owed_cents: 0 },
  ]) === null &&
    pendingReturnRefund([]) === null &&
    pendingReturnRefund(null) === null);
check("oldest pending return wins",
  pendingReturnRefund([
    { ...retA, action_id: "new", committed_at: "2025-11-20T10:00:00Z" },
    { ...retA, action_id: "old", committed_at: "2025-11-10T10:00:00Z" },
  ])?.action_id === "old");

// 162 hold + locked-amount rules: committed un-refunded returns hold
// their owed refund out of the credit; linked refunds lock to the owed
// amount; only adjust callers get a free amount.
check("held cents counts only committed un-refunded returns",
  heldReturnCents([retA]) === 90000 &&
    heldReturnCents([
      retA,
      { ...retA, action_id: "h2", refund_owed_cents: 5000 },
    ]) === 95000 &&
    heldReturnCents([
      { ...retA, action_id: "h3", status: "COMPLETED" },
      { ...retA, action_id: "h4", status: "CANCELLED" },
      { ...retA, action_id: "h5", action: "EXCHANGE" },
      { ...retA, action_id: "h6", refund_recorded_at: "2025-11-11T00:00:00Z" },
    ]) === 0);
check("allowed credit subtracts the held return money",
  allowedCreditCents(120000, [retA]) === 30000 &&
    allowedCreditCents(90000, [retA]) === 0 &&
    allowedCreditCents(120000, [
      { ...retA, action_id: "hx", action: "EXCHANGE" },
    ]) === 120000);
check("locked amount: linked locks to owed, unlinked locks to allowed, adjust is free",
  refundLockedAmountCents({
    canAdjust: false,
    linkedOwedCents: 90000,
    creditCents: 120000,
    actions: [retA],
  }) === 90000 &&
    refundLockedAmountCents({
      canAdjust: false,
      linkedOwedCents: null,
      creditCents: 120000,
      actions: [retA],
    }) === 30000 &&
    refundLockedAmountCents({
      canAdjust: true,
      linkedOwedCents: 90000,
      creditCents: 120000,
      actions: [retA],
    }) === null &&
    refundLockedAmountCents({
      canAdjust: true,
      linkedOwedCents: null,
      creditCents: 120000,
      actions: [retA],
    }) === null);
check("refund block reason follows the receive and delivery milestones",
  actionRefundBlockReason({
    action: "RETURN",
    original_received_on: null,
  }) === "The original mattress has not been received yet." &&
    actionRefundBlockReason({
      action: "RETURN",
      original_received_on: "2025-11-19",
    }) === null &&
    actionRefundBlockReason({
      action: "EXCHANGE",
      original_received_on: "2025-11-19",
      replacement_delivered_on: null,
    }) === "The replacement has not been delivered yet." &&
    actionRefundBlockReason({
      action: "EXCHANGE",
      original_received_on: "2025-11-19",
      replacement_delivered_on: "2025-11-20",
    }) === null);

console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
