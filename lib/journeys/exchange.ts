import { createClient } from "@/lib/supabase/client";

// Exchange Builder EB-1 (docs/exchange-builder-spec.md Section 14).
// Typed wrappers for the three client-facing RPCs from migration 087.
// No UI calls these yet  -  the Exchange Builder panel ships in EB-3.

export type SleepTrialActionKind = "EXCHANGE" | "RETURN";

export type FulfillmentMethod = "delivery" | "pickup";

export type ExchangeQuote = {
  trial_item_id: string;
  journey_id: string;
  action: SleepTrialActionKind;
  /** Full stv_eval_one result (display, actions, headline, allowed_ui_actions). */
  evaluation: Record<string, unknown> | null;
  /** The actions.EXCHANGE / actions.RETURN block lifted out of the evaluation. */
  action_result: {
    status: string;
    reason_code: string | null;
    explanation: string | null;
    fee: { amount_cents: number; [k: string]: unknown } | null;
    requires_approval: boolean;
    exception_available: boolean;
    exception_type: string | null;
    applied_exception_id: string | null;
    [k: string]: unknown;
  } | null;
  locked_fee_cents: number;
  /** 169: 'POLICY' or 'EXCEPTION' when an approver set the fee. */
  fee_source?: string | null;
  original_credit_cents: number | null;
  list_credit_cents?: number | null;
  credit_capped?: boolean;
  replacement_product_id: string | null;
  replacement_price_cents: number | null;
  net_cents: number;
  refund_owed_cents: number;
  commission_basis_cents: number;
  replacement_trial_preview: {
    exchange_number: number;
    rule: "FULL_NEW" | "REMAINING" | "FIXED" | "NONE";
    nights: number | null;
    replacement_minimum: unknown;
  } | null;
  applicable_exception: {
    exception_id: string;
    exception_type: string;
    approved_terms: Record<string, unknown> | null;
    usable: boolean;
  } | null;
  quoted_at: string;
};

/** Read-only quote: evaluation + fee + money + replacement-trial preview.
 *  No drafts, no reservations, no consumed exceptions. */
export async function quoteSleepTrialAction(
  trialItemId: string,
  action: SleepTrialActionKind,
  replacementProductId: string | null
): Promise<ExchangeQuote> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("quote_sleep_trial_action", {
    p_trial_item_id: trialItemId,
    p_action: action,
    p_replacement_product_id: replacementProductId,
  });
  if (error) throw new Error(error.message);
  return data as ExchangeQuote;
}

/** Creates the DRAFT exchange/return record. Idempotent on idempotencyKey:
 *  a retry with the same key returns the same action id. */
export async function createExchangeDraft(
  trialItemId: string,
  action: SleepTrialActionKind,
  replacementProductId: string | null,
  replacementVariantId: string | null,
  fulfillmentMethod: FulfillmentMethod | null,
  idempotencyKey: string | null
): Promise<string> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("create_exchange_draft", {
    p_trial_item_id: trialItemId,
    p_action: action,
    p_replacement_product_id: replacementProductId,
    p_replacement_variant_id: replacementVariantId,
    p_fulfillment_method: fulfillmentMethod,
    p_idempotency_key: idempotencyKey,
  });
  if (error) throw new Error(error.message);
  return data as string;
}

/** Discards a DRAFT (status -> CANCELLED). Allowed for the starter or a
 *  sleep_trial.complete_exchange holder. */
export async function discardExchangeDraft(actionId: string): Promise<void> {
  const supabase = createClient();
  const { error } = await supabase.rpc("discard_exchange_draft", {
    p_action_id: actionId,
  });
  if (error) throw new Error(error.message);
}

// ---------------------------------------------------------------------------
// EB-2 (migration 088): commit / edit / cancel / refund / complete.
// ---------------------------------------------------------------------------

export type UpdateExchangeDraftParams = {
  /** Changing the product re-checks the company, resets the price to the
   *  default and clears any price-override reason. */
  replacementProductId?: string | null;
  fulfillmentMethod?: FulfillmentMethod | null;
  otherFeesCents?: number | null;
  taxCents?: number | null;
  /** sleep_trial.complete_exchange only; requires priceReason. */
  replacementPriceCents?: number | null;
  priceReason?: string | null;
};

