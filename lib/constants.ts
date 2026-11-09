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

// Days a Ready to Schedule order may sit unscheduled before My Work shows
// an amber "Waiting N days" flag. Single source so it can move into
// delivery settings later.
export const READY_SCHEDULING_STALE_DAYS = 2;
