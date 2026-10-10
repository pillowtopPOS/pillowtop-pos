"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import {
  quoteSleepTrialAction,
  createExchangeDraft,
  discardExchangeDraft,
  updateExchangeDraft,
  commitSleepTrialAction,
  getExchangeAction,
  dollarsToCents,
  centsToDollars,
  type ExchangeQuote,
  type JourneyExchangeAction,
  type FulfillmentMethod,
} from "@/lib/journeys/exchange";
import {
  formatMoney,
  type SleepTrialEvaluation,
} from "@/lib/journeys/sleepTrial";
import {
  fetchStores,
  type JourneyWithDetails,
  type Employee,
  type Store,
} from "@/lib/journeys/queries";
import type { Product } from "@/lib/inventory/queries";
import Modal from "@/components/Modal";
import ProductPicker, {
  type ProductSelection,
} from "@/components/ProductPicker";

// Exchange Builder EB-3a (docs/exchange-builder-spec.md Section 16):
// start -> quote -> pick replacement (mattresses only) -> money ->
// fulfillment -> review -> commit. Draft is created when the user leaves
// the replacement step and discarded if they close without committing.

type Step = "return" | "replacement" | "money" | "fulfillment" | "review";

const STEPS: { key: Step; label: string }[] = [
  { key: "return", label: "Return" },
  { key: "replacement", label: "Replacement" },
  { key: "money", label: "Money" },
  { key: "fulfillment", label: "Fulfillment" },
  { key: "review", label: "Review" },
];

/** RPC messages are already plain English; only transport noise needs
 *  translating. */
function friendlyError(e: unknown): string {
  const msg = (e as Error)?.message ?? "Something went wrong";
  if (msg === "Failed to fetch" || msg.includes("fetch failed")) {
    return "Couldn't reach the server — check your connection and try again.";
  }
  return msg;
}