/** Edits a DRAFT. Null/absent fields stay unchanged. Starter or a
 *  sleep_trial.complete_exchange holder; price overrides also require the
 *  permission and a non-empty reason. Returns the action id. */
export async function updateExchangeDraft(
  actionId: string,
  params: UpdateExchangeDraftParams = {}
): Promise<string> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("update_exchange_draft", {
    p_action_id: actionId,
    p_replacement_product_id: params.replacementProductId ?? null,
    p_fulfillment_method: params.fulfillmentMethod ?? null,
    p_other_fees_cents: params.otherFeesCents ?? null,
    p_tax_cents: params.taxCents ?? null,
    p_replacement_price_cents: params.replacementPriceCents ?? null,
    p_price_reason: params.priceReason ?? null,
  });
  if (error) throw new Error(error.message);
  return data as string;
}

/** Commits a DRAFT exchange: creates the linked child journey with its
 *  flagged lines, moves the trial item to EXCHANGE_IN_PROGRESS and locks
 *  the evaluation, fee and money on the action. Idempotent  -  a COMMITTED
 *  action returns its existing child journey id. */
export async function commitSleepTrialAction(
  actionId: string
): Promise<string | null> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("commit_sleep_trial_action", {
    p_action_id: actionId,
  });
  if (error) throw new Error(error.message);
  // A RETURN commit has no child journey and returns null (161).
  return data as string | null;
}

/** Cancels a COMMITTED exchange: cancels the child journey through the
 *  guarded path and reopens the original trial item. Refused once the
 *  original is received, the replacement is delivered, or the child has a
 *  SUCCEEDED payment. */
export async function cancelSleepTrialAction(
  actionId: string,
  reason: string | null
): Promise<void> {
  const supabase = createClient();
  const { error } = await supabase.rpc("cancel_sleep_trial_action", {
    p_action_id: actionId,
    p_reason: reason,
  });
  if (error) throw new Error(error.message);
}

export type ExchangeRefundMethod =
  | "card"
  | "cash"
  | "check"
  | "store_credit"
  | "none";

/** Documents the refund owed to the customer (complete_exchange holder,
 *  COMMITTED only). Amount must equal refund_owed_cents unless a different
 *  settled amount is being documented  -  then a reference is required. */
export async function recordExchangeRefund(
  actionId: string,
  method: ExchangeRefundMethod,
  amountCents: number,
  reference: string | null
): Promise<void> {
  const supabase = createClient();
  const { error } = await supabase.rpc("record_exchange_refund", {
    p_action_id: actionId,
    p_method: method,
    p_amount_cents: amountCents,
    p_reference: reference,
  });
  if (error) throw new Error(error.message);
}

/** Completes a COMMITTED exchange once all milestones are met, in order:
 *  replacement delivered, original received, money settled. Closes the
 *  trial item as EXCHANGED. "Original received" is EB-4 functionality, so
 *  completion is unreachable until then. */
export async function completeSleepTrialAction(
  actionId: string
): Promise<void> {
  const supabase = createClient();
  const { error } = await supabase.rpc("complete_sleep_trial_action", {
    p_action_id: actionId,
  });
  if (error) throw new Error(error.message);
}

// ---------------------------------------------------------------------------
// EB-3a (migration 089): read RPCs for the Exchange Builder UI.
// ---------------------------------------------------------------------------

export type ExchangeMilestone = {
  done: boolean;
  at: string | null;
  by: string | null;
};

export type ExchangeMilestones = {
  replacement_reserved: ExchangeMilestone;
  replacement_delivered: ExchangeMilestone;
  original_received: ExchangeMilestone;
  money_settled: ExchangeMilestone;
  completed: ExchangeMilestone;
};

export type VoidedRefundRecord = {
  refund_method: string | null;
  refund_amount_cents: number | null;
  refund_reference: string | null;
  recorded_by: string | null;
  recorded_by_name: string | null;
  recorded_at: string | null;
  voided_by: string | null;
  voided_by_name: string | null;
  voided_at: string | null;
  void_reason: string | null;
};

