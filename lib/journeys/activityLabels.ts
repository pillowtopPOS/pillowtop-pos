// ============================================================
// Journey Activity wording — the single place where event types,
// payment outcomes, and activity badges become employee-facing
// text. Anything not mapped here must never leak a raw
// snake_case name to the screen.
// ============================================================

import {
  INTERACTION_TYPE_LABELS,
  type JourneyInteraction,
} from "@/lib/journeys/interactions";
import { EXCEPTION_TYPE_LABELS } from "@/lib/journeys/sleepTrial";
import type { Employee, JourneyEvent } from "@/lib/journeys/queries";

// "Oct 12" — year appended only when it isn't the current one.
// Date-only strings parse as local midnight; full timestamps keep
// their own offset.
export function activityShortDate(iso: string): string {
  const d = iso.includes("T") ? new Date(iso) : new Date(`${iso}T00:00:00`);
  return d.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    ...(d.getFullYear() === new Date().getFullYear() ? {} : { year: "numeric" }),
  });
}

function money(n: unknown): string {
  const v = typeof n === "number" ? n : parseFloat(String(n ?? 0));
  return `$${v.toLocaleString(undefined, {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })}`;
}

// Payment titles come from the stored outcome, not the method name.
// outcome is null on a handful of legacy rows — those get the
// neutral "recorded" wording.
function paymentTitle(e: JourneyEvent): string {
  const amount = money((e.event_data ?? {}).amount);
  const noun = e.event_type === "deposit_received" ? "Deposit" : "Payment";
  switch (e.outcome) {
    case "SUCCEEDED":
      return `${noun} received · ${amount}`;
    case "UNKNOWN":
      return `${noun} outcome unknown · ${amount}`;
    case "FAILED":
      return `${noun} failed · ${amount}`;
    default:
      return `${noun} recorded · ${amount}`;
  }
}

// Whitelisted event titles. The default case is deliberately safe:
// an unmapped type renders "Journey updated" and warns in
// development — never the raw event_type.
export function activityEventTitle(e: JourneyEvent): string {
  const data = e.event_data ?? {};
  if (e.event_type === "deposit_received" || e.event_type === "payment_completed") {
    return paymentTitle(e);
  }
  switch (e.event_type) {
    case "payment_refunded":
      return e.outcome === "VOIDED"
        ? `Refund voided: ${money(data.amount)}`
        : `Refund recorded: ${money(data.amount)}${
            data.method ? ` (${String(data.method)})` : ""
          }`;
    case "journey_updated_to_sold":
      return "Sale committed";
    case "line_items_changed_balance_due":
      return "Order changed, balance now due";
    case "delivery_scheduled":
      return `Delivery scheduled${
        data.delivery_date ? ` for ${activityShortDate(String(data.delivery_date))}` : ""
      }`;
    case "inventory_received":
      return "Inventory ready";
    case "inventory_required":
      return `Waiting: ${data.item_name ?? "Stock"} is not at ${
        data.location_name ?? data.store_name ?? "the pickup store"
      } yet`;
    case "line_item_added":
      return `Item added: ${data.item_name ?? "Item"}${
        typeof data.quantity === "number" ? `, qty ${data.quantity}` : ""
      }`;
    case "line_item_updated":
      return `Item changed: ${data.item_name ?? "Item"}${
        typeof data.quantity === "number" ? `, now qty ${data.quantity}` : ""
      }${typeof data.unit_price === "number" ? ` at ${money(data.unit_price)}` : ""}`;
    case "line_item_removed":
      return `Item removed: ${data.item_name ?? "Item"}`;
    case "quote_created":
      return "Quote created";
    case "quote_sent":
      return "Quote sent";
    case "delivery_completed":
      return "Delivery completed";
    case "journey_cancelled":
      return `Journey cancelled${data.reason ? ` — ${data.reason}` : ""}`;
    case "trial_completed":
      return "Sleep trial completed";
    default:
      if (process.env.NODE_ENV !== "production") {
        console.warn(`[JourneyActivity] Unmapped event type: ${e.event_type}`);
      }
      return "Journey updated";
  }
}

// Detail lines stay whitelisted per event type — a type without an
// explicit formatter renders no detail at all. Raw event_data JSON
// must never be visible to an employee.
export function activityEventDetail(e: JourneyEvent): string | undefined {
  const data = e.event_data ?? {};
  switch (e.event_type) {
    case "deposit_received":
    case "payment_completed":
      // Method text is stored verbatim (e.g. "Simulated card — timeout"
      // is the literal test method name) — shown as the quiet line.
      return data.payment_method ? String(data.payment_method) : undefined;
    case "payment_refunded":
      return data.reason ? String(data.reason) : undefined;
    case "delivery_completed":
      return data.delivered_at
        ? `Delivered ${activityShortDate(String(data.delivered_at))}`
        : undefined;
    case "inventory_received":
      return "All required products are available.";
    case "line_items_changed_balance_due":
      return typeof data.balance_due === "number"
        ? `Balance due ${money(data.balance_due)}`
        : undefined;
    case "line_item_added":
    case "line_item_updated":
    case "line_item_removed": {
      const qty = typeof data.quantity === "number" ? data.quantity : null;
      const price =
        typeof data.unit_price === "number" ? money(data.unit_price) : null;
      const parts = [
        qty !== null ? `Qty ${qty}` : null,
        price !== null ? `${price} each` : null,
      ].filter(Boolean);
      return parts.length > 0 ? parts.join(" · ") : undefined;
    }
    default:
      return undefined;
  }
}

