"use client";

// C2c: spiffs page for Google review logging (every role through
// commission.spiffs_log_review) and rule management (owner and admin
// through commission.spiffs_manage). Both permissions are checked
// separately before any RPC runs; a user with neither sees only the
// denial box. Reps never see or send an amount: p_amount_cents is
// omitted entirely so the database default of 2500 cents applies
// (an explicit null would not fall back to the default and would be
// rejected). No cost field exists on this page.
//
// Reads: list_google_reviews, list_spiff_rules, fetchJourneys (order
// number lookup), searchProducts, fetchProductCategories, fetchStores
// (company id for the categories query). Writes: log_google_review,
// void_google_review, save_spiff_rule, set_spiff_rule_active.

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import Modal from "@/components/Modal";
import { createClient } from "@/lib/supabase/client";
import { hasPermission, searchProducts, type Product } from "@/lib/inventory/queries";
import {
  fetchJourneys,
  fetchStores,
  type JourneyWithDetails,
} from "@/lib/journeys/queries";
import { fetchProductCategories } from "@/lib/financing/queries";
import { localDateISO, localTodayISO } from "@/lib/dates";

type ReviewRow = {
  id: string;
  journey_id: string;
  journey_number: string | null;
  customer_name: string | null;
  review_date: string;
  amount_cents: number;
  logged_by_name: string | null;
  logged_at: string;
  voided_at: string | null;
  void_reason: string | null;
};

type RuleRow = {
  id: string;
  name: string;
  scope: "PRODUCT" | "BRAND" | "CATEGORY";
  product_id: string | null;
  product_name: string | null;
  scope_value: string | null;
  amount_cents: number;
  starts_on: string | null;
  ends_on: string | null;
  is_active: boolean;
  created_at: string;
  updated_at: string;
};

type CategoryOption = { id: string; name: string };

function money(cents: number | null): string {
  if (cents == null) return "-";
  const sign = cents < 0 ? "-" : "";
  return `${sign}$${(Math.abs(cents) / 100).toFixed(2)}`;
}

// Same typed-string pattern as /payouts and the new-order unit price
// input: digits and at most one dot while focused, reformatted on blur.
// Empty or a half-typed value reports null, never NaN.
function DollarInput({
  value,
  onChange,
  autoFocus = false,
}: {
  value: number | null;
  onChange: (v: number | null) => void;
  autoFocus?: boolean;
}) {
  const [text, setText] = useState<string | null>(null);
  return (
    <input
      type="text"
      inputMode="decimal"
      autoFocus={autoFocus}
      value={text ?? (value == null ? "" : value.toFixed(2))}
      onFocus={() => setText(value == null ? "" : value.toFixed(2))}
      onChange={(e) => {
        const s = e.target.value;
        if (!/^\d*\.?\d*$/.test(s)) return;
        setText(s);
        const n = parseFloat(s);
        onChange(Number.isFinite(n) ? n : null);
      }}
      onBlur={() => setText(null)}
      className="w-full rounded-md border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
    />
  );
}

function fmtDay(iso: string | null): string {
  if (!iso) return "";
  return new Date(`${iso}T00:00:00`).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
  });
}

function ruleDates(r: RuleRow): string {
  if (!r.starts_on && !r.ends_on) return "Always";
  if (r.starts_on && r.ends_on)
    return `${fmtDay(r.starts_on)} to ${fmtDay(r.ends_on)}`;
  if (r.starts_on) return `From ${fmtDay(r.starts_on)}`;
  return `Until ${fmtDay(r.ends_on)}`;
}

function ruleAppliesTo(r: RuleRow): string {
  if (r.scope === "PRODUCT") return `Product: ${r.product_name ?? "Unknown"}`;
  if (r.scope === "BRAND") return `Brand: ${r.scope_value ?? ""}`;
  return `Category: ${r.scope_value ?? ""}`;
}