export type ExchangeActionRead = {
  action_id: string;
  status: "DRAFT" | "COMMITTED" | "COMPLETED" | "CANCELLED";
  action: SleepTrialActionKind;
  trial_item_id: string;
  journey_id: string;
  child_journey_id: string | null;
  replacement_product_id: string | null;
  replacement_product_name: string | null;
  replacement_price_cents: number | null;
  original_credit_cents: number | null;
  exchange_fee_cents: number | null;
  other_fees_cents: number | null;
  tax_cents: number | null;
  net_cents: number | null;
  refund_owed_cents: number | null;
  refund_method: string | null;
  refund_amount_cents: number | null;
  refund_reference: string | null;
  refund_recorded_at: string | null;
  refund_recorded_by: string | null;
  refund_recorded_by_name: string | null;
  refund_history: VoidedRefundRecord[];
  original_received_on: string | null;
  replacement_delivered_on: string | null;
  completed_at: string | null;
  completed_by: string | null;
  completed_by_name: string | null;
  cancelled_at: string | null;
  cancelled_by: string | null;
  cancelled_by_name: string | null;
  cancel_reason: string | null;
  fulfillment_method: FulfillmentMethod | null;
  created_by: string | null;
  created_by_name: string | null;
  created_at: string;
  committed_at: string | null;
  committed_by: string | null;
  committed_by_name: string | null;
  child_price: number | null;
  child_total_paid: number | null;
  child_has_succeeded_payment: boolean;
  /** 093: positive when the customer has paid more than the child price
   *  (e.g. an add-on was removed after payment). 0 otherwise, and absent on
   *  pre-093 payloads  -  callers should use ?? 0. */
  child_overpaid_cents?: number;
  /** 093: sum of the child's ordinary (non-exchange-flagged) add-on lines. */
  add_ons_total_cents?: number;
  milestones: ExchangeMilestones;
  can_cancel: boolean;
  cancel_block_code: string | null;
  cancel_block_message: string | null;
  can_record_refund: boolean;
  can_void_refund: boolean;
  can_complete: boolean;
  complete_blockers: string[];
  /** 164: caller has sleep_trial.reopen_action and the action is
   *  COMPLETED  -  the only status a reopen applies to. */
  can_reopen: boolean;
  /** 164: plain-language quarantine refusal for a COMPLETED action
   *  (unit moved/sold/inspected); null when reopen may proceed. */
  reopen_block_reason: string | null;
  /** 165: original-mattress custody. outcome is the last recorded
   *  answer (PICKED_UP / HANDED_OVER / NOT_PICKED_UP / NOT_HANDED_OVER);
   *  custody is the server's derived state. */
  original_pickup_outcome: OriginalPickupOutcome | null;
  original_pickup_on: string | null;
  original_pickup_location_id: string | null;
  original_pickup_location_name: string | null;
  original_pickup_by: string | null;
  original_pickup_by_name: string | null;
  original_pickup_reason: string | null;
  original_pickup_custody: OriginalPickupCustody;
  /** 165: non-blocking note for the cancel dialog when the original is
   *  recorded picked up or handed over but not yet received. */
  cancel_warning: string | null;
};

/** One action row, with names resolved. Visibility-checked like the quote
 *  RPC  -  raises "Not authorized for this journey" for other companies. */
export async function getExchangeAction(
  actionId: string
): Promise<ExchangeActionRead> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("get_exchange_action", {
    p_action_id: actionId,
  });
  if (error) throw new Error(error.message);
  return data as ExchangeActionRead;
}

/** Every RETURN action that lowers the journey's effective price
 *  (COMMITTED or COMPLETED). get_journey_exchange_actions only lists open
 *  actions, so completed returns are found through the action_id that
 *  record_payment_refund (161) writes into its payment_refunded events. */
export async function fetchJourneyReturnActions(
  journeyId: string,
  events: {
    event_type: string;
    outcome: string | null;
    event_data: unknown;
  }[]
): Promise<ExchangeActionRead[]> {
  const info = await getJourneyExchangeActions(journeyId);
  const ids = new Set(
    info.actions
      .filter((a) => a.action === "RETURN")
      .map((a) => a.action_id)
  );
  for (const e of events) {
    if (e.event_type !== "payment_refunded" || e.outcome !== "SUCCEEDED") {
      continue;
    }
    const actionId = (e.event_data as { action_id?: unknown } | null)
      ?.action_id;
    if (typeof actionId === "string") ids.add(actionId);
  }
  const reads = await Promise.all(
    Array.from(ids).map((id) => getExchangeAction(id).catch(() => null))
  );
  return reads.filter(
    (r): r is ExchangeActionRead =>
      r !== null &&
      r.action === "RETURN" &&
      (r.status === "COMMITTED" || r.status === "COMPLETED")
  );
}

