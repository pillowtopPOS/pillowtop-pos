// ============================================================
// Net money held for a journey — the single client-side copy of the
// total_paid rule (014, amended 097): SUCCEEDED payments minus
// SUCCEEDED refunds. Whole cents throughout so display code never
// compares floats.
// ============================================================

import type { JourneyEvent } from "@/lib/journeys/queries";

const PAYMENT_TYPES = new Set(["deposit_received", "payment_completed"]);

export function paymentAmountCents(e: JourneyEvent): number {
  const a = e.event_data?.amount;
  return Math.round((typeof a === "number" ? a : 0) * 100);
}

function amountCents(e: JourneyEvent): number {
  return paymentAmountCents(e);
}

export function computeNetPaidCents(events: JourneyEvent[]): number {
  let cents = 0;
  for (const e of events) {
    if (e.outcome !== "SUCCEEDED") continue;
    if (PAYMENT_TYPES.has(e.event_type)) cents += amountCents(e);
    else if (e.event_type === "payment_refunded") cents -= amountCents(e);
  }
  return cents;
}

export function computeNetPaid(events: JourneyEvent[]): number {
  return computeNetPaidCents(events) / 100;
}

// What is still refundable on one payment row: its amount minus the
// SUCCEEDED refunds already pointing at it.
export function refundableCentsOnPayment(
  payment: JourneyEvent,
  events: JourneyEvent[]
): number {
  let refunded = 0;
  for (const e of events) {
    if (
      e.event_type === "payment_refunded" &&
      e.outcome === "SUCCEEDED" &&
      e.event_data?.refunds_payment_id === payment.id
    ) {
      refunded += amountCents(e);
    }
  }
  return amountCents(payment) - refunded;
}

// SUCCEEDED payments that still have money left to refund, newest first.
export function refundablePaymentEvents(events: JourneyEvent[]): JourneyEvent[] {
  return events
    .filter(
      (e) =>
        e.outcome === "SUCCEEDED" &&
        PAYMENT_TYPES.has(e.event_type) &&
        refundableCentsOnPayment(e, events) > 0
    )
    .sort((a, b) => b.created_at.localeCompare(a.created_at));
}

// Where a credit refund should point by default: the first payment
// (callers pass newest first) that can cover the whole credit, else the
// one with the most left to refund, with the amount capped there.
export function pickRefundPayment(
  payments: JourneyEvent[],
  events: JourneyEvent[],
  creditCents: number
): { payment: JourneyEvent | null; amountCents: number } {
  let best: JourneyEvent | null = null;
  let bestCents = -1;
  for (const p of payments) {
    const left = refundableCentsOnPayment(p, events);
    if (left <= 0) continue;
    if (left >= creditCents) {
      return { payment: p, amountCents: creditCents };
    }
    if (left > bestCents) {
      best = p;
      bestCents = left;
    }
  }
  return {
    payment: best,
    amountCents: best ? Math.min(creditCents, bestCents) : 0,
  };
}
