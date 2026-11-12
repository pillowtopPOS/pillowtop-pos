import { createClient } from "@/lib/supabase/client";
import { localTodayISO } from "@/lib/dates";

// ============================================================
// D1-c2a: delivery contact log (migration 134). One log tied to the
// order and customer, shared by SCHEDULING calls now and CONFIRMATION
// calls later. Everything here warns and informs; nothing blocks.
// ============================================================

export type ContactOutcome =
  | "spoke"
  | "voicemail"
  | "no_answer"
  | "texted"
  | "will_call_back"
  | "not_ready"
  | "wrong_number";

export const CONTACT_OUTCOMES: { value: ContactOutcome; label: string }[] = [
  { value: "spoke", label: "Spoke with customer" },
  { value: "voicemail", label: "Left voicemail" },
  { value: "no_answer", label: "No answer" },
  { value: "texted", label: "Texted" },
  { value: "will_call_back", label: "Customer will call back" },
  { value: "not_ready", label: "Not ready yet" },
  { value: "wrong_number", label: "Wrong number" },
];

export const CONTACT_OUTCOME_LABELS: Record<string, string> =
  Object.fromEntries(CONTACT_OUTCOMES.map((o) => [o.value, o.label]));

// Outcomes that put the customer on "Waiting on customer" hold. The
// callback date field shows for exactly these.
export const HOLD_OUTCOMES: ContactOutcome[] = [
  "voicemail",
  "no_answer",
  "texted",
  "will_call_back",
  "not_ready",
];

export type DeliveryContactLastContact = {
  purpose?: string | null;
  contact_outcome: string | null;
  occurred_at: string;
  employee_name: string | null;
  journey_id: string;
  journey_number: string | null;
  customer_name: string | null;
  on_this_order: boolean;
};

export type DeliveryContactState = {
  last_contact: DeliveryContactLastContact | null;
  held: boolean;
  hold_until: string | null;
  callback_due: boolean;
  bad_number: boolean;
  recent_contact_minutes: number | null;
};

export type DeliveryContactEntry = {
  journey_id: string;
  journey_number: string | null;
  customer_name: string | null;
  employee_name: string | null;
  purpose: string;
  contact_outcome: string | null;
  note: string | null;
  occurred_at: string;
  callback_after: string | null;
  on_this_order: boolean;
};

export type DeliveryContactHistory = DeliveryContactState & {
  contacts: DeliveryContactEntry[];
};

export type DeliveryContactHoldDays = {
  hold_days: number;
  can_edit: boolean;
};

export async function logDeliveryContact(input: {
  journey_id: string;
  purpose?: "SCHEDULING" | "CONFIRMATION";
  outcome: string;
  note?: string | null;
  callback_after?: string | null;
  occurred_at?: string | null;
  idempotency_key?: string | null;
  stop_id?: string | null;
  window_snapshot?: unknown;
}): Promise<string> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc(
    "log_delivery_contact",
    {
      p_journey_id: input.journey_id,
      p_purpose: input.purpose ?? "SCHEDULING",
      p_outcome: input.outcome,
      p_note: input.note ?? null,
      p_callback_after: input.callback_after ?? null,
      p_occurred_at: input.occurred_at ?? null,
      p_idempotency_key: input.idempotency_key ?? null,
      p_stop_id: input.stop_id ?? null,
      p_window_snapshot: input.window_snapshot ?? null,
    }
  );
  if (error) throw new Error(error.message);
  return data as string;
}

export async function getDeliveryContactHistory(
  journeyId: string,
  limit = 20
): Promise<DeliveryContactHistory> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc(
    "get_delivery_contact_history",
    { p_journey_id: journeyId, p_limit: limit }
  );
  if (error) throw new Error(error.message);
  const d = (data ?? {}) as Partial<DeliveryContactHistory>;
  return {
    last_contact: d.last_contact ?? null,
    held: d.held ?? false,
    hold_until: d.hold_until ?? null,
    callback_due: d.callback_due ?? false,
    bad_number: d.bad_number ?? false,
    recent_contact_minutes: d.recent_contact_minutes ?? null,
    contacts: d.contacts ?? [],
  };
}

export async function fetchDeliveryContactHoldDays(): Promise<DeliveryContactHoldDays | null> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc(
    "get_delivery_contact_hold_days"
  );
  if (error || !data) return null;
  return data as DeliveryContactHoldDays;
}

export async function setDeliveryContactHoldDays(days: number): Promise<void> {
  const supabase = createClient();
  const { error } = await (supabase as any).rpc(
    "set_delivery_contact_hold_days",
    { p_days: days }
  );
  if (error) throw new Error(error.message);
}

// Hold days are fetched once and cached for the session; the setting
// changes rarely and a stale value only affects a date prefill. Only a
// successful fetch is cached - a failure clears the slot so the next
// call retries instead of sticking on null for the whole session.
let holdDaysCache: Promise<DeliveryContactHoldDays | null> | null = null;
export function getDeliveryContactHoldDaysCached(): Promise<DeliveryContactHoldDays | null> {
  if (!holdDaysCache) {
    holdDaysCache = fetchDeliveryContactHoldDays()
      .then((d) => {
        if (d === null) holdDaysCache = null;
        return d;
      })
      .catch(() => {
        holdDaysCache = null;
        return null;
      });
  }
  return holdDaysCache;
}