/** Every COMMITTED action on the journey (RETURN and EXCHANGE) read out
 *  in full so the client can mirror the server's held-money cap on
 *  unlinked refunds: their un-recorded refund_owed_cents is held. */
export async function fetchJourneyHeldActions(
  journeyId: string
): Promise<ExchangeActionRead[]> {
  const info = await getJourneyExchangeActions(journeyId);
  const reads = await Promise.all(
    info.actions
      .filter((a) => a.status === "COMMITTED")
      .map((a) => getExchangeAction(a.action_id).catch(() => null))
  );
  return reads.filter((r): r is ExchangeActionRead => r !== null);
}

export type JourneyExchangeAction = {
  action_id: string;
  status: "DRAFT" | "COMMITTED";
  action: SleepTrialActionKind;
  trial_item_id: string;
  journey_id: string;
  child_journey_id: string | null;
  replacement_product_id: string | null;
  replacement_product_name: string | null;
  created_by: string | null;
  created_by_name: string | null;
  created_at: string;
  committed_at: string | null;
};

export type ExchangeParentLink = {
  parent_journey_id: string;
  parent_customer_name: string | null;
  original_mattress_name: string | null;
  action_id: string | null;
  action_status: string | null;
};

export type JourneyExchangeInfo = {
  /** The open (DRAFT) or COMMITTED action for each trial item on the
   *  journey  -  history (CANCELLED/COMPLETED) is not returned. */
  actions: JourneyExchangeAction[];
  /** Set only when this journey is itself an exchange child. */
  parent: ExchangeParentLink | null;
};

/** All live exchange actions on a journey plus the parent link when the
 *  journey is an exchange child. */
export async function getJourneyExchangeActions(
  journeyId: string
): Promise<JourneyExchangeInfo> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("get_journey_exchange_actions", {
    p_journey_id: journeyId,
  });
  if (error) throw new Error(error.message);
  return data as JourneyExchangeInfo;
}

// ---------------------------------------------------------------------------
// EB-3b (migration 091): refund void + derived My Work feed.
// ---------------------------------------------------------------------------

/** Voids a recorded refund (sleep_trial.void_refund holders only,
 *  COMMITTED + a refund recorded + a non-empty reason). The voided record
 *  is kept forever in refund_history; the active refund fields are
 *  cleared so the exchange goes back to "refund owed" and both cancel and
 *  a new record_exchange_refund are allowed again. */
export async function voidExchangeRefund(
  actionId: string,
  reason: string
): Promise<void> {
  const supabase = createClient();
  const { error } = await supabase.rpc("void_exchange_refund", {
    p_action_id: actionId,
    p_reason: reason,
  });
  if (error) throw new Error(error.message);
}

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Dollars <-> cents. The database stores integer cents; inputs collect
// dollars. One shared conversion pair so every builder field converts the
// same way (hand-tested: "1200"->120000, "1,234.56"->123456,
// "$9.999"->1000 (banker-free Math.round), ""->null, "abc"->null,
// "-5"->null).
// ---------------------------------------------------------------------------

/** Parses a dollars input ("1200", "$1,234.56") to integer cents. Returns
 *  null for blank, non-numeric, or negative input. */
export function dollarsToCents(input: string): number | null {
  const s = input.trim().replace(/^\$/, "").replace(/,/g, "");
  if (s === "") return null;
  const n = Number(s);
  if (!Number.isFinite(n) || n < 0) return null;
  return Math.round(n * 100);
}

/** Integer cents -> "1234.56" for editable inputs (no $ sign). */
export function centsToDollars(cents: number | null | undefined): string {
  return ((cents ?? 0) / 100).toFixed(2);
}

/** EB-4a: record the original mattress received into the location's
 *  quarantine area. Returns the returned_unit_inspections id. Server
 *  enforces start_exchange or warehouse-based, COMMITTED status, and
 *  date guards; errors surface verbatim. */
