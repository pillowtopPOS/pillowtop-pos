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
  if (chosen < today && reason.length < 3) {
    return {
      completedOn: null,
      reason: null,
      error: "Enter a reason for the earlier date.",
    };
  }
  return { completedOn: chosen, reason: reason || null };
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
