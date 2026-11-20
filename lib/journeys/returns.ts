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
  original_received_on?: string | null;
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

// A trial item only counts as returned once it is CLOSED with
// close_reason RETURNED. RETURN_IN_PROGRESS is shared with committed
// exchanges (stv_action_set_item_in_progress sets it for both) and a
// committed return can still be cancelled, so in-progress never counts.
export function isReturnedTrialItem(
  status: string,
  closeReason: string | null
): boolean {
  return status === "CLOSED" && closeReason === "RETURNED";
}

// Money held for committed returns that still owe an un-recorded refund.
// The credit due already dropped when the return was committed, so
// without the hold an unlinked refund could pay this money out before
// the mattress is received. Mirrors held_return_cents in migration 162.
export function heldReturnCents<
  T extends ReturnActionLike & { refund_recorded_at?: string | null }
>(actions: T[] | null | undefined): number {
  let sum = 0;
  for (const a of actions ?? []) {
    if (
      a.action === "RETURN" &&
      a.status === "COMMITTED" &&
      a.refund_recorded_at == null &&
      (a.refund_owed_cents ?? 0) > 0
    ) {
      sum += a.refund_owed_cents ?? 0;
    }
  }
  return sum;
}

// What an unlinked refund may take: the credit due minus held return
// money. Negative means every refundable cent is spoken for.
export function allowedCreditCents<
  T extends ReturnActionLike & { refund_recorded_at?: string | null }
>(creditCents: number, actions: T[] | null | undefined): number {
  return creditCents - heldReturnCents(actions);
}

// The amount a non-adjust caller is locked to: the return's owed refund
// when the refund is linked, the allowed credit for a plain credit-due
// refund, or null (free amount, capped by the payment) for callers with
// payments.adjust_refund_amount.
export function refundLockedAmountCents<
  T extends ReturnActionLike & { refund_recorded_at?: string | null }
>(opts: {
  canAdjust: boolean;
  linkedOwedCents?: number | null;
  creditCents: number;
  actions: T[] | null | undefined;
}): number | null {
  if (opts.canAdjust) return null;
  if (opts.linkedOwedCents != null) return opts.linkedOwedCents;
  return allowedCreditCents(opts.creditCents, opts.actions);
}

// One line for every linked-refund dialog: the sentence is identical
// whether the refund opens from the action card, the Financial rail or
// a payment row. Falls back to "this return/exchange" when the product
// name is unknown.
export function refundLinkedLine(
  action: "RETURN" | "EXCHANGE",
  productName?: string | null
): string {
  const noun = action === "RETURN" ? "return" : "exchange";
  const name = productName?.trim();
  if (name) {
    return `This refund is recorded as the refund for the ${noun} of ${name}.`;
  }
  return `This refund is recorded as the refund for this ${noun}.`;
}

// Money held for committed actions of either kind that still owe an
// un-recorded refund. Mirrors held_cents in migration 162: unlike
// held_return_cents (return money only, already netted out of the credit
// due), this is the cap the server applies to adjust callers so an
// unlinked refund can never touch money owed to an open return or
// exchange.
export function heldActionCents<
  T extends ReturnActionLike & { refund_recorded_at?: string | null }
>(actions: T[] | null | undefined): number {
  let sum = 0;
  for (const a of actions ?? []) {
    if (
      a.status === "COMMITTED" &&
      a.refund_recorded_at == null &&
      (a.refund_owed_cents ?? 0) > 0
    ) {
      sum += a.refund_owed_cents ?? 0;
    }
  }
  return sum;
}

// The server's unlinked-refund cap: net paid minus all held money.
// Passing more is refused with the held-money error, so the dialog uses
// this as its editable ceiling alongside the per-payment remainder.
export function unlinkedRefundCapCents(
  netPaidCents: number,
  heldCents: number
): number {
  return Math.max(0, netPaidCents - Math.max(0, heldCents));
}

// Why a linked refund cannot be recorded yet, or null. Mirrors the R2
// gates in record_payment_refund / record_exchange_refund: a return
// needs the original back; an exchange needs both physical steps done.
export function actionRefundBlockReason(a: {
  action: string;
  original_received_on?: string | null;
  replacement_delivered_on?: string | null;
}): string | null {
  if (a.original_received_on == null) {
    return "The original mattress has not been received yet.";
  }
  if (a.action === "EXCHANGE" && a.replacement_delivered_on == null) {
    return "The replacement has not been delivered yet.";
  }
  return null;
}