export async function receiveReturnedUnit(
  actionId: string,
  locationId: string,
  receivedOn: string
): Promise<string> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("receive_returned_unit", {
    p_action_id: actionId,
    p_location_id: locationId,
    p_received_on: receivedOn,
  });
  if (error) throw new Error(error.message);
  return data as string;
}

/** EB-4a: void a mistaken receipt while the inspection is still
 *  AWAITING_INSPECTION. Reason is required. */
export async function voidReturnedReceipt(
  actionId: string,
  reason: string
): Promise<void> {
  const supabase = createClient();
  const { error } = await supabase.rpc("void_returned_receipt", {
    p_action_id: actionId,
    p_reason: reason,
  });
  if (error) throw new Error(error.message);
}

/** 164: reopen a COMPLETED return/exchange back to COMMITTED. The
 *  recorded refund is voided into refund_history and held again, the
 *  trial item goes back to its in-progress state, and the journey
 *  derives back to Sleep Trial through the sleep_trial_action_reopened
 *  event. Reason is required; sleep_trial.reopen_action enforced
 *  server-side. */
export async function reopenSleepTrialAction(
  actionId: string,
  reason: string
): Promise<void> {
  const supabase = createClient();
  const { error } = await supabase.rpc("reopen_sleep_trial_action", {
    p_action_id: actionId,
    p_reason: reason,
  });
  if (error) throw new Error(error.message);
}

/** 164: completed actions are not returned by get_journey_exchange_actions
 *  ("history, not UI state"), so they are discovered the way they left a
 *  trail: journey_interactions rows stamped source_domain
 *  'sleep_trial_action' carry the action id in source_record_id, and a
 *  linked refund's payment_refunded event carries it in event_data. Each
 *  candidate is read in full and kept only when it is COMPLETED. */
export async function fetchJourneyCompletedActions(
  journeyId: string
): Promise<ExchangeActionRead[]> {
  const supabase = createClient();
  const [{ data: interactions }, { data: refundEvents }] =
    await Promise.all([
      supabase
        .from("journey_interactions")
        .select("source_record_id")
        .eq("journey_id", journeyId)
        .eq("source_domain", "sleep_trial_action"),
      supabase
        .from("journey_events")
        .select("event_data")
        .eq("journey_id", journeyId)
        .eq("event_type", "payment_refunded"),
    ]);
  const ids = new Set<string>();
  for (const i of (interactions ?? []) as { source_record_id: string | null }[]) {
    if (i.source_record_id) ids.add(i.source_record_id);
  }
  for (const e of (refundEvents ?? []) as { event_data: unknown }[]) {
    const actionId = (e.event_data as { action_id?: unknown } | null)
      ?.action_id;
    if (typeof actionId === "string") ids.add(actionId);
  }
  const reads = await Promise.all(
    Array.from(ids).map((id) => getExchangeAction(id).catch(() => null))
  );
  return reads.filter(
    (r): r is ExchangeActionRead => r !== null && r.status === "COMPLETED"
  );
}

/** EB-4a: owner/admin one-click quarantine provisioning for a location. */
export async function createQuarantineArea(
  locationId: string
): Promise<string> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("create_quarantine_area", {
    p_location_id: locationId,
  });
  if (error) throw new Error(error.message);
  return data as string;
}

// ---------------------------------------------------------------------------
// Pure action helpers shared by the return UI and its tests.
// ---------------------------------------------------------------------------

// Milestone rows the card renders per action: a return has no replacement
// journey, so only the receive, money and complete steps apply.
export function actionMilestoneKeys(
  action: SleepTrialActionKind
): (keyof ExchangeMilestones)[] {
  if (action === "RETURN") {
    return ["original_received", "money_settled", "completed"];
  }
  return [
    "replacement_reserved",
    "replacement_delivered",
    "original_received",
    "money_settled",
    "completed",
  ];
}

// get_exchange_action's complete_blockers still lists the replacement
// milestones for RETURN actions (091 predates returns); the card drops
// them so Complete can enable once the real blockers are met.
export function actionCompleteBlockers(
  blockers: string[] | null | undefined,
  action: SleepTrialActionKind
): string[] {
  const list = blockers ?? [];
  if (action !== "RETURN") return list;
  return list.filter((b) => !b.includes("replacement"));
}

