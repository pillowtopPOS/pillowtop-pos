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
