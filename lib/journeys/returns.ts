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

export type PendingReturnAction = ReturnActionLike & {
  action_id: string;
  trial_item_id: string;
  refund_recorded_at: string | null;
  committed_at: string | null;
};

// The return still waiting on its refund: COMMITTED, owed money, and not
// yet stamped. Any refund recorded while one is pending must link to it
// (p_action_id) or the return's complete step can never pass and the
// money gets recorded twice. Oldest commit wins when two are pending.
export function pendingReturnRefund(
  actions: PendingReturnAction[] | null | undefined
): PendingReturnAction | null {
  const pending = (actions ?? []).filter(
    (a) =>
      a.action === "RETURN" &&
      a.status === "COMMITTED" &&
      a.refund_recorded_at == null &&
      (a.refund_owed_cents ?? 0) > 0
  );
  if (pending.length === 0) return null;
  pending.sort((a, b) =>
    (a.committed_at ?? "").localeCompare(b.committed_at ?? "")
  );
  return pending[0];
}