// The owed-refund blocker text emitted by get_exchange_action's
// complete_blockers. Recording the refund completes the action only when
// it is the sole remaining blocker; anything else still open (undelivered
// replacement, unreceived original, unpaid replacement balance) means the
// refund dialog must not claim completion.
export const REFUND_COMPLETE_BLOCKER =
  "The owed refund has not been recorded yet";

export function refundIsFinalBlocker(
  blockers: string[] | null | undefined,
  action: SleepTrialActionKind
): boolean {
  const list = actionCompleteBlockers(blockers, action);
  return list.length === 1 && list[0] === REFUND_COMPLETE_BLOCKER;
}

// ---------------------------------------------------------------------------
// Open trial-action worklist (163)

export type OriginalPickupOutcome =
  | "PICKED_UP"
  | "HANDED_OVER"
  | "NOT_PICKED_UP"
  | "NOT_HANDED_OVER";

export type OriginalPickupCustody =
  | "not_yet"
  | "with_driver"
  | "waiting_to_receive"
  | "received";

/** 165: record the custody answer for the original mattress (driver
 *  pickup at the replacement stop, or handover at the pickup location).
 *  Calling again overwrites; the server keeps the displaced answer in
 *  history. Errors surface verbatim. */
export async function recordOriginalHandover(
  actionId: string,
  outcome: OriginalPickupOutcome,
  locationId: string | null,
  reason: string | null
): Promise<void> {
  const supabase = createClient();
  const { error } = await supabase.rpc("record_original_handover", {
    p_action_id: actionId,
    p_outcome: outcome,
    p_location_id: locationId,
    p_reason: reason,
  });
  if (error) throw new Error(error.message);
}

/** 165: reasoned correction for a pickup or handover recorded by
 *  mistake. Works only before the original is received; afterwards the
 *  receipt void is the path. */
export async function voidOriginalHandover(
  actionId: string,
  reason: string
): Promise<void> {
  const supabase = createClient();
  const { error } = await supabase.rpc("void_original_handover", {
    p_action_id: actionId,
    p_reason: reason,
  });
  if (error) throw new Error(error.message);
}

/** 165: the client mirror of the server's custody derivation - a set
 *  original_received_on always wins over every pickup answer. */
export function originalPickupCustody(a: {
  original_received_on: string | null;
  original_pickup_outcome?: string | null;
}): OriginalPickupCustody {
  if (a.original_received_on != null) return "received";
  if (a.original_pickup_outcome === "PICKED_UP") return "with_driver";
  if (a.original_pickup_outcome === "HANDED_OVER") {
    return "waiting_to_receive";
  }
  return "not_yet";
}

