// ============================================================
// D1-c2b part 3a: pure helpers for the night-before confirmation
// call list. No React, no Supabase — unit tested by
// scripts/test_delivery_calls.ts.
//
// Dates (YYYY-MM-DD) are plain calendar dates: weekday/month math
// runs through Date.UTC only, so the browser's timezone can never
// shift a day. occurred_at values are real timestamps and are
// formatted in local time like the rest of the app.
// ============================================================

import { timeStrToMinutes, windowLabel } from "./windows.ts";

export type ConfirmationCallStatus =
  | "not_called"
  | "confirmed"
  | "confirmed_window_changed"
  | "left_voicemail"
  | "no_answer"
  | "wrong_number"
  | "needs_different_day";

export type ConfirmationPillTone = "grey" | "green" | "amber" | "red";

export const CONFIRMATION_STATUS_META: Record<
  ConfirmationCallStatus,
  { label: string; tone: ConfirmationPillTone }
> = {
  not_called: { label: "Not called", tone: "grey" },
  confirmed: { label: "Confirmed", tone: "green" },
  confirmed_window_changed: {
    label: "Window changed since confirmed, call again",
    tone: "amber",
  },
  left_voicemail: { label: "Left voicemail", tone: "grey" },
  no_answer: { label: "No answer", tone: "grey" },
  wrong_number: { label: "Wrong number", tone: "red" },
  needs_different_day: { label: "Needs a different day", tone: "amber" },
};

// The five outcomes the log-call modal offers, in display order.
// Values are the CONFIRMATION contact_outcome namespace from m138.
export const CONFIRMATION_OUTCOMES = [
  { value: "confirmed", label: "Confirmed" },
  { value: "left_voicemail", label: "Left voicemail" },
  { value: "no_answer", label: "No answer" },
  { value: "wrong_number", label: "Wrong number" },
  { value: "needs_different_day", label: "Needs a different day" },
] as const;

export type ConfirmationOutcome = (typeof CONFIRMATION_OUTCOMES)[number]["value"];

const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

/** "2026-11-13" -> "Fri Nov 13". UTC math only — never shifts a day. */
export function confirmationDayLabel(iso: string): string {
  const [y, m, d] = iso.slice(0, 10).split("-").map(Number);
  if (!y || !m || !d) return iso;
  const wd = new Date(Date.UTC(y, m - 1, d)).getUTCDay();
  return `${WEEKDAYS[wd]} ${MONTHS[m - 1]} ${d}`;
}

/**
 * The window line on a call-list row (and in the log-call modal).
 * day_only companies get the delivery date instead of a window;
 * window mode with no window set shows "No window set".
 */
export function confirmationWindowText(
  dayMode: string,
  windowStart: string | null,
  windowEnd: string | null,
  dateIso: string
): string {
  if (dayMode === "day_only") return confirmationDayLabel(dateIso);
  return (
    windowLabel(timeStrToMinutes(windowStart), timeStrToMinutes(windowEnd)) ??
    "No window set"
  );
}

function clockLabel(d: Date): string {
  const h24 = d.getHours();
  const m = d.getMinutes();
  const suffix = h24 < 12 ? "AM" : "PM";
  const h12 = h24 % 12 === 0 ? 12 : h24 % 12;
  return `${h12}:${String(m).padStart(2, "0")} ${suffix}`;
}

function localDayStart(d: Date): number {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
}

/**
 * "today 4:50 PM" / "yesterday 4:50 PM" / "Nov 10, 4:50 PM" for a real
 * timestamp, relative to `now` (injectable for tests).
 */
export function lastCallWhen(
  occurredAt: string,
  now: Date = new Date()
): string {
  const d = new Date(occurredAt);
  if (Number.isNaN(d.getTime())) return occurredAt;
  const dayDiff = Math.round(
    (localDayStart(now) - localDayStart(d)) / 86_400_000
  );
  const t = clockLabel(d);
  if (dayDiff === 0) return `today ${t}`;
  if (dayDiff === 1) return `yesterday ${t}`;
  if (dayDiff > 1) {
    return `${MONTHS[d.getMonth()]} ${d.getDate()}, ${t}`;
  }
  // Future timestamps (clock skew) still read sanely.
  return `${MONTHS[d.getMonth()]} ${d.getDate()}, ${t}`;
}

export type LastCallInfo = {
  outcome: string | null;
  occurred_at: string | null;
  by_name: string | null;
};

/**
 * "Left voicemail, yesterday 4:50 PM (Sam)" — the last-call summary on
 * a call-list row. Null when there is no recorded call.
 */
export function lastCallText(
  lastCall: LastCallInfo | null | undefined,
  now: Date = new Date()
): string | null {
  if (!lastCall?.occurred_at) return null;
  const outcome = lastCall.outcome as ConfirmationCallStatus | null;
  const label =
    (outcome && CONFIRMATION_STATUS_META[outcome]?.label) ?? "Call";
  const who = lastCall.by_name ? ` (${lastCall.by_name})` : "";
  return `${label}, ${lastCallWhen(lastCall.occurred_at, now)}${who}`;
}

/** Status pill classes by tone — kept here so the page stays markup-only. */
export const CONFIRMATION_PILL_CLASSES: Record<ConfirmationPillTone, string> = {
  grey: "bg-slate-100 text-slate-600",
  green: "bg-green-100 text-green-800",
  amber: "bg-amber-100 text-amber-800",
  red: "bg-red-100 text-red-800",
};

/** Display-only phone formatting: a 10-digit US number (or 11 digits
 *  with a leading 1) shows as "303-555-0166"; anything else is shown
 *  exactly as stored. Never mutates the stored value. */
export function formatPhoneDashed(
  phone: string | null | undefined
): string {
  const trimmed = (phone ?? "").trim();
  const digits = trimmed.replace(/\D/g, "");
  const ten =
    digits.length === 11 && digits.startsWith("1")
      ? digits.slice(1)
      : digits;
  if (ten.length === 10) {
    return `${ten.slice(0, 3)}-${ten.slice(3, 6)}-${ten.slice(6)}`;
  }
  return trimmed;
}
