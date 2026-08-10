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

export const BOARD_STATES = [
  "Quoted",
  "Sold",
  "Waiting for Inventory",
  "Ready to Schedule",
  "Scheduled",
  "Sleep Trial",
] as const;

export type BoardState = (typeof BOARD_STATES)[number];