function shortPickupDate(on: string | null | undefined): string | null {
  if (!on) return null;
  const d = new Date(`${on}T00:00:00`);
  return Number.isNaN(d.getTime())
    ? null
    : d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

/** 165: the human custody line for the exchange card and the day plan.
 *  Returns null when the original is already received or nothing is
 *  recorded yet (callers show their own not-yet text there). */
export function originalPickupCustodyLine(a: {
  original_pickup_outcome?: string | null;
  original_pickup_on?: string | null;
  original_pickup_location_name?: string | null;
  original_pickup_by_name?: string | null;
  original_pickup_reason?: string | null;
}): string | null {
  const on = shortPickupDate(a.original_pickup_on);
  switch (a.original_pickup_outcome) {
    case "PICKED_UP":
      return `with the driver${on ? ` since ${on}` : ""}${
        a.original_pickup_by_name
          ? ` (picked up by ${a.original_pickup_by_name})`
          : ""
      }`;
    case "HANDED_OVER":
      return `handed over at ${
        a.original_pickup_location_name ?? "the pickup location"
      }${on ? ` ${on}` : ""}, waiting to be received`;
    case "NOT_PICKED_UP":
      return `Not picked up${a.original_pickup_reason
        ? `: ${a.original_pickup_reason}`
        : ""}`;
    case "NOT_HANDED_OVER":
      return `Not handed over${a.original_pickup_reason
        ? `: ${a.original_pickup_reason}`
        : ""}`;
    default:
      return null;
  }
}

/** 165: the COMMITTED exchange action behind the order being completed
 *  (the action's child journey) whose original is still out. This is
 *  the "ask the question" condition for the completion dialogs. */
export function originalPickupActionForJourney<
  T extends {
    action: string;
    child_journey_id: string | null;
    original_received_on: string | null;
  }
>(actions: T[] | null | undefined, journeyId: string): T | null {
  return (
    (actions ?? []).find(
      (a) =>
        a.action === "EXCHANGE" &&
        a.child_journey_id === journeyId &&
        a.original_received_on == null
    ) ?? null
  );
}

/** 165: the receive step's custody-aware text for the worklists.
 *  Returns null for not-yet / NOT_ outcomes, which keep the plain
 *  waiting label. */
export function workReceiveCustodyLabel(a: {
  original_pickup_outcome?: string | null;
  original_pickup_on?: string | null;
  original_pickup_location_name?: string | null;
}): string | null {
  const on = shortPickupDate(a.original_pickup_on);
  if (a.original_pickup_outcome === "PICKED_UP") {
    return `Picked up by the driver${on ? ` ${on}` : ""}, waiting at the warehouse`;
  }
  if (a.original_pickup_outcome === "HANDED_OVER") {
    return `Handed over at ${
      a.original_pickup_location_name ?? "the pickup location"
    }${on ? ` ${on}` : ""}, waiting to be received`;
  }
  return null;
}

/** 165: the cancel dialog shows the server warning whenever one is
 *  set - it informs, it never blocks. */
export function cancelWarningFor(action: {
  cancel_warning?: string | null;
}): string | null {
  return action.cancel_warning ?? null;
}

export type OpenTrialAction = {
  action_id: string;
  action: SleepTrialActionKind;
  journey_id: string;
  journey_number: string | null;
  journey_state: string;
  customer_name: string | null;
  trial_item_id: string;
  product_name: string | null;
  store_id: string;
  store_name: string | null;
  started_by_employee_id: string | null;
  started_by_name: string | null;
  committed_at: string;
  days_committed: number;
  original_received_on: string | null;
  replacement_delivered_on: string | null;
  child_journey_id: string | null;
  refund_owed_cents: number | null;
  refund_recorded_at: string | null;
  is_stalled: boolean;
  original_pickup_outcome: OriginalPickupOutcome | null;
  original_pickup_on: string | null;
  original_pickup_location_id: string | null;
  original_pickup_location_name: string | null;
  original_pickup_by_name: string | null;
  original_pickup_reason: string | null;
  original_pickup_custody: OriginalPickupCustody;
};

/** Every COMMITTED return/exchange the caller can see (one batched read
 *  for the board hide rule, the board chip, My Work and the inventory
 *  receive list). No role filter server-side: callers partition. */
export async function fetchOpenTrialActions(): Promise<OpenTrialAction[]> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("list_open_trial_actions");
  if (error) {
    console.error("fetchOpenTrialActions error", error);
    return [];
  }
  return (data as OpenTrialAction[] | null) ?? [];
}

// What parks a journey's items: "RETURN" when any committed action is a
// return (those orders stay on the board), "EXCHANGE" when only
// exchanges are open, null when nothing is open.
export function inProgressActionKind(
  actions: { action: string }[] | null | undefined
): "RETURN" | "EXCHANGE" | null {
  const list = actions ?? [];
  if (list.length === 0) return null;
  return list.some((a) => a.action === "RETURN") ? "RETURN" : "EXCHANGE";
}

// The committed return a board chip or work row points at. Oldest
// commit wins when an order somehow has more than one open return.
export function oldestOpenReturn<
  T extends { action: string; committed_at: string | null }
>(actions: T[] | null | undefined): T | null {
  const returns = (actions ?? []).filter((a) => a.action === "RETURN");
  if (returns.length === 0) return null;
  returns.sort((a, b) =>
    (a.committed_at ?? "").localeCompare(b.committed_at ?? "")
  );
  return returns[0];
}

