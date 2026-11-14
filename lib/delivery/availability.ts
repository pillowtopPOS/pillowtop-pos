// ============================================================
// D1-c2b part 3a-5: pure helpers for the /delivery landing view.
// No React, no Supabase — unit tested by
// scripts/test_delivery_slots.ts.
//
// Mirrors two server-side rules without a journey id:
//   - get_earliest_bookable_date (m129): earliest = business
//     today + 1, or + 2 once the cutoff time has passed, all in
//     the store/business timezone.
//   - DeliveryBookingModal's day-state words and cutoff note.
// Dates stay YYYY-MM-DD strings; timezone math goes through
// Intl so the browser clock can't shift a day.
// ============================================================

export type DeliveryCutoffContext = {
  timezone: string | null;
  cutoff_time: string | null; // "HH:MM" or "HH:MM:SS"
};

const WEEKDAYS_SUN = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTHS = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

function parseDay(iso: string): Date {
  return new Date(`${iso.slice(0, 10)}T00:00:00Z`);
}

function toISODay(d: Date): string {
  return d.toISOString().slice(0, 10);
}

export function addDaysISO(iso: string, n: number): string {
  const d = parseDay(iso);
  d.setUTCDate(d.getUTCDate() + n);
  return toISODay(d);
}

/** Card header pieces, UTC math only — never shifts a day. */
export function slotDayParts(iso: string): {
  weekday: string;
  dayNum: number;
  month: string;
} {
  const d = parseDay(iso);
  return {
    weekday: WEEKDAYS_SUN[d.getUTCDay()],
    dayNum: d.getUTCDate(),
    month: MONTHS[d.getUTCMonth()],
  };
}

/** "15:00" / "15:00:00" -> minutes since midnight; null when unset. */
export function cutoffMinutes(
  cutoffTime: string | null | undefined
): number | null {
  if (!cutoffTime) return null;
  const [h, m] = cutoffTime.split(":").map(Number);
  if (!Number.isFinite(h) || !Number.isFinite(m)) return null;
  return h * 60 + m;
}

/** Current date (YYYY-MM-DD) and minute-of-day inside `timezone`.
 *  Null when the timezone is missing or invalid. */
export function zonedNow(
  now: Date,
  timezone: string | null | undefined
): { dateIso: string; minutes: number } | null {
  if (!timezone) return null;
  try {
    const parts = new Intl.DateTimeFormat("en-US", {
      timeZone: timezone,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
    }).formatToParts(now);
    const get = (t: string) =>
      parts.find((p) => p.type === t)?.value ?? "";
    const dateIso = `${get("year")}-${get("month")}-${get("day")}`;
    const minutes = Number(get("hour")) * 60 + Number(get("minute"));
    if (!/^\d{4}-\d{2}-\d{2}$/.test(dateIso) || !Number.isFinite(minutes)) {
      return null;
    }
    return { dateIso, minutes };
  } catch {
    return null;
  }
}

/**
 * The earliest bookable delivery date for the company, computed the
 * same way as get_earliest_bookable_date: business today + 1, or
 * today + 2 once the cutoff time has passed in the company timezone.
 * Null when timezone data is unavailable (caller hides the marker).
 */
export function earliestBookableDate(
  ctx: DeliveryCutoffContext | null | undefined,
  now: Date = new Date()
): string | null {
  const z = zonedNow(now, ctx?.timezone);
  if (!z) return null;
  const cutoff = cutoffMinutes(ctx?.cutoff_time);
  const passed = cutoff !== null && z.minutes >= cutoff;
  return addDaysISO(z.dateIso, passed ? 2 : 1);
}

function cutoffTimeLabel(t: string): string {
  const [h, m] = t.split(":").map(Number);
  const suffix = h >= 12 ? "PM" : "AM";
  const hour = h % 12 === 0 ? 12 : h % 12;
  return `${hour}:${String(m).padStart(2, "0")} ${suffix}`;
}

function tzCity(iana: string): string {
  const last = iana.split("/").pop() ?? iana;
  return last.replace(/_/g, " ");
}

/**
 * The one-line cutoff note the booking window shows, rebuilt from
 * company-level data (no journey needed). Null when there is no
 * cutoff context to explain.
 */
export function cutoffNoteLine(
  ctx: DeliveryCutoffContext | null | undefined,
  earliestDate: string | null,
  now: Date = new Date()
): string | null {
  if (!ctx?.timezone) return null;
  if (!ctx.cutoff_time) {
    return "No cutoff. Earliest day is tomorrow.";
  }
  const z = zonedNow(now, ctx.timezone);
  if (!z) return null;
  const t = cutoffTimeLabel(ctx.cutoff_time);
  const city = tzCity(ctx.timezone);
  const suffix = city ? ` (${city} time)` : "";
  const dayAfter = addDaysISO(z.dateIso, 2);
  if (earliestDate && earliestDate === dayAfter) {
    return `Orders booked after ${t}${suffix} start the day after tomorrow.`;
  }
  return `Orders booked before ${t}${suffix} can start tomorrow.`;
}

/**
 * The status word on a landing-view day card, in the booking
 * window's words: "N open", "Full", "No delivery". A day whose
 * trucks are on but whose capacity was driven to zero (negative
 * extra slots) reads "Closed", matching the admin grid's word for
 * capacity 0.
 */
export function openSlotLabel(
  day:
    | {
        capacity: number;
        booked_count: number;
        trucks?: { on: boolean }[];
      }
    | null
    | undefined
): string {
  if (!day) return "";
  if (day.capacity <= 0) {
    const anyOn = (day.trucks ?? []).some((t) => t.on);
    return anyOn ? "Closed" : "No delivery";
  }
  const open = Math.max(0, day.capacity - day.booked_count);
  return open <= 0 ? "Full" : `${open} open`;
}

/**
 * The day the "Earliest" badge belongs on: the first loaded day on
 * or after the earliest bookable date that still has an open slot.
 * The earliest date itself can be Full, Closed or "No delivery" —
 * the badge then moves to the next day a customer could actually
 * book. Null when nothing in the loaded days qualifies.
 */
export function firstOpenDayOnOrAfter(
  earliestIso: string | null,
  days: {
    date: string;
    capacity: number;
    booked_count: number;
    trucks?: { on: boolean }[];
  }[]
): string | null {
  if (!earliestIso) return null;
  for (const d of days) {
    if (d.date < earliestIso) continue;
    const label = openSlotLabel(d);
    if (label !== "" && !["Full", "Closed", "No delivery"].includes(label)) {
      return d.date;
    }
  }
  return null;
}