export default function ExchangeBuilderModal({
  journey,
  evaluation,
  existingAction,
  currentEmployee,
  canCompleteExchange,
  onClose,
  onCommitted,
  onChanged,
}: {
  journey: JourneyWithDetails;
  evaluation: SleepTrialEvaluation;
  /** The open (DRAFT) action already on this trial item, if any. */
  existingAction: JourneyExchangeAction | null;
  currentEmployee: Employee | null;
  canCompleteExchange: boolean;
  onClose: () => void;
  onCommitted: (childJourneyId: string) => void;
  onChanged: () => void;
}) {
  const trialItemId = evaluation.trial_item_id;
  const [quote, setQuote] = useState<ExchangeQuote | null>(null);
  const [quoteError, setQuoteError] = useState<string | null>(null);
  const [step, setStep] = useState<Step>("return");
  const [selection, setSelection] = useState<ProductSelection | null>(null);
  const [actionId, setActionId] = useState<string | null>(null);
  const [resuming, setResuming] = useState<boolean>(!!existingAction);
  const [otherFeesInput, setOtherFeesInput] = useState("0.00");
  const [taxInput, setTaxInput] = useState("0.00");
  const [priceInput, setPriceInput] = useState<string | null>(null);
  const [priceReason, setPriceReason] = useState("");
  const [fulfillment, setFulfillment] = useState<FulfillmentMethod>("delivery");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [storeId, setStoreId] = useState<string>(journey.store_id);
  const [stores, setStores] = useState<Store[]>([]);
  const [catEligible, setCatEligible] = useState<Record<string, boolean> | null>(null);
  const committedRef = useRef(false);
  // A draft created by this builder session is discarded on close; a draft
  // that existed before (someone else's or an older one of mine) is left
  // alone — discarding it is a deliberate button, not a side effect.
  const createdHereRef = useRef(false);
  // One idempotency key per builder session — a retry of "Next" replays to
  // the same action id instead of duplicating drafts.
  const idempotencyKey = useMemo(
    () => `eb-${trialItemId}-${crypto.randomUUID()}`,
    [trialItemId]
  );

  const hasDeliveryAddress =
    (journey.customer?.street_address ?? "").trim() !== "";

  // Stock display + trial eligibility both read catalog/store reference
  // data once on mount. The stock location is the session's active store
  // (also where commit places the child; falls back to the original
  // journey's store) resolved through the fulfillment rule.
  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getSession().then(({ data: { session } }) => {
      const active = session?.user?.user_metadata?.active_store_id;
      if (active) setStoreId(active);
    });
    fetchStores().then(setStores);
    supabase
      .from("product_categories")
      .select("id, sleep_trial_eligible")
      .then(({ data }) => {
        const map: Record<string, boolean> = {};
        for (const c of (data as { id: string; sleep_trial_eligible: boolean }[]) ?? []) {
          map[c.id] = c.sleep_trial_eligible;
        }
        setCatEligible(map);
      });
  }, []);

  // Stock is shown at the line's sourcing location, same rule as
  // resolveLineItemLocation: pickup reads the store, delivery reads the
  // store's assigned warehouse (falling back to the store). The number is
  // labeled with that location's name so it can't be misread.
  const activeStore = stores.find((s) => s.id === storeId) ?? null;
  const sourcingId =
    fulfillment === "pickup"
      ? storeId
      : activeStore?.assigned_warehouse_id ?? storeId;
  const sourcingName =
    stores.find((s) => s.id === sourcingId)?.name ?? null;

  // Any catalog product may be the replacement; the trial-eligibility
  // predicate is only informational now. Product flag wins, NULL inherits
  // the category flag, default false — the same rule
  // stv_bind_trial_items uses. null = not yet decidable (flags loading).
  const earnsTrial = (p: Product | undefined): boolean | null => {
    if (!p) return null;
    if (p.sleep_trial_eligible !== null && p.sleep_trial_eligible !== undefined) {
      return p.sleep_trial_eligible;
    }
    if (catEligible === null) return null;
    return catEligible[p.category_id ?? ""] ?? false;
  };
  const selectedEarnsTrial = earnsTrial(selection?.product);

  async function loadQuote(productId: string | null) {
    const q = await quoteSleepTrialAction(trialItemId, "EXCHANGE", productId);
    setQuote(q);
    if (productId && q.replacement_price_cents != null) {
      setPriceInput((cur) =>
        cur === null ? centsToDollars(q.replacement_price_cents) : cur
      );
    }
  }

  useEffect(() => {
    loadQuote(null).catch((e) => setQuoteError(friendlyError(e)));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [trialItemId]);

  // Resume an existing draft: pull its stored values into the builder.
  async function resumeDraft() {
    if (!existingAction) return;
    setBusy(true);
    setError(null);
    try {
      const a = await getExchangeAction(existingAction.action_id);
      setActionId(a.action_id);
      setFulfillment(a.fulfillment_method ?? "delivery");
      setOtherFeesInput(centsToDollars(a.other_fees_cents));
      setTaxInput(centsToDollars(a.tax_cents));
      if (a.replacement_product_id) {
        // The draft stores only the product id — pull the row back for the
        // trial-eligibility check (products_public is the safe read path).
        const supabase = createClient();
        const { data: prod } = await supabase
          .from("products_public")
          .select("*")
          .eq("id", a.replacement_product_id)
          .maybeSingle();
        setSelection({
          productId: a.replacement_product_id,
          productSummary: a.replacement_product_name ?? "Replacement",
          price: (a.replacement_price_cents ?? 0) / 100,
          salePrice: null,
          product: (prod as Product) ?? undefined,
        });
        setPriceInput(centsToDollars(a.replacement_price_cents));
        await loadQuote(a.replacement_product_id);
      }
      setResuming(false);
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  async function discardExisting() {
    if (!existingAction) return;
    if (!window.confirm("Discard this exchange draft?")) return;
    setBusy(true);
    setError(null);
    try {
      await discardExchangeDraft(existingAction.action_id);
      onChanged();
      onClose();
    } catch (e) {
      setError(friendlyError(e));
      setBusy(false);
    }
  }

  async function selectReplacement(sel: ProductSelection) {
    setSelection(sel);
    setPriceInput(null);
    setPriceReason("");
    setError(null);
    if (sel.productId) {
      try {
        await loadQuote(sel.productId);
      } catch (e) {
        setError(friendlyError(e));
      }
    }
  }

  // Leaving the replacement step creates the draft (or re-points an
  // existing one at the new product, which resets its price server-side).
  async function ensureDraft(): Promise<string> {
    if (actionId) {
      await updateExchangeDraft(actionId, {
        replacementProductId: selection?.productId ?? null,
      });
      return actionId;
    }
    const id = await createExchangeDraft(
      trialItemId,
      "EXCHANGE",
      selection?.productId ?? null,
      selection?.productId ?? null,
      fulfillment,
      idempotencyKey
    );
    setActionId(id);
    createdHereRef.current = true;
    return id;
  }

  const otherFeesCents = dollarsToCents(otherFeesInput);
  const taxCents = dollarsToCents(taxInput);
  const priceCents = priceInput !== null ? dollarsToCents(priceInput) : null;
  const catalogPriceCents = quote?.replacement_price_cents ?? null;
  const priceOverridden =
    priceCents !== null &&
    catalogPriceCents !== null &&
    priceCents !== catalogPriceCents;

  const feeCents = quote?.locked_fee_cents ?? 0;
  const creditCents = quote?.original_credit_cents ?? 0;
  const replacementCents = priceCents ?? catalogPriceCents ?? 0;
  const netCents =
    replacementCents + feeCents + (otherFeesCents ?? 0) - creditCents;

  const rule = quote?.replacement_trial_preview?.rule ?? null;
  const ruleBlocks = rule !== null && rule !== "NONE";

  async function goNext() {
    setError(null);
    setBusy(true);
    try {
      if (step === "return") {
        setStep("replacement");
      } else if (step === "replacement") {
        await ensureDraft();
        setStep("money");
      } else if (step === "money") {
        await persistMoney();
        setStep("fulfillment");
      } else if (step === "fulfillment") {
        const id = actionId ?? (await ensureDraft());
        await updateExchangeDraft(id, { fulfillmentMethod: fulfillment });
        setStep("review");
      }
    } catch (e) {
      setError(friendlyError(e));
    } finally {
      setBusy(false);
    }
  }

  async function persistMoney() {
    if (otherFeesCents === null || taxCents === null) {
      throw new Error("Fees and tax must be non-negative dollar amounts.");
    }
    const id = actionId ?? (await ensureDraft());
    await updateExchangeDraft(id, {
      otherFeesCents,
      taxCents,
      ...(priceOverridden
        ? { replacementPriceCents: priceCents, priceReason: priceReason.trim() }
        : {}),
    });
  }

  async function commit() {
    const id = actionId;
    if (!id) return;
    setBusy(true);
    setError(null);
    try {
      const childId = await commitSleepTrialAction(id);
      committedRef.current = true;
      onCommitted(childId);
    } catch (e) {
      setError(friendlyError(e));
      setBusy(false);
    }
  }

  // Modal's `dirty` asks "Discard changes?" before onClose runs; a draft
  // this session created is then cancelled server-side. Anything touched
  // counts as dirty so the confirm also guards unsaved input.
  const dirty =
    !committedRef.current &&
    (actionId !== null ||
      selection !== null ||
      otherFeesInput !== "0.00" ||
      taxInput !== "0.00");

  async function handleClose() {
    if (createdHereRef.current && actionId && !committedRef.current) {
      try {
        await discardExchangeDraft(actionId);
        onChanged();
      } catch (e) {
        window.alert(
          `The draft could not be discarded: ${friendlyError(e)}`
        );
      }
    }
    onClose();
  }

  // In-modal close buttons mirror Modal's own confirm: the overlay/Esc
  // path already asks "Discard changes?" when dirty — the footer button
  // must too, or it would silently cancel the draft.
  function requestClose() {
    if (busy) return;
    if (dirty && !window.confirm("Discard changes?")) return;
    void handleClose();
  }

  const fee = quote?.action_result?.fee ?? null;
  const night = evaluation.display?.night;
  const lengthNights = evaluation.display?.length_nights;
  const itemTitle =
    [evaluation.item?.size, evaluation.item?.product_name]
      .filter(Boolean)
      .join(" · ") || "Mattress";
  const isStarter = existingAction?.created_by === currentEmployee?.id;
  const canTakeOver = isStarter || canCompleteExchange;

  return (
    <Modal onClose={() => void handleClose()} dirty={dirty} saving={busy}>
      <div className="w-full max-w-lg rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
        <h2 className="text-lg font-semibold text-slate-900">
          Exchange — {itemTitle}
        </h2>

        {resuming && existingAction ? (
          existingAction.status === "DRAFT" ? (
            <div className="mt-4">
              <p className="text-sm text-slate-700">
                An exchange draft was already started on this mattress
                {existingAction.created_by_name
                  ? ` by ${existingAction.created_by_name}`
                  : ""}
                {existingAction.created_at
                  ? ` on ${new Date(existingAction.created_at).toLocaleDateString()}`
                  : ""}
                .
              </p>
              {canTakeOver ? (
                <>
                  <p className="mt-1 text-xs text-slate-500">
                    Continue it, or discard it and start over.
                  </p>
                  <div className="mt-4 flex gap-2">
                    <button
                      onClick={resumeDraft}
                      disabled={busy}
                      className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                    >
                      {busy ? "Loading…" : "Continue draft"}
                    </button>
                    <button
                      onClick={discardExisting}
                      disabled={busy}
                      className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
                    >
                      Discard draft
                    </button>
                  </div>
                </>
              ) : (
                <p className="mt-1 text-xs text-slate-500">
                  Only {existingAction.created_by_name ?? "the starter"} or a
                  manager can continue or discard it.
                </p>
              )}
              <button
                onClick={onClose}
                className="mt-4 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Close
              </button>
            </div>
          ) : (
            <div className="mt-4">
              <p className="text-sm text-slate-700">
                This exchange is already committed.
              </p>
              <button
                onClick={onClose}
                className="mt-4 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Close
              </button>
            </div>
          )
        ) : quoteError ? (
          <p className="mt-4 rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-700">
            {quoteError}
          </p>
        ) : !quote ? (
          <p className="mt-4 text-sm text-slate-500">Loading quote…</p>
        ) : (
          <>
            {/* Step indicator */}
            <div className="mt-3 flex gap-1">
              {STEPS.map((s, i) => (
                <span
                  key={s.key}
                  className={`h-1 flex-1 rounded-full ${
                    STEPS.findIndex((x) => x.key === step) >= i
                      ? "bg-brand-500"
                      : "bg-slate-200"
                  }`}
                />
              ))}
            </div>
            <p className="mt-1 text-xs font-medium uppercase tracking-wide text-slate-500">
              {STEPS.find((s) => s.key === step)?.label}
            </p>

            {step === "return" && (
              <div className="mt-3 space-y-2 text-sm">
                <p className="font-medium text-slate-900">{itemTitle}</p>
                {night != null && (
                  <p className="text-slate-600">
                    Night {night}
                    {lengthNights != null ? ` of ${lengthNights}` : ""}
                  </p>
                )}
                {evaluation.headline?.explanation && (
                  <p className="text-slate-600">
                    {evaluation.headline.explanation}
                  </p>
                )}
                {fee && (
                  <p className="text-slate-600">
                    Exchange fee: {formatMoney(feeCents)}
                    {(() => {
                      const f = fee as {
                        window?: { label?: string } | null;
                        basis_label?: string;
                        basis_cents?: number | null;
                      };
                      return [
                        f.window?.label,
                        f.basis_label
                          ? `${formatMoney(f.basis_cents)} ${f.basis_label}`
                          : null,
                      ]
                        .filter(Boolean)
                        .map((t) => ` — ${t}`)
                        .join("");
                    })()}
                  </p>
                )}
                <p className="text-slate-600">
                  {quote.applicable_exception
                    ? "An approved exception will be applied to this exchange."
                    : "No exception applied — policy rules used as-is."}
                </p>
              </div>
            )}

            {step === "replacement" && (
              <div className="mt-3">
                <ProductPicker
                  storeId={sourcingId}
                  stockLabel={sourcingName ?? undefined}
                  allowCustom={false}
                  placeholder="Search products"
                  onSelect={selectReplacement}
                />
                {selection?.productId && (
                  <p className="mt-2 text-xs text-slate-600">
                    Replacement:{" "}
                    <span className="font-medium text-slate-800">
                      {selection.productSummary}
                    </span>
                    {" — "}
                    {formatMoney(replacementCents)}
                  </p>
                )}
                {selectedEarnsTrial === false && (
                  <p className="mt-1 text-xs text-slate-500">
                    This product does not earn a sleep trial.
                  </p>
                )}
                {rule !== null && (
                  <p
                    className={`mt-2 rounded-md p-2 text-xs ${
                      ruleBlocks
                        ? "border border-amber-300 bg-amber-50 text-amber-800"
                        : "text-slate-500"
                    }`}
                  >
                    {rule === "NONE"
                      ? "The replacement starts no new sleep trial (rule NONE)."
                      : `Policy gives the replacement a new sleep trial (rule ${rule}) — not supported yet; this exchange can't be committed.`}
                  </p>
                )}
              </div>
            )}

            {step === "money" && (
              <div className="mt-3 space-y-2 text-sm">
                <div className="flex justify-between">
                  <span className="text-slate-500">Original credit</span>
                  <span className="font-medium text-slate-900">
                    {formatMoney(creditCents)}
                  </span>
                </div>
                <div className="flex justify-between">
                  <span className="text-slate-500">Exchange fee</span>
                  <span className="font-medium text-slate-900">
                    {formatMoney(feeCents)}
                  </span>
                </div>
                <div className="flex items-center justify-between gap-3">
                  <span className="text-slate-500">Replacement price</span>
                  {canCompleteExchange ? (
                    <span className="flex items-center gap-1">
                      <span className="text-slate-400">$</span>
                      <input
                        type="text"
                        inputMode="decimal"
                        value={priceInput ?? ""}
                        onChange={(e) => setPriceInput(e.target.value)}
                        className="w-24 rounded-md border border-slate-300 px-2 py-1 text-right text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                      />
                    </span>
                  ) : (
                    <span className="font-medium text-slate-900">
                      {formatMoney(replacementCents)}
                    </span>
                  )}
                </div>
                {priceOverridden && canCompleteExchange && (
                  <input
                    type="text"
                    value={priceReason}
                    onChange={(e) => setPriceReason(e.target.value)}
                    placeholder="Reason for price override (required)"
                    className="w-full rounded-md border border-amber-300 bg-amber-50 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                  />
                )}
                <div className="flex items-center justify-between gap-3">
                  <span className="text-slate-500">Other fees</span>
                  <span className="flex items-center gap-1">
                    <span className="text-slate-400">$</span>
                    <input
                      type="text"
                      inputMode="decimal"
                      value={otherFeesInput}
                      onChange={(e) => setOtherFeesInput(e.target.value)}
                      className="w-24 rounded-md border border-slate-300 px-2 py-1 text-right text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                    />
                  </span>
                </div>
                <div className="flex items-center justify-between gap-3">
                  <span className="text-slate-500">
                    Tax
                    <span className="block text-xs font-normal text-slate-400">
                      Enter manually; tax engine not built yet
                    </span>
                  </span>
                  <span className="flex items-center gap-1">
                    <span className="text-slate-400">$</span>
                    <input
                      type="text"
                      inputMode="decimal"
                      value={taxInput}
                      onChange={(e) => setTaxInput(e.target.value)}
                      className="w-24 rounded-md border border-slate-300 px-2 py-1 text-right text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                    />
                  </span>
                </div>
                <div className="border-t border-slate-200 pt-2">
                  {netCents > 0 ? (
                    <p className="font-semibold text-slate-900">
                      Customer owes {formatMoney(netCents)}
                    </p>
                  ) : netCents < 0 ? (
                    <p className="font-semibold text-blue-700">
                      Refund owed {formatMoney(-netCents)} (record and issue it
                      in your payment system; PillowTop records it later)
                    </p>
                  ) : (
                    <p className="font-semibold text-slate-900">
                      $0 — no payment needed
                    </p>
                  )}
                  {(taxCents ?? 0) > 0 && (
                    <p className="mt-1 text-xs text-slate-500">
                      Tax of {formatMoney(taxCents)} is collected separately; it
                      is not part of the amount above.
                    </p>
                  )}
                  {ruleBlocks && (
                    <p className="mt-1 text-xs text-amber-700">
                      Commit is blocked: the replacement would get a new trial
                      (rule {rule}), which isn't supported yet.
                    </p>
                  )}
                </div>
              </div>
            )}

            {step === "fulfillment" && (
              <div className="mt-3 space-y-2 text-sm">
                <p className="text-slate-600">
                  How does the replacement get to the customer?
                </p>
                {(["delivery", "pickup"] as FulfillmentMethod[]).map((m) => (
                  <label
                    key={m}
                    className={`flex items-center gap-2 rounded-md border p-2.5 ${
                      m === "delivery" && !hasDeliveryAddress
                        ? "border-slate-200 text-slate-400"
                        : "cursor-pointer border-slate-300"
                    } ${
                      fulfillment === m
                        ? "border-brand-500 ring-1 ring-brand-500"
                        : ""
                    }`}
                  >
                    <input
                      type="radio"
                      name="fulfillment"
                      checked={fulfillment === m}
                      disabled={m === "delivery" && !hasDeliveryAddress}
                      onChange={() => setFulfillment(m)}
                    />
                    <span className="capitalize">{m}</span>
                  </label>
                ))}
                {!hasDeliveryAddress && (
                  <p className="text-xs text-amber-700">
                    The customer has no street address — add one on the journey
                    or choose pickup.
                  </p>
                )}
              </div>
            )}

            {step === "review" && (
              <div className="mt-3 space-y-2 text-sm">
                <div className="rounded-md bg-slate-50 p-3 text-sm">
                  <p className="text-slate-700">
                    Return: {itemTitle} — credit {formatMoney(creditCents)}
                  </p>
                  <p className="text-slate-700">
                    Replacement:{" "}
                    {selection?.productSummary ?? "—"} —{" "}
                    {formatMoney(replacementCents)}
                    {feeCents > 0 ? ` + fee ${formatMoney(feeCents)}` : ""}
                    {(otherFeesCents ?? 0) > 0
                      ? ` + other fees ${formatMoney(otherFeesCents)}`
                      : ""}
                  </p>
                  <p className="mt-1 font-medium text-slate-900">
                    {netCents > 0
                      ? `Customer owes ${formatMoney(netCents)}`
                      : netCents < 0
                      ? `Refund owed ${formatMoney(-netCents)}`
                      : "$0 — no payment needed"}
                    {" · "}
                    <span className="capitalize">{fulfillment}</span>
                  </p>
                </div>
                {(taxCents ?? 0) > 0 && (
                  <p className="text-xs text-slate-500">
                    Tax of {formatMoney(taxCents)} is collected separately; it
                    is not part of the amount above.
                  </p>
                )}
                {selectedEarnsTrial === false && (
                  <p className="text-xs text-slate-500">
                    This product does not earn a sleep trial.
                  </p>
                )}
                <p className="text-xs text-slate-600">
                  This ends the current sleep trial on this mattress. You can
                  cancel only until the old mattress is received.
                </p>
                {quote.applicable_exception && (
                  <p className="text-xs text-amber-700">
                    An approved exception is used up on commit and is not
                    restored by cancelling.
                  </p>
                )}
                {ruleBlocks && (
                  <p className="rounded-md border border-amber-300 bg-amber-50 p-2 text-xs text-amber-800">
                    This mattress&apos;s trial policy gives the replacement a
                    new sleep trial (rule {rule}), which is not supported yet —
                    this exchange cannot be committed.
                  </p>
                )}
              </div>
            )}

            {error && (
              <p className="mt-3 rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-700">
                {error}
              </p>
            )}

            <div className="mt-4 flex gap-2">
              {step !== "return" && (
                <button
                  onClick={() => {
                    const i = STEPS.findIndex((s) => s.key === step);
                    setStep(STEPS[i - 1].key);
                  }}
                  disabled={busy}
                  className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
                >
                  Back
                </button>
              )}
              {step !== "review" ? (
                <button
                  onClick={goNext}
                  disabled={
                    busy ||
                    (step === "replacement" && !selection?.productId) ||
                    (step === "money" &&
                      (otherFeesCents === null ||
                        taxCents === null ||
                        (priceOverridden && !priceReason.trim()))) ||
                    (step === "fulfillment" &&
                      fulfillment === "delivery" &&
                      !hasDeliveryAddress)
                  }
                  className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                >
                  {busy ? "Saving…" : "Next"}
                </button>
              ) : (
                <button
                  onClick={commit}
                  disabled={busy || ruleBlocks}
                  className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                >
                  {busy ? "Committing…" : "Commit exchange"}
                </button>
              )}
              <button
                onClick={requestClose}
                className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Close
              </button>
            </div>
          </>
        )}
      </div>
    </Modal>
  );
}