export default function SpiffsPage() {
  const [canLog, setCanLog] = useState<boolean | null>(null);
  const [canManage, setCanManage] = useState<boolean | null>(null);
  // undefined while get_spiff_settings is still in flight so neither tab
  // can flash before the company switches are known.
  const [spiffSettings, setSpiffSettings] = useState<
    | { spiffs_enabled: boolean; google_reviews_enabled: boolean }
    | null
    | undefined
  >(undefined);
  const [tab, setTab] = useState<"reviews" | "rules">("reviews");

  // ---------- shared state ----------
  const [notice, setNotice] = useState<string | null>(null);
  const [errorMsg, setErrorMsg] = useState<string | null>(null);

  // ---------- review log form ----------
  const [orderInput, setOrderInput] = useState("");
  const [orderResolving, setOrderResolving] = useState(false);
  const [orderResolved, setOrderResolved] = useState<JourneyWithDetails | null>(
    null
  );
  const [orderTried, setOrderTried] = useState(false);
  const [reviewDate, setReviewDate] = useState(localTodayISO());
  const [reviewNote, setReviewNote] = useState("");
  const [reviewAmount, setReviewAmount] = useState<number | null>(null);
  const [logSaving, setLogSaving] = useState(false);
  const [logError, setLogError] = useState<string | null>(null);

  // ---------- review list ----------
  const [fromDate, setFromDate] = useState(() =>
    localDateISO(new Date(Date.now() - 90 * 86400000))
  );
  const [toDate, setToDate] = useState(localTodayISO());
  const [reviews, setReviews] = useState<ReviewRow[] | null>(null);
  const [reviewsLoading, setReviewsLoading] = useState(false);
  const [voidTarget, setVoidTarget] = useState<ReviewRow | null>(null);
  const [voidReason, setVoidReason] = useState("");
  const [voidSaving, setVoidSaving] = useState(false);
  const [voidError, setVoidError] = useState<string | null>(null);

  // ---------- rules ----------
  const [rules, setRules] = useState<RuleRow[] | null>(null);
  const [rulesLoading, setRulesLoading] = useState(false);
  const [ruleModal, setRuleModal] = useState<null | { editing: RuleRow | null }>(
    null
  );
  const [ruleName, setRuleName] = useState("");
  const [ruleScope, setRuleScope] = useState<"PRODUCT" | "BRAND" | "CATEGORY">(
    "BRAND"
  );
  const [ruleScopeValue, setRuleScopeValue] = useState("");
  const [ruleProduct, setRuleProduct] = useState<Product | null>(null);
  const [productQuery, setProductQuery] = useState("");
  const [productHits, setProductHits] = useState<Product[]>([]);
  const [ruleAmount, setRuleAmount] = useState<number | null>(null);
  const [ruleStart, setRuleStart] = useState("");
  const [ruleEnd, setRuleEnd] = useState("");
  const [ruleActive, setRuleActive] = useState(true);
  const [ruleSaving, setRuleSaving] = useState(false);
  const [ruleError, setRuleError] = useState<string | null>(null);
  const [brands, setBrands] = useState<string[]>([]);
  const [categories, setCategories] = useState<CategoryOption[]>([]);
  const [toggleSaving, setToggleSaving] = useState<string | null>(null);

  // ---------- gate ----------
  useEffect(() => {
    Promise.all([
      hasPermission("commission.spiffs_log_review"),
      hasPermission("commission.spiffs_manage"),
      createClient().rpc("get_spiff_settings"),
    ]).then(([log, manage, settingsRes]) => {
      const ss = settingsRes.error
        ? null
        : (settingsRes.data as {
            spiffs_enabled: boolean;
            google_reviews_enabled: boolean;
          } | null);
      setCanLog(log === true);
      setCanManage(manage === true);
      setSpiffSettings(ss);
      // Land on the first tab that can actually render: reviews for
      // anyone with it enabled, rules otherwise.
      const reviewsTab =
        log === true && ss?.google_reviews_enabled === true;
      const rulesTab = manage === true && ss?.spiffs_enabled === true;
      if (!reviewsTab && rulesTab) setTab("rules");
    });
  }, []);

  const supabase = useMemo(() => createClient(), []);

  // ---------- review list load ----------
  const loadReviews = useCallback(async () => {
    setReviewsLoading(true);
    const { data, error } = await supabase.rpc("list_google_reviews", {
      p_from: fromDate || null,
      p_to: toDate || null,
    });
    if (error) {
      setErrorMsg(error.message);
      setReviews([]);
    } else {
      setReviews((data as unknown as ReviewRow[]) ?? []);
    }
    setReviewsLoading(false);
  }, [supabase, fromDate, toDate]);

  // Reviews are only fetched while the company switch keeps them on;
  // when it is off the history listing is not needed on this page.
  useEffect(() => {
    if (canLog === true && spiffSettings?.google_reviews_enabled === true)
      loadReviews();
  }, [canLog, spiffSettings, loadReviews]);

  // ---------- rules load ----------
  const loadRules = useCallback(async () => {
    setRulesLoading(true);
    const { data, error } = await supabase.rpc("list_spiff_rules");
    if (error) {
      setErrorMsg(error.message);
      setRules([]);
    } else {
      setRules((data as unknown as RuleRow[]) ?? []);
    }
    setRulesLoading(false);
  }, [supabase]);

  useEffect(() => {
    if (canManage === true) loadRules();
  }, [canManage, loadRules]);

  // Brand suggestions and the category list are only needed once a
  // rules modal opens; load them lazily the first time.
  const ensureRuleSources = useCallback(async () => {
    if (brands.length === 0) {
      const { data } = await supabase.from("products").select("brand");
      const set = new Set<string>();
      for (const p of (data ?? []) as { brand: string | null }[]) {
        if (p.brand && p.brand.trim()) set.add(p.brand.trim());
      }
      setBrands(Array.from(set).sort());
    }
    if (categories.length === 0) {
      const stores = await fetchStores();
      const companyId = stores[0]?.company_id;
      if (companyId) {
        const cats = await fetchProductCategories(companyId);
        setCategories(cats.map((c) => ({ id: c.id, name: c.name })));
      }
    }
  }, [supabase, brands.length, categories.length]);

  // ---------- order number resolve ----------
  useEffect(() => {
    const term = orderInput.trim();
    if (!term) {
      setOrderResolved(null);
      setOrderTried(false);
      return;
    }
    setOrderResolving(true);
    const t = setTimeout(async () => {
      const hits = await fetchJourneys(undefined, term);
      const exact =
        hits.find(
          (j) =>
            j.journey_number &&
            j.journey_number.toLowerCase() === term.toLowerCase()
        ) ?? (hits.length === 1 ? hits[0] : null);
      setOrderResolved(exact ?? null);
      setOrderTried(true);
      setOrderResolving(false);
    }, 400);
    return () => clearTimeout(t);
  }, [orderInput]);

  // ---------- product search inside the rule modal ----------
  useEffect(() => {
    const q = productQuery.trim();
    if (!q || ruleProduct) {
      if (!q) setProductHits([]);
      return;
    }
    const t = setTimeout(async () => {
      setProductHits(await searchProducts(q));
    }, 300);
    return () => clearTimeout(t);
  }, [productQuery, ruleProduct]);

  // ---------- log a review ----------
  const submitReview = async () => {
    if (!orderResolved) return;
    setLogSaving(true);
    setLogError(null);
    setNotice(null);
    const args: Record<string, unknown> = {
      p_journey_id: orderResolved.id,
      p_review_date: reviewDate,
      p_note: reviewNote.trim() || null,
    };
    if (canManage === true && reviewAmount != null) {
      args.p_amount_cents = Math.round(reviewAmount * 100);
    }
    const { error } = await supabase.rpc("log_google_review", args);
    if (error) {
      setLogError(error.message);
    } else {
      setNotice("Review logged.");
      setOrderInput("");
      setOrderResolved(null);
      setOrderTried(false);
      setReviewDate(localTodayISO());
      setReviewNote("");
      setReviewAmount(null);
      loadReviews();
    }
    setLogSaving(false);
  };

  // ---------- void a review ----------
  const submitVoid = async () => {
    if (!voidTarget || !voidReason.trim()) return;
    setVoidSaving(true);
    setVoidError(null);
    const { error } = await supabase.rpc("void_google_review", {
      p_id: voidTarget.id,
      p_reason: voidReason.trim(),
    });
    if (error) {
      setVoidError(error.message);
    } else {
      setNotice("Review voided.");
      setVoidTarget(null);
      setVoidReason("");
      loadReviews();
    }
    setVoidSaving(false);
  };

  // ---------- rule modal ----------
  const openRuleModal = (editing: RuleRow | null) => {
    ensureRuleSources();
    setRuleError(null);
    setRuleModal({ editing });
    if (editing) {
      setRuleName(editing.name);
      setRuleScope(editing.scope);
      setRuleScopeValue(editing.scope === "PRODUCT" ? "" : editing.scope_value ?? "");
      setRuleProduct(
        editing.product_id
          ? ({
              id: editing.product_id,
              item_name: editing.product_name ?? "",
            } as Product)
          : null
      );
      setProductQuery("");
      setProductHits([]);
      setRuleAmount(editing.amount_cents / 100);
      setRuleStart(editing.starts_on ?? "");
      setRuleEnd(editing.ends_on ?? "");
      setRuleActive(editing.is_active);
    } else {
      setRuleName("");
      setRuleScope("BRAND");
      setRuleScopeValue("");
      setRuleProduct(null);
      setProductQuery("");
      setProductHits([]);
      setRuleAmount(null);
      setRuleStart("");
      setRuleEnd("");
      setRuleActive(true);
    }
  };

  const scopeReady =
    ruleScope === "PRODUCT"
      ? ruleProduct != null
      : ruleScopeValue.trim().length > 0;

  const saveRule = async () => {
    setRuleSaving(true);
    setRuleError(null);
    const { error } = await supabase.rpc("save_spiff_rule", {
      p_id: ruleModal?.editing?.id ?? null,
      p_name: ruleName,
      p_scope: ruleScope,
      p_product_id: ruleScope === "PRODUCT" ? ruleProduct?.id ?? null : null,
      p_scope_value: ruleScope === "PRODUCT" ? null : ruleScopeValue.trim(),
      p_amount_cents: Math.round((ruleAmount ?? 0) * 100),
      p_starts_on: ruleStart || null,
      p_ends_on: ruleEnd || null,
      p_is_active: ruleActive,
    });
    if (error) {
      setRuleError(error.message);
    } else {
      setNotice(ruleModal?.editing ? "Rule saved." : "Rule added.");
      setRuleModal(null);
      loadRules();
    }
    setRuleSaving(false);
  };

  const toggleRule = async (r: RuleRow) => {
    setToggleSaving(r.id);
    const { error } = await supabase.rpc("set_spiff_rule_active", {
      p_id: r.id,
      p_active: !r.is_active,
    });
    if (error) {
      setErrorMsg(error.message);
    } else {
      setNotice(r.is_active ? "Rule stopped." : "Rule started.");
      loadRules();
    }
    setToggleSaving(null);
  };

  // ---------- render ----------

  if (
    canLog === null ||
    canManage === null ||
    spiffSettings === undefined
  ) {
    return <p className="p-8 text-sm text-slate-500">Loading…</p>;
  }

  if (!canLog && !canManage) {
    return (
      <div className="p-8">
        <div className="max-w-md rounded-lg border border-slate-200 bg-white px-4 py-6 text-center text-sm text-slate-600">
          You do not have access to spiffs.
        </div>
      </div>
    );
  }

  const reviewsOn = spiffSettings?.google_reviews_enabled === true;
  const spiffsOn = spiffSettings?.spiffs_enabled === true;
  const showReviewsTab = canLog && reviewsOn;
  const showRulesTab = canManage && spiffsOn;
  const tabs = [
    ...(showReviewsTab ? (["reviews"] as const) : []),
    ...(showRulesTab ? (["rules"] as const) : []),
  ];

  // Direct URL case: the visitor has permission but every tab is gated
  // off by the company switches.
  if (tabs.length === 0) {
    return (
      <div className="p-8">
        <div className="max-w-md rounded-lg border border-slate-200 bg-white px-4 py-6 text-center text-sm text-slate-600">
          Spiffs are turned off for this company.
        </div>
      </div>
    );
  }

  const inputCls =
    "rounded-md border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500";

  return (
    <div className="mx-auto max-w-5xl p-6">
      <h1 className="mb-4 text-xl font-semibold text-slate-900">
        {canManage ? "Spiffs" : "Reviews"}
      </h1>

      {tabs.length > 1 && (
        <div className="mb-4 flex gap-1 border-b border-slate-200">
          {tabs.map((t) => (
            <button
              key={t}
              onClick={() => setTab(t)}
              className={`px-4 py-2 text-sm font-medium ${
                tab === t
                  ? "border-b-2 border-brand-600 text-brand-700"
                  : "text-slate-500 hover:text-slate-700"
              }`}
            >
              {t === "reviews" ? "Google reviews" : "Rules"}
            </button>
          ))}
        </div>
      )}

      {notice && (
        <p className="mb-3 rounded-md border border-green-200 bg-green-50 px-3 py-2 text-sm text-green-800">
          {notice}
        </p>
      )}
      {errorMsg && (
        <p className="mb-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
          {errorMsg}
        </p>
      )}

      {tab === "reviews" && showReviewsTab && (
        <>
          {/* ---------- log a review ---------- */}
          <div className="mb-6 rounded-lg border border-slate-200 bg-white p-4">
            <h2 className="mb-3 text-sm font-semibold text-slate-900">
              Log a Google review
            </h2>
            <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
              <label className="text-xs font-medium text-slate-600">
                Order number
                <input
                  type="text"
                  value={orderInput}
                  onChange={(e) => setOrderInput(e.target.value)}
                  placeholder="SJ-MS00288"
                  className={`mt-1 w-full ${inputCls}`}
                />
              </label>
              <label className="text-xs font-medium text-slate-600">
                Review date
                <input
                  type="date"
                  value={reviewDate}
                  max={localTodayISO()}
                  onChange={(e) => setReviewDate(e.target.value)}
                  className={`mt-1 w-full ${inputCls}`}
                />
              </label>
              <label className="text-xs font-medium text-slate-600 sm:col-span-2">
                Note (optional)
                <input
                  type="text"
                  value={reviewNote}
                  onChange={(e) => setReviewNote(e.target.value)}
                  className={`mt-1 w-full ${inputCls}`}
                />
              </label>
              {canManage && (
                <label className="text-xs font-medium text-slate-600">
                  Amount ($, optional)
                  <div className="mt-1">
                    <DollarInput value={reviewAmount} onChange={setReviewAmount} />
                  </div>
                </label>
              )}
            </div>

            {orderResolving && (
              <p className="mt-2 text-xs text-slate-500">Looking up order…</p>
            )}
            {!orderResolving && orderResolved && (
              <p className="mt-2 text-xs text-green-700">
                {orderResolved.customer
                  ? `${orderResolved.customer.first_name} ${orderResolved.customer.last_name}`
                  : "Customer"}{" "}
                - {orderResolved.current_state}
              </p>
            )}
            {!orderResolving && orderTried && !orderResolved && orderInput.trim() && (
              <p className="mt-2 text-xs text-red-600">
                No order found with that number.
              </p>
            )}
            {logError && (
              <p className="mt-2 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
                {logError}
              </p>
            )}
            <div className="mt-3">
              <button
                onClick={submitReview}
                disabled={!orderResolved || logSaving}
                className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:cursor-not-allowed disabled:opacity-50"
              >
                {logSaving ? "Saving…" : "Log review"}
              </button>
            </div>
          </div>

          {/* ---------- review list ---------- */}
          <div className="mb-3 flex flex-wrap items-end gap-3">
            <label className="text-xs font-medium text-slate-600">
              From
              <input
                type="date"
                value={fromDate}
                onChange={(e) => setFromDate(e.target.value)}
                className={`ml-1 ${inputCls}`}
              />
            </label>
            <label className="text-xs font-medium text-slate-600">
              To
              <input
                type="date"
                value={toDate}
                onChange={(e) => setToDate(e.target.value)}
                className={`ml-1 ${inputCls}`}
              />
            </label>
          </div>

          <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
            <table className="min-w-full divide-y divide-slate-200 text-sm">
              <thead>
                <tr className="text-left text-xs font-medium uppercase tracking-wide text-slate-500">
                  <th className="px-3 py-2">Order</th>
                  <th className="px-3 py-2">Customer</th>
                  <th className="px-3 py-2">Review date</th>
                  <th className="px-3 py-2 text-right">Amount</th>
                  <th className="px-3 py-2">Logged by</th>
                  <th className="px-3 py-2">Logged on</th>
                  <th className="px-3 py-2">Status</th>
                  {canManage && <th className="px-3 py-2" />}
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {reviewsLoading && (
                  <tr>
                    <td
                      colSpan={8}
                      className="px-3 py-3 text-center text-sm text-slate-500"
                    >
                      Loading…
                    </td>
                  </tr>
                )}
                {!reviewsLoading && (reviews ?? []).length === 0 && (
                  <tr>
                    <td
                      colSpan={8}
                      className="px-3 py-6 text-center text-sm text-slate-500"
                    >
                      No Google reviews logged for these dates.
                    </td>
                  </tr>
                )}
                {(reviews ?? []).map((r) => (
                  <tr key={r.id} className="align-top">
                    <td className="whitespace-nowrap px-3 py-2">
                      <Link
                        href={`/board?journey=${r.journey_id}`}
                        className="text-brand-600 hover:text-brand-700 hover:underline"
                      >
                        {r.journey_number ?? "View order"}
                      </Link>
                    </td>
                    <td className="px-3 py-2 text-slate-700">
                      {r.customer_name ?? ""}
                    </td>
                    <td className="whitespace-nowrap px-3 py-2 text-slate-700">
                      {r.review_date}
                    </td>
                    <td className="whitespace-nowrap px-3 py-2 text-right text-slate-700">
                      {r.voided_at ? (
                        <span className="line-through">
                          {money(r.amount_cents)}
                        </span>
                      ) : (
                        money(r.amount_cents)
                      )}
                    </td>
                    <td className="px-3 py-2 text-slate-700">
                      {r.logged_by_name ?? ""}
                    </td>
                    <td className="whitespace-nowrap px-3 py-2 text-slate-700">
                      {localDateISO(r.logged_at)}
                    </td>
                    <td className="px-3 py-2 text-slate-700">
                      {r.voided_at ? (
                        <span>
                          <span className="mr-1 rounded-full bg-slate-100 px-2 py-0.5 text-xs text-slate-600">
                            Voided
                          </span>
                          {r.void_reason && (
                            <span className="text-xs text-slate-500">
                              {r.void_reason}
                            </span>
                          )}
                        </span>
                      ) : (
                        <span className="text-xs text-slate-400">Active</span>
                      )}
                    </td>
                    {canManage && (
                      <td className="whitespace-nowrap px-3 py-2 text-right">
                        {!r.voided_at && (
                          <button
                            onClick={() => {
                              setVoidTarget(r);
                              setVoidReason("");
                              setVoidError(null);
                            }}
                            className="text-xs font-medium text-red-600 hover:text-red-700 hover:underline"
                          >
                            Void
                          </button>
                        )}
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}

      {tab === "rules" && showRulesTab && (
        <>
          <div className="mb-3 flex items-center justify-between">
            <p className="text-sm text-slate-500">
              Spiffs are calculated automatically when an order is sold.
            </p>
            <button
              onClick={() => openRuleModal(null)}
              className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700"
            >
              Add rule
            </button>
          </div>
          <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
            <table className="min-w-full divide-y divide-slate-200 text-sm">
              <thead>
                <tr className="text-left text-xs font-medium uppercase tracking-wide text-slate-500">
                  <th className="px-3 py-2">Name</th>
                  <th className="px-3 py-2">Applies to</th>
                  <th className="px-3 py-2 text-right">Amount per unit</th>
                  <th className="px-3 py-2">Dates</th>
                  <th className="px-3 py-2">Status</th>
                  <th className="px-3 py-2" />
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {rulesLoading && (
                  <tr>
                    <td
                      colSpan={6}
                      className="px-3 py-3 text-center text-sm text-slate-500"
                    >
                      Loading…
                    </td>
                  </tr>
                )}
                {!rulesLoading && (rules ?? []).length === 0 && (
                  <tr>
                    <td
                      colSpan={6}
                      className="px-3 py-6 text-center text-sm text-slate-500"
                    >
                      No spiff rules yet.
                    </td>
                  </tr>
                )}
                {(rules ?? []).map((r) => (
                  <tr key={r.id} className="align-top">
                    <td className="px-3 py-2 font-medium text-slate-800">
                      {r.name}
                    </td>
                    <td className="px-3 py-2 text-slate-700">
                      {ruleAppliesTo(r)}
                    </td>
                    <td className="whitespace-nowrap px-3 py-2 text-right text-slate-700">
                      {money(r.amount_cents)}
                    </td>
                    <td className="whitespace-nowrap px-3 py-2 text-slate-700">
                      {ruleDates(r)}
                    </td>
                    <td className="px-3 py-2">
                      <span
                        className={`rounded-full px-2 py-0.5 text-xs ${
                          r.is_active
                            ? "bg-green-100 text-green-800"
                            : "bg-slate-100 text-slate-600"
                        }`}
                      >
                        {r.is_active ? "On" : "Stopped"}
                      </span>
                    </td>
                    <td className="whitespace-nowrap px-3 py-2 text-right">
                      <button
                        onClick={() => openRuleModal(r)}
                        className="mr-3 text-xs font-medium text-brand-600 hover:text-brand-700 hover:underline"
                      >
                        Edit
                      </button>
                      <button
                        onClick={() => toggleRule(r)}
                        disabled={toggleSaving === r.id}
                        className="text-xs font-medium text-slate-600 hover:text-slate-800 hover:underline disabled:opacity-50"
                      >
                        {r.is_active ? "Stop" : "Start"}
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}

      {/* ---------- void modal ---------- */}
      {voidTarget && (
        <Modal
          onClose={() => setVoidTarget(null)}
          saving={voidSaving}
          dirty={voidReason.trim().length > 0}
        >
          <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-xl">
            <h3 className="mb-1 text-base font-semibold text-slate-900">
              Void this review?
            </h3>
            <p className="mb-3 text-sm text-slate-600">
              The spiff is taken back in the current month. Nothing is
              deleted.
            </p>
            <label className="block text-xs font-medium text-slate-600">
              Reason (required)
              <input
                type="text"
                autoFocus
                value={voidReason}
                onChange={(e) => setVoidReason(e.target.value)}
                className={`mt-1 w-full ${inputCls}`}
              />
            </label>
            {voidError && (
              <p className="mt-2 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
                {voidError}
              </p>
            )}
            <div className="mt-4 flex justify-end gap-2">
              <button
                onClick={() => setVoidTarget(null)}
                className="rounded-md border border-slate-300 px-4 py-2 text-sm text-slate-700 hover:bg-slate-50"
              >
                Cancel
              </button>
              <button
                onClick={submitVoid}
                disabled={!voidReason.trim() || voidSaving}
                className="rounded-md bg-red-600 px-4 py-2 text-sm font-medium text-white hover:bg-red-700 disabled:cursor-not-allowed disabled:opacity-50"
              >
                {voidSaving ? "Voiding…" : "Void review"}
              </button>
            </div>
          </div>
        </Modal>
      )}

      {/* ---------- rule modal ---------- */}
      {ruleModal && (
        <Modal
          onClose={() => setRuleModal(null)}
          saving={ruleSaving}
          dirty={ruleName.trim().length > 0}
        >
          <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-xl">
            <h3 className="mb-3 text-base font-semibold text-slate-900">
              {ruleModal.editing ? "Edit rule" : "Add rule"}
            </h3>
            <div className="space-y-3">
              <label className="block text-xs font-medium text-slate-600">
                Name
                <input
                  type="text"
                  autoFocus
                  value={ruleName}
                  onChange={(e) => setRuleName(e.target.value)}
                  className={`mt-1 w-full ${inputCls}`}
                />
              </label>
              <label className="block text-xs font-medium text-slate-600">
                Applies to
                <select
                  value={ruleScope}
                  onChange={(e) => {
                    setRuleScope(
                      e.target.value as "PRODUCT" | "BRAND" | "CATEGORY"
                    );
                  }}
                  className={`mt-1 w-full ${inputCls}`}
                >
                  <option value="BRAND">Brand</option>
                  <option value="CATEGORY">Category</option>
                  <option value="PRODUCT">Product</option>
                </select>
              </label>

              {ruleScope === "BRAND" && (
                <label className="block text-xs font-medium text-slate-600">
                  Brand
                  <input
                    type="text"
                    list="spiff-brand-suggestions"
                    value={ruleScopeValue}
                    onChange={(e) => setRuleScopeValue(e.target.value)}
                    className={`mt-1 w-full ${inputCls}`}
                  />
                  <datalist id="spiff-brand-suggestions">
                    {brands.map((b) => (
                      <option key={b} value={b} />
                    ))}
                  </datalist>
                </label>
              )}

              {ruleScope === "CATEGORY" && (
                <label className="block text-xs font-medium text-slate-600">
                  Category
                  <select
                    value={ruleScopeValue}
                    onChange={(e) => setRuleScopeValue(e.target.value)}
                    className={`mt-1 w-full ${inputCls}`}
                  >
                    <option value="">Choose a category</option>
                    {categories.map((c) => (
                      <option key={c.id} value={c.name}>
                        {c.name}
                      </option>
                    ))}
                  </select>
                </label>
              )}

              {ruleScope === "PRODUCT" && (
                <div className="text-xs font-medium text-slate-600">
                  Product
                  {ruleProduct ? (
                    <div className="mt-1 flex items-center justify-between rounded-md border border-slate-300 px-2 py-1 text-sm">
                      <span>{ruleProduct.item_name}</span>
                      <button
                        onClick={() => {
                          setRuleProduct(null);
                          setProductQuery("");
                        }}
                        className="text-xs text-brand-600 hover:underline"
                      >
                        Change
                      </button>
                    </div>
                  ) : (
                    <>
                      <input
                        type="text"
                        value={productQuery}
                        onChange={(e) => setProductQuery(e.target.value)}
                        placeholder="Search products"
                        className={`mt-1 w-full ${inputCls}`}
                      />
                      {productHits.length > 0 && (
                        <ul className="mt-1 max-h-40 overflow-y-auto rounded-md border border-slate-200">
                          {productHits.map((p) => (
                            <li key={p.id}>
                              <button
                                onClick={() => {
                                  setRuleProduct(p);
                                  setProductHits([]);
                                }}
                                className="block w-full px-2 py-1 text-left text-sm hover:bg-slate-50"
                              >
                                {p.item_name}
                                {p.brand && (
                                  <span className="ml-1 text-slate-400">
                                    ({p.brand})
                                  </span>
                                )}
                              </button>
                            </li>
                          ))}
                        </ul>
                      )}
                    </>
                  )}
                </div>
              )}

              <label className="block text-xs font-medium text-slate-600">
                Amount per unit ($)
                <div className="mt-1">
                  <DollarInput value={ruleAmount} onChange={setRuleAmount} />
                </div>
              </label>
              <div className="grid grid-cols-2 gap-3">
                <label className="block text-xs font-medium text-slate-600">
                  Start date (optional)
                  <input
                    type="date"
                    value={ruleStart}
                    onChange={(e) => setRuleStart(e.target.value)}
                    className={`mt-1 w-full ${inputCls}`}
                  />
                </label>
                <label className="block text-xs font-medium text-slate-600">
                  End date (optional)
                  <input
                    type="date"
                    value={ruleEnd}
                    onChange={(e) => setRuleEnd(e.target.value)}
                    className={`mt-1 w-full ${inputCls}`}
                  />
                </label>
              </div>
              {ruleModal.editing && (
                <label className="flex items-center gap-2 text-xs font-medium text-slate-600">
                  <input
                    type="checkbox"
                    checked={ruleActive}
                    onChange={(e) => setRuleActive(e.target.checked)}
                  />
                  Rule is on
                </label>
              )}
              <p className="rounded-md bg-slate-50 px-3 py-2 text-xs text-slate-600">
                Rules apply to sales made from now on. Past sales are not
                changed. Spiffs are calculated automatically when an order
                is sold.
              </p>
              {ruleError && (
                <p className="rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
                  {ruleError}
                </p>
              )}
            </div>
            <div className="mt-4 flex justify-end gap-2">
              <button
                onClick={() => setRuleModal(null)}
                className="rounded-md border border-slate-300 px-4 py-2 text-sm text-slate-700 hover:bg-slate-50"
              >
                Cancel
              </button>
              <button
                onClick={saveRule}
                disabled={
                  !ruleName.trim() ||
                  !scopeReady ||
                  ruleAmount == null ||
                  ruleAmount <= 0 ||
                  ruleSaving
                }
                className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:cursor-not-allowed disabled:opacity-50"
              >
                {ruleSaving ? "Saving…" : "Save rule"}
              </button>
            </div>
          </div>
        </Modal>
      )}
    </div>
  );
}
