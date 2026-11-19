import { SLEEP_JOURNEY_STATES, type SleepJourneyState } from "@/lib/constants";

export type JourneyEventType =
  | "quote_created"
  | "quote_sent"
  | "deposit_received"
  | "payment_completed"
  | "delivery_scheduled"
  | "delivery_unscheduled"
  | "delivery_completed"
  | "trial_completed"
  | "journey_cancelled";

export type RequiredField = {
  name: string;
  label: string;
  type: "text" | "number" | "date" | "datetime-local" | "select";
  options?: string[];
  optional?: boolean;
  defaultToday?: boolean;
};

export type StateTransition = {
  to: SleepJourneyState;
  event: JourneyEventType;
  label: string;
  requiredFields?: RequiredField[];
  // When set, the action only applies to journeys with this fulfillment
  // type. Unset means it applies to both.
  fulfillment?: "delivery" | "pickup";
};

// STATE_TRANSITIONS is keyed by state alone, so fulfillment-scoped
// actions (Mark Delivered vs Mark Picked Up) carry the order's
// fulfillment type and callers filter with this helper.
export function transitionAppliesToFulfillment(
  transition: StateTransition,
  fulfillmentType: "delivery" | "pickup" | null | undefined
): boolean {
  return (
    !transition.fulfillment ||
    transition.fulfillment === (fulfillmentType ?? "delivery")
  );
}

// Payment + refund method pickers share this list so a refund can be
// recorded the same way the payment came in.
export const PAYMENT_METHOD_OPTIONS = [
  "Credit card",
  "Debit card",
  "Cash",
  "Check",
  "Financing",
  "Other",
  "Simulated card — success",
  "Simulated card — timeout",
  "Simulated card — failure",
];

export const STATE_TRANSITIONS: Record<SleepJourneyState, StateTransition[]> = {
  "Active Opportunity": [],
  Quoted: [
    {
      to: "Sold",
      event: "payment_completed",
      label: "Record Payment",
      requiredFields: [
        { name: "amount", label: "Amount", type: "number" },
        {
          name: "payment_method",
          label: "Payment method",
          type: "select",
          options: PAYMENT_METHOD_OPTIONS,
        },
      ],
    },
  ],
  "Deposit Made": [],
  Sold: [
    {
      to: "Sleep Trial",
      event: "delivery_completed",
      label: "Mark picked up",
      fulfillment: "pickup",
    },
  ],
  "Waiting for Inventory": [],
  // Pickup orders complete from Ready to Schedule too: there is no
  // delivery stop to book, so the RPC accepts Sold or Ready to Schedule.
  "Ready to Schedule": [
    {
      to: "Sleep Trial",
      event: "delivery_completed",
      label: "Mark picked up",
      fulfillment: "pickup",
    },
  ],
  Scheduled: [
    {
      to: "Sleep Trial",
      event: "delivery_completed",
      label: "Mark delivered",
      fulfillment: "delivery",
    },
  ],
  "Sleep Trial": [
    {
      to: "Completed",
      event: "trial_completed",
      label: "Complete Trial",
    },
  ],
  Completed: [],
};

export function getStateIndex(state: SleepJourneyState) {
  return SLEEP_JOURNEY_STATES.indexOf(state);
}

export function getTransitionForTarget(
  from: SleepJourneyState,
  to: SleepJourneyState
): StateTransition | undefined {
  return STATE_TRANSITIONS[from].find((t) => t.to === to);
}

export function getTransitionForEvent(
  from: SleepJourneyState,
  eventType: JourneyEventType
): StateTransition | undefined {
  return STATE_TRANSITIONS[from].find((t) => t.event === eventType);
}

export function getValidNextStates(from: SleepJourneyState): SleepJourneyState[] {
  return STATE_TRANSITIONS[from].map((t) => t.to);
}