// triggered_by holds either the literal "system" or an auth user id;
// match it to employees.auth_user_id for a real name.
export function activityEventAuthor(
  triggeredBy: string,
  employees: Employee[]
): string {
  if (triggeredBy === "system") return "System";
  // triggered_by carries an employee id on order/line writes (DB
  // functions pass v_emp_id) and an auth user id on client writes — a
  // mismatch here is why line events used to render "Unknown".
  return (
    employees.find(
      (e) => e.id === triggeredBy || e.auth_user_id === triggeredBy
    )?.name ?? "Unknown"
  );
}

// Small uppercase label shown above customer-facing interactions.
// Types without a dedicated short badge fall back to their normal
// label, and unknowns to "Update" — never the raw type.
const INTERACTION_BADGES: Record<string, string> = {
  customer_called: "Phone Call",
  called_customer: "Phone Call",
  text_conversation: "Text",
  email: "Email",
  in_person: "In Person",
};

export function interactionBadgeLabel(i: JourneyInteraction): string {
  if (i.source_domain === "sleep_concern") return "Sleep Concern";
  if (i.is_internal) return "Note";
  return (
    INTERACTION_BADGES[i.interaction_type] ??
    INTERACTION_TYPE_LABELS[i.interaction_type] ??
    "Update"
  );
}

// Sleep-trial summaries are written as "<CODE> exception …" (migrations
// 074/075). Match the code plus an optional trailing " exception" and
// apply the same phrase logic as exceptionPhrase: the label alone when
// it already ends in "exception", otherwise label + " exception" — so
// "RETURN_NOT_ALLOWED exception denied" renders "Return exception
// denied", never "Return exception exception denied". Display only;
// stored data is untouched.
const EXCEPTION_CODE_RE = new RegExp(
  `\\b(${Object.keys(EXCEPTION_TYPE_LABELS).join("|")})( exception)?\\b`,
  "g"
);

export function interactionSummaryText(i: JourneyInteraction): string {
  return i.summary.replace(EXCEPTION_CODE_RE, (_match, code: string) => {
    const label = EXCEPTION_TYPE_LABELS[code] ?? code;
    return label.endsWith("exception") ? label : `${label} exception`;
  });
}

// ============================================================
// Unit + transfer activity wording — ONE formatter shared by the
// order activity feed and the unit history page so the two can
// never drift. Display only.
// ============================================================

export type UnitActivityEvent = {
  event_type: string;
  from_status: string | null;
  to_status: string | null;
  from_location_id: string | null;
  to_location_id: string | null;
  data?: Record<string, unknown> | null;
};

export function unitActivitySentence(
  e: UnitActivityEvent,
  ctx: {
    unitNumber?: number | null;
    locName: (id: string | null) => string;
    // "SJ-MS00123 (Ann Lee)" on the unit page; "this order" in the feed.
    orderLabel?: string | null;
    forJourney?: boolean;
    poNumber?: string | null;
  }
): string {
  const n = ctx.unitNumber != null ? `Unit ${ctx.unitNumber}` : "Unit";
  const at = (id: string | null) => (id ? ` at ${ctx.locName(id)}` : "");
  if (e.event_type === "UNIT_CREATED") {
    return `Received${at(e.to_location_id)}${
      ctx.poNumber ? ` on ${ctx.poNumber}` : ""
    }${ctx.forJourney && ctx.unitNumber != null ? ` (unit ${ctx.unitNumber})` : ""}`;
  }
  if (e.event_type === "UNIT_VOIDED" || e.to_status === "VOID") {
    return `Voided`;
  }
  if (e.to_status === "RESERVED" && e.from_status !== "RESERVED") {
    return ctx.forJourney
      ? `${n} reserved for this order${at(e.to_location_id)}`
      : `Reserved for order ${ctx.orderLabel ?? "—"}${at(e.to_location_id)}`;
  }
  if (e.to_status === "STOCK" && e.from_status === "RESERVED") {
    return `Released back to stock`;
  }
  if (e.to_status === "DELIVERED") {
    return `Delivered to ${ctx.orderLabel ?? "the customer"}`;
  }
  if (e.to_status === "IN_TRANSIT") {
    return `In transit to ${ctx.locName(e.to_location_id)}`;
  }
  if (
    e.from_location_id &&
    e.to_location_id &&
    e.from_location_id !== e.to_location_id
  ) {
    return ctx.forJourney
      ? `${n} arrived at ${ctx.locName(e.to_location_id)}`
      : `Moved to ${ctx.locName(e.to_location_id)}`;
  }
  if (e.from_status !== e.to_status && e.to_status) {
    return `${e.from_status ?? "?"} to ${e.to_status}${at(e.to_location_id)}`;
  }
  return `Updated${at(e.to_location_id)}`;
}

// One feed line per transfer stage, in plain language.
export function transferStageLines(
  r: {
    created_at: string;
    originName: string;
    destName: string;
    requestedByName?: string | null;
    transfer?: {
      created_at?: string | null;
      scheduled_date?: string | null;
      in_transit_at?: string | null;
      finalized_at?: string | null;
    } | null;
  },
  shortDate: (iso: string) => string
): { at: string; text: string; actor: string }[] {
  const out: { at: string; text: string; actor: string }[] = [
    {
      at: r.created_at,
      text: `Transfer requested: ${r.originName} to ${r.destName}`,
      actor: r.requestedByName ?? "System",
    },
  ];
  const t = r.transfer;
  if (!t) return out;
  if (t.scheduled_date) {
    out.push({
      at: t.created_at ?? r.created_at,
      text: `Transfer scheduled for ${shortDate(t.scheduled_date)}`,
      actor: "System",
    });
  }
  if (t.in_transit_at) {
    out.push({
      at: t.in_transit_at,
      text: `Shipped from ${r.originName}`,
      actor: "System",
    });
  }
  if (t.finalized_at) {
    out.push({
      at: t.finalized_at,
      text: `Arrived at ${r.destName}`,
      actor: "System",
    });
  }
  return out;
}
