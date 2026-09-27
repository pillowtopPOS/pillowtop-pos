import { SLEEP_JOURNEY_STATES, type SleepJourneyState } from "@/lib/constants";

export type JourneyEventType =
  | "quote_created"
  | "quote_sent"
  | "deposit_received"
  | "payment_completed"
  | "delivery_scheduled"
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
};

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
          options: [
            "Credit card",
            "Debit card",
            "Cash",
            "Check",
            "Financing",
            "Other",
            "Simulated card — success",
            "Simulated card — timeout",
            "Simulated card — failure",
          ],
        },
      ],
    },
  ],
  "Deposit Made": [],
  Sold: [],
  "Waiting for Inventory": [],
  "Ready to Schedule": [
    {
      to: "Scheduled",
      event: "delivery_scheduled",
      label: "Schedule Delivery",
      requiredFields: [
        { name: "delivery_date", label: "Delivery date", type: "date" },
      ],
    },
  ],
  Scheduled: [
    {
      to: "Sleep Trial",
      event: "delivery_completed",
      label: "Mark Delivered",
      requiredFields: [
        {
          name: "delivered_at",
          label: "Delivery date",
          type: "date",
          defaultToday: true,
        },
      ],
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
