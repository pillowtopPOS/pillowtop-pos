import { createClient } from "@/lib/supabase/client";

// Exchange Builder EB-1 (docs/exchange-builder-spec.md Section 14).
// Typed wrappers for the three client-facing RPCs from migration 087.
// No UI calls these yet — the Exchange Builder panel ships in EB-3.

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
  original_credit_cents: number | null;
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
 *  the evaluation, fee and money on the action. Idempotent — a COMMITTED
 *  action returns its existing child journey id. */
export async function commitSleepTrialAction(
  actionId: string
): Promise<string> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("commit_sleep_trial_action", {
    p_action_id: actionId,
  });
  if (error) throw new Error(error.message);
  return data as string;
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
 *  settled amount is being documented — then a reference is required. */
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
  refund_recorded_at: string | null;
  fulfillment_method: FulfillmentMethod | null;
  created_by: string | null;
  created_by_name: string | null;
  created_at: string;
  committed_at: string | null;
};

/** One action row, with names resolved. Visibility-checked like the quote
 *  RPC — raises "Not authorized for this journey" for other companies. */
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
   *  journey — history (CANCELLED/COMPLETED) is not returned. */
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
