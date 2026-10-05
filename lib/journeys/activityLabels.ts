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
      return "Waiting for inventory";
    case "line_item_added":
      return `Added to order${data.item_name ? `: ${data.item_name}` : ""}`;
    case "line_item_updated":
      return `Updated in order${data.item_name ? `: ${data.item_name}` : ""}`;
    case "line_item_removed":
      return `Removed from order${data.item_name ? `: ${data.item_name}` : ""}`;
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
  return (
    employees.find((e) => e.auth_user_id === triggeredBy)?.name ?? "Unknown"
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