// Next-step text under the board's "Return in progress" chip: the
// warehouse receive step while the original is out, the refund step once
// it is back and money is still owed. Null means nothing actionable is
// left (auto-complete is about to close it).
export function returnChipStep(a: {
  original_received_on: string | null;
  refund_owed_cents: number | null;
  refund_recorded_at: string | null;
}): string | null {
  if (a.original_received_on == null) return "Waiting for the mattress";
  if ((a.refund_owed_cents ?? 0) > 0 && a.refund_recorded_at == null) {
    return "Refund due";
  }
  return null;
}

// Board hide rule (163): a journey leaves the board only when every live
// trial item is parked on an in-progress action AND none of those
// actions is a return. Exchange-parked orders stay hidden (the
// replacement order is on the board); return-parked orders stay visible
// because nothing else represents them.
const IN_PROGRESS_TRIAL_STATUSES = new Set([
  "EXCHANGE_IN_PROGRESS",
  "RETURN_IN_PROGRESS",
]);

export function hiddenByInProgressAction(
  statusesByJourney: Map<string, string[]>,
  openActions: { journey_id: string; action: string }[]
): Set<string> {
  const returnJourneyIds = new Set(
    openActions.filter((a) => a.action === "RETURN").map((a) => a.journey_id)
  );
  const out = new Set<string>();
  statusesByJourney.forEach((statuses, journeyId) => {
    if (
      statuses.length > 0 &&
      statuses.every((s: string) => IN_PROGRESS_TRIAL_STATUSES.has(s)) &&
      !returnJourneyIds.has(journeyId)
    ) {
      out.add(journeyId);
    }
  });
  return out;
}

// The step the caller can take on an action right now, or null. Receive
// comes first (a refund is server-blocked until the original is back);
// refund needs the original received plus, for exchanges, the
// replacement delivered. Completion is automatic, so there is no
// complete step here.
export type TrialActionStep = "receive" | "refund";

export function callerActionStep<
  T extends {
    action: string;
    original_received_on: string | null;
    replacement_delivered_on?: string | null;
    refund_owed_cents: number | null;
    refund_recorded_at: string | null;
  }
>(
  a: T,
  caller: { canInspect: boolean; canRecordRefund: boolean }
): TrialActionStep | null {
  if (a.original_received_on == null) {
    return caller.canInspect ? "receive" : null;
  }
  if (
    (a.action !== "EXCHANGE" || a.replacement_delivered_on != null) &&
    (a.refund_owed_cents ?? 0) > 0 &&
    a.refund_recorded_at == null &&
    caller.canRecordRefund
  ) {
    return "refund";
  }
  return null;
}

export function workStepLabel(step: TrialActionStep): string {
  return step === "receive"
    ? "Receive the returned mattress"
    : "Record the refund";
}

// My Work partition (B2). needsYou: every action whose next step the
// caller's permissions cover. waiting: the rest, but only rows the
// caller started or that belong to the caller's store - an action at a
// store the caller has no tie to is simply not theirs to watch.
export function partitionWork<
  T extends {
    action: string;
    original_received_on: string | null;
    replacement_delivered_on?: string | null;
    refund_owed_cents: number | null;
    refund_recorded_at: string | null;
    store_id: string;
    started_by_employee_id: string | null;
  }
>(
  actions: T[] | null | undefined,
  caller: {
    employeeId: string | null;
    storeId: string | null;
    canInspect: boolean;
    canRecordRefund: boolean;
  }
): { needsYou: { action: T; step: TrialActionStep }[]; waiting: T[] } {
  const needsYou: { action: T; step: TrialActionStep }[] = [];
  const waiting: T[] = [];
  for (const a of actions ?? []) {
    const step = callerActionStep(a, caller);
    if (step) {
      needsYou.push({ action: a, step });
    } else if (
      (caller.employeeId != null &&
        a.started_by_employee_id === caller.employeeId) ||
      (caller.storeId != null && a.store_id === caller.storeId)
    ) {
      waiting.push(a);
    }
  }
  return { needsYou, waiting };
}

// Sidebar badge parity (163): the badge counts what the My Work page
// actually renders - every non-action item (ready, follow-ups,
// approvals, opportunities) plus the caller's Needs you rows. The
// exchange/return items still inside the fetched list and the
// Waiting-on-others rows are not counted.
export function visibleWorkCount(
  items: unknown[] | null | undefined,
  needsYouCount: number
): number {
  return (items ?? []).length + needsYouCount;
}
