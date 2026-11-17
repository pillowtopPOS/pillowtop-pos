// Pure-logic checks for safe completion (m147 client slice):
// date-field visibility, backdate reason requirement, which action
// label applies per fulfillment type and state, and the activity-feed
// wording for delivery_completed events. No database needed.
// Run: npx tsx scripts/test_complete_fulfillment.ts
import {
  buildCompletionRequest,
  completionNeedsReason,
  completionReasonMet,
  completionShowsDateField,
  completionTransitionFor,
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

console.log(failures === 0 ? "\nAll checks passed." : `\n${failures} check(s) FAILED.`);
process.exit(failures === 0 ? 0 : 1);
