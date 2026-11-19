// Slice 2b: a committed or completed RETURN action lowers what the
// customer effectively owes by the action's refund_owed_cents (sale price
// minus the restocking fee). journey.price itself is never edited - the
// line guards freeze it - so every balance/credit read derives the
// effective total through these helpers instead.

export type ReturnActionLike = {
  action: string;
  status: string;
  refund_owed_cents: number | null | undefined;
};

// Cents the order's effective total drops by. DRAFT and CANCELLED actions
// never committed, so they change nothing.
export function returnedCreditCents(
  actions: ReturnActionLike[] | null | undefined
): number {
  let sum = 0;
  for (const a of actions ?? []) {
    if (
      a.action === "RETURN" &&
      (a.status === "COMMITTED" || a.status === "COMPLETED")
    ) {
      sum += a.refund_owed_cents ?? 0;
    }
  }
  return sum;
}

// journey.price is dollars; refund_owed_cents is cents. Result stays in
// dollars and never goes below zero.
export function effectivePrice(
  price: number,
  actions: ReturnActionLike[] | null | undefined
): number {
  return Math.max(0, price - returnedCreditCents(actions) / 100);
}

// Order-level pill text. returned = closed-RETURNED trial items, total =
// all non-VOIDED trial items on the order. Null means nothing to show.
export function returnedPillText(
  returned: number,
  total: number
): string | null {
  if (returned <= 0 || total <= 0) return null;
  return returned >= total ? "Fully returned" : `${returned} of ${total} returned`;
}