// ============================================================
// Shared wording helpers (browser local time)
// ============================================================

function sameDay(a: Date, b: Date): boolean {
  return (
    a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate()
  );
}

function timeLabel(d: Date): string {
  return d.toLocaleTimeString(undefined, {
    hour: "numeric",
    minute: "2-digit",
  });
}

const WEEKDAY_SHORT = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const MONTH_SHORT = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

/** "today 2:15 PM" / "yesterday 4:40 PM" / "Tue 2:15 PM" / "Nov 3". */
export function contactWhenLabel(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const now = new Date();
  const yesterday = new Date(now);
  yesterday.setDate(now.getDate() - 1);
  if (sameDay(d, now)) return `today ${timeLabel(d)}`;
  if (sameDay(d, yesterday)) return `yesterday ${timeLabel(d)}`;
  const ageDays = Math.floor(
    (new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime() -
      new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()) /
      86400000
  );
  if (ageDays <= 6) {
    return `${WEEKDAY_SHORT[d.getDay()]} ${timeLabel(d)}`;
  }
  return `${MONTH_SHORT[d.getMonth()]} ${d.getDate()}`;
}

/** "20 minutes ago" / "an hour ago" / "3 hours ago". */
export function relativeMinutesLabel(minutes: number | null): string {
  if (minutes === null || minutes < 0) return "";
  if (minutes < 1) return "just now";
  if (minutes < 60) {
    return `${minutes} minute${minutes === 1 ? "" : "s"} ago`;
  }
  if (minutes < 120) return "an hour ago";
  const h = Math.floor(minutes / 60);
  return `${h} hours ago`;
}

/** Past-tense phrase for an outcome, for sentences like
 *  "Sam called Hilda, left voicemail, today 2:15 PM." */
export function pastOutcomePhrase(outcome: string | null): string {
  switch (outcome) {
    case "spoke":
      return "spoke with customer";
    case "voicemail":
      return "left voicemail";
    case "no_answer":
      return "got no answer";
    case "texted":
      return "sent a text";
    case "will_call_back":
      return "customer will call back";
    case "not_ready":
      return "customer not ready yet";
    case "wrong_number":
      return "wrong number";
    default:
      return "made contact";
  }
}

/** Short line for a My Work ready row.
 *  This order: "Called today 2:15 PM, left voicemail (Sam)".
 *  Sibling order: "Sam called Hilda Jones about order SJ-0123,
 *  left voicemail, today 2:15 PM". */
export function myWorkContactLine(
  lastContact: DeliveryContactLastContact | null,
  currentJourneyId: string,
  fallbackCustomerName?: string | null
): string | null {
  if (!lastContact) return null;
  const when = contactWhenLabel(lastContact.occurred_at);
  const emp = lastContact.employee_name?.trim() || null;
  const isText = lastContact.contact_outcome === "texted";
  if (lastContact.on_this_order || lastContact.journey_id === currentJourneyId) {
    if (isText) {
      return `Texted ${when}${emp ? ` (${emp})` : ""}`;
    }
    const phrase = pastOutcomePhrase(lastContact.contact_outcome);
    return `Called ${when}, ${phrase}${emp ? ` (${emp})` : ""}`;
  }
  const who = emp ?? "Someone";
  const customer =
    lastContact.customer_name ?? fallbackCustomerName ?? "the customer";
  const order = lastContact.journey_number
    ? ` about order ${lastContact.journey_number}`
    : "";
  const verb = isText ? "texted" : "called";
  return `${who} ${verb} ${customer}${order}, ${pastOutcomePhrase(
    lastContact.contact_outcome
  )}, ${when}`;
}

/** Strip the auto-generated delivery-contact sentence from a stored
 *  summary so history shows only what the person actually typed.
 *  Generated forms: "Delivery scheduling call: <result>." and
 *  "Delivery scheduling text sent." Anything left (like an appended
 *  "Promised: ...") is kept; empty means show no note. */
export function contactDisplayNote(note: string | null): string | null {
  if (!note) return null;
  const cleaned = note
    .replace(/Delivery scheduling call:[^.]*\./g, "")
    .replace(/Delivery scheduling text sent\./g, "")
    .replace(/\s{2,}/g, " ")
    .trim();
  return cleaned || null;
}

/** "Waiting on customer until Fri" day label from an ISO timestamp. */
export function holdUntilDayLabel(iso: string | null): string {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return WEEKDAY_SHORT[d.getDay()];
}

// Date helpers for the callback field (browser local, YYYY-MM-DD).
export function addDaysToISODate(iso: string, days: number): string {
  const d = new Date(`${iso}T00:00:00`);
  d.setDate(d.getDate() + days);
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

export { localTodayISO };
