export const SLEEP_JOURNEY_STATES = [
  "Active Opportunity",
  "Quoted",
  "Deposit Made",
  "Sold",
  "Waiting for Inventory",
  "Ready to Schedule",
  "Scheduled",
  "Sleep Trial",
  "Completed",
] as const;

export type SleepJourneyState = (typeof SLEEP_JOURNEY_STATES)[number];
