"use client";

import { useEffect, useMemo, useState } from "react";
import { X, Calculator, ArrowRight, RefreshCw, ChevronDown, ChevronUp } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import Modal from "@/components/Modal";
import { searchProducts, type Product } from "@/lib/inventory/queries";
import {
  fetchFinancingTiers,
  fetchAccessoryCategories,
  fetchAccessoryPins,
  fetchAccessoryBundles,
  fetchBundleComponents,
} from "@/lib/financing/queries";
import type {
  FinancingTier,
  AccessoryCategory,
  AccessoryPin,
  AccessoryBundle,
  AccessoryBundleComponent,
} from "@/lib/financing/types";
import {
  getTier,
  getTerms,
  computePayments,
  resolveAccessory,
  recomputeWithProduct,
  type PaymentRow,
  type ResolvedAccessory,
} from "@/lib/financing/calculator";

function getEffectivePrice(product: Product | null): number {
  return product?.sale_price ?? product?.price ?? 0;
}

type Props = {
  companyId: string;
  onClose: () => void;
};

export default function FinancingCalculator({ companyId, onClose }: Props) {
  // ---- Config data ----
  const [tiers, setTiers] = useState<FinancingTier[]>([]);
  const [accCats, setAccCats] = useState<AccessoryCategory[]>([]);
  const [pins, setPins] = useState<AccessoryPin[]>([]);
  const [bundles, setBundles] = useState<AccessoryBundle[]>([]);
  const [bundleComps, setBundleComps] = useState<Record<string, string[]>>({});
  const [configLoaded, setConfigLoaded] = useState(false);

  // ---- Product search ----
  const [query, setQuery] = useState("");
  const [debouncedQuery, setDebouncedQuery] = useState("");
  const [searchResults, setSearchResults] = useState<Product[]>([]);
  const [searching, setSearching] = useState(false);

  // ---- Selected item ----
  const [selectedProduct, setSelectedProduct] = useState<Product | null>(null);
  const [priceOverride, setPriceOverride] = useState<string>("");

  // ---- Accessory products (products in each accessory category) ----
  const [accessoryProducts, setAccessoryProducts] = useState<Record<string, Product[]>>({});

  // ---- Resolved accessories ----
  const [resolvedAccessories, setResolvedAccessories] = useState<ResolvedAccessory[]>([]);

  // ---- Swap UI ----
  const [swapOpen, setSwapOpen] = useState<string | null>(null);

  // ---- Bundle view ----
  const [expandedBundle, setExpandedBundle] = useState<string | null>(null);

  // Load configuration
  useEffect(() => {
    (async () => {
      const [ft, ac, ap, ab] = await Promise.all([
        fetchFinancingTiers(companyId),
        fetchAccessoryCategories(companyId),
        fetchAccessoryPins(companyId),
        fetchAccessoryBundles(companyId),
      ]);
      setTiers(ft);
      setAccCats(ac.filter((c) => c.enabled_for_suggestions));
      setPins(ap);
      setBundles(ab);

      // Load bundle components
      const compMap: Record<string, string[]> = {};
      await Promise.all(
        ab.map(async (b) => {
          const comps = await fetchBundleComponents(b.id);
          compMap[b.id] = comps.map((c) => c.accessory_category_id);
        })
      );
      setBundleComps(compMap);

      // Load products for each enabled accessory category
      const enabledCats = ac.filter((c) => c.enabled_for_suggestions);
      if (enabledCats.length > 0) {
        const supabase = createClient();
        const catIds = enabledCats.map((c) => c.category_id);
        const { data } = await (supabase as any)
          .from("products_public")
          .select("id, company_id, sku, item_name, brand, price, sale_price, category_id, search_text, created_at, updated_at")
          .eq("company_id", companyId)
          .in("category_id", catIds)
          .order("item_name");
        const prods = (data ?? []) as Product[];
        const map: Record<string, Product[]> = {};
        for (const cat of enabledCats) {
          map[cat.category_id] = prods.filter((p) => p.category_id === cat.category_id);
        }
        setAccessoryProducts(map);
      }

      setConfigLoaded(true);
    })();
  }, [companyId]);

  // Debounced search
  useEffect(() => {
    const t = setTimeout(() => setDebouncedQuery(query), 300);
    return () => clearTimeout(t);
  }, [query]);

  useEffect(() => {
    let ignore = false;
    if (!debouncedQuery.trim()) {
      setSearchResults([]);
      return () => { ignore = true; };
    }
    setSearching(true);
    searchProducts(debouncedQuery).then((res) => {
      if (!ignore) {
        setSearchResults(res);
        setSearching(false);
      }
    });
    return () => { ignore = true; };
  }, [debouncedQuery]);

  // Effective price (override or product price)
  const effectivePrice = useMemo(() => {
    if (priceOverride.trim() !== "") {
      const n = Number(priceOverride);
      if (!isNaN(n) && n >= 0) return n;
    }
    return getEffectivePrice(selectedProduct);
  }, [priceOverride, selectedProduct]);

  // Compute tier, terms, payments for the item alone
  const itemTier = useMemo(() => getTier(effectivePrice, tiers), [effectivePrice, tiers]);
  const itemTerms = useMemo(() => getTerms(effectivePrice, tiers), [effectivePrice, tiers]);
  const itemPayments = useMemo(() => computePayments(effectivePrice, itemTerms), [effectivePrice, itemTerms]);

  // Resolve accessories whenever item or config changes
  useEffect(() => {
    if (!selectedProduct && priceOverride.trim() === "") {
      setResolvedAccessories([]);
      return;
    }
    const resolved = accCats.map((ac) =>
      resolveAccessory({
        accCat: ac,
        itemPrice: effectivePrice,
        itemTier,
        itemTerms,
        tiers,
        pins,
        candidateProducts: accessoryProducts[ac.category_id] ?? [],
      })
    );
    setResolvedAccessories(resolved);
  }, [effectivePrice, itemTier, itemTerms, accCats, tiers, pins, accessoryProducts, selectedProduct, priceOverride]);

  function selectProduct(product: Product) {
    setSelectedProduct(product);
    setPriceOverride("");
    setQuery("");
    setSearchResults([]);
  }

  function handleSwap(accIdx: number, product: Product) {
    setResolvedAccessories((prev) =>
      prev.map((r, i) =>
        i === accIdx ? recomputeWithProduct(r, product, effectivePrice, tiers, itemTerms) : r
      )
    );
    setSwapOpen(null);
  }

  const hasItem = selectedProduct !== null || (priceOverride.trim() !== "" && effectivePrice > 0);

  return (
    <Modal
      onClose={onClose}
      overlayClassName="fixed inset-0 z-50 flex items-start justify-center overflow-y-auto bg-slate-900/50 p-4 pt-12"
      dirty={
        selectedProduct !== null ||
        priceOverride.trim() !== "" ||
        query.trim() !== "" ||
        resolvedAccessories.length > 0
      }
    >
      <div className="w-full max-w-3xl rounded-lg border border-slate-200 bg-white shadow-lg">
        {/* Header */}
        <div className="flex items-center justify-between border-b border-slate-200 px-6 py-4">
          <div className="flex items-center gap-2">
            <Calculator className="h-5 w-5 text-brand-600" />
            <h2 className="text-lg font-semibold text-slate-900">Financing Calculator</h2>
          </div>
          <button onClick={onClose} className="rounded-md p-1 text-slate-500 hover:bg-slate-100">
            <X className="h-5 w-5" />
          </button>
        </div>

        <div className="p-6 space-y-6">
          {!configLoaded ? (
            <p className="text-sm text-slate-500">Loading...</p>
          ) : tiers.length === 0 ? (
            <p className="text-sm text-slate-500">
              No financing tiers configured. An admin can set them up in Settings &rarr; Financing &amp; Accessories.
            </p>
          ) : (
            <>
              {/* Product Search */}
              <div className="space-y-2">
                <label className="block text-sm font-medium text-slate-700">Product</label>
                <div className="relative">
                  <input
                    type="text"
                    value={query}
                    onChange={(e) => {
                      setQuery(e.target.value);
                      if (selectedProduct) setSelectedProduct(null);
                    }}
                    placeholder="Search products..."
                    className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                  />
                </div>

                {searching && <p className="text-xs text-slate-500">Searching...</p>}

                {!searching && searchResults.length > 0 && !selectedProduct && (
                  <ul className="max-h-48 overflow-y-auto rounded-md border border-slate-200 bg-white shadow-sm">
                    {searchResults.map((p) => (
                      <li
                        key={p.id}
                        onClick={() => selectProduct(p)}
                        className="cursor-pointer border-b border-slate-100 px-3 py-2 text-sm hover:bg-slate-50 last:border-b-0"
                      >
                        <div className="flex items-center justify-between">
                          <div>
                            <span className="font-medium text-slate-900">{p.item_name}</span>
                            {p.brand && <span className="ml-1 text-slate-500">({p.brand})</span>}
                          </div>
                          <span className="text-sm font-medium text-slate-700">
                            {getEffectivePrice(p) > 0 ? `$${getEffectivePrice(p).toFixed(2)}` : "No price"}
                            {p.sale_price !== null && p.sale_price < (p.price ?? Infinity) && (
                              <span className="ml-1 text-xs text-slate-400 line-through">${p.price?.toFixed(2)}</span>
                            )}
                          </span>
                        </div>
                      </li>
                    ))}
                  </ul>
                )}

                {selectedProduct && (
                  <p className="text-sm text-slate-600">
                    Selected: <span className="font-medium text-slate-900">{selectedProduct.item_name}</span>
                    {selectedProduct.brand ? ` (${selectedProduct.brand})` : ""}
                    {getEffectivePrice(selectedProduct) > 0 && (
                      <span className="ml-2 text-slate-500">
                        Catalog: ${getEffectivePrice(selectedProduct).toFixed(2)}
                        {selectedProduct.sale_price !== null && selectedProduct.sale_price < (selectedProduct.price ?? Infinity) && (
                          <span className="ml-1 text-xs text-slate-400 line-through">${selectedProduct.price?.toFixed(2)}</span>
                        )}
                      </span>
                    )}
                  </p>
                )}

                <div className="flex items-end gap-3">
                  <div className="w-40">
                    <label className="block text-xs font-medium text-slate-500">Price Override</label>
                    <input
                      type="number"
                      min="0"
                      step="0.01"
                      value={priceOverride}
                      onChange={(e) => setPriceOverride(e.target.value)}
                      placeholder={getEffectivePrice(selectedProduct) > 0 ? getEffectivePrice(selectedProduct).toFixed(2) : "Enter price"}
                      className="mt-1 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                    />
                  </div>
                  {hasItem && (
                    <span className="mb-1 text-sm font-medium text-slate-900">
                      Using: ${effectivePrice.toFixed(2)}
                    </span>
                  )}
                </div>
              </div>

              {/* Item-alone results */}
              {hasItem && (
                <div className="space-y-3">
                  <div className="flex items-center gap-2">
                    <h3 className="text-sm font-semibold text-slate-900">Item Alone</h3>
                    {itemTier && (
                      <span className="rounded-full bg-brand-100 px-2 py-0.5 text-xs font-medium text-brand-700">
                        Tier: ${itemTier.min_price} &ndash; {itemTier.max_price === null ? "∞" : `$${itemTier.max_price}`}
                      </span>
                    )}
                  </div>

                  {itemPayments.length > 0 ? (
                    <PaymentTable payments={itemPayments} />
                  ) : (
                    <p className="text-sm text-slate-400">No financing terms available at this price.</p>
                  )}
                </div>
              )}

              {/* Accessory suggestions */}
              {hasItem && resolvedAccessories.length > 0 && (
                <div className="space-y-4">
                  <h3 className="text-sm font-semibold text-slate-900">Accessory Suggestions</h3>

                  {resolvedAccessories.map((ra, idx) => (
                    <AccessoryCard
                      key={ra.accessoryCategoryId}
                      ra={ra}
                      idx={idx}
                      itemPayments={itemPayments}
                      itemTerms={itemTerms}
                      swapOpen={swapOpen === ra.accessoryCategoryId}
                      onToggleSwap={() =>
                        setSwapOpen(
                          swapOpen === ra.accessoryCategoryId ? null : ra.accessoryCategoryId
                        )
                      }
                      onSwap={(product) => handleSwap(idx, product)}
                    />
                  ))}
                </div>
              )}

              {/* Bundles */}
              {hasItem && bundles.length > 0 && (
                <div className="space-y-3">
                  <h3 className="text-sm font-semibold text-slate-900">Bundles</h3>
                  {bundles.map((b) => {
                    const catIds = bundleComps[b.id] ?? [];
                    const bundleAccessories = resolvedAccessories.filter((ra) =>
                      catIds.includes(ra.accessoryCategoryId)
                    );
                    if (bundleAccessories.length === 0) return null;

                    // Compute combined bundle price
                    let bundleTotal = effectivePrice;
                    for (const ba of bundleAccessories) {
                      const ap = getEffectivePrice(ba.suggestedProduct);
                      bundleTotal += ap * ba.defaultQty;
                    }
                    const bundleTier = getTier(bundleTotal, tiers);
                    const bundleTerms = bundleTier
                      ? [...bundleTier.term_lengths].sort((a, b) => a - b)
                      : [];
                    const bundlePayments = computePayments(bundleTotal, bundleTerms);
                    const bundleBump =
                      !!bundleTier &&
                      !!itemTier &&
                      bundleTier.id !== itemTier.id &&
                      bundleTier.sort_order > itemTier.sort_order;

                    const isExpanded = expandedBundle === b.id;

                    return (
                      <div
                        key={b.id}
                        className="rounded-lg border border-slate-200 bg-white"
                      >
                        <button
                          onClick={() => setExpandedBundle(isExpanded ? null : b.id)}
                          className="flex w-full items-center justify-between px-4 py-3 text-left"
                        >
                          <div className="flex items-center gap-2">
                            <span className="text-sm font-medium text-slate-900">{b.name}</span>
                            <span className="text-sm text-slate-500">
                              ${bundleTotal.toFixed(2)} total
                            </span>
                            {bundleBump && (
                              <span className="rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-700">
                                Tier unlocked
                              </span>
                            )}
                          </div>
                          {isExpanded ? (
                            <ChevronUp className="h-4 w-4 text-slate-400" />
                          ) : (
                            <ChevronDown className="h-4 w-4 text-slate-400" />
                          )}
                        </button>
                        {isExpanded && (
                          <div className="border-t border-slate-100 px-4 py-3 space-y-3">
                            <div className="text-xs text-slate-500">
                              Includes:{" "}
                              {bundleAccessories
                                .map(
                                  (ba) =>
                                    `${ba.categoryName}${
                                      ba.suggestedProduct
                                        ? ` (${ba.suggestedProduct.item_name})`
                                        : ""
                                    }`
                                )
                                .join(", ")}
                            </div>
                            {bundlePayments.length > 0 ? (
                              <PaymentTable payments={bundlePayments} />
                            ) : (
                              <p className="text-sm text-slate-400">
                                No financing terms at this bundle price.
                              </p>
                            )}
                          </div>
                        )}
                      </div>
                    );
                  })}
                </div>
              )}
            </>
          )}
        </div>
      </div>
    </Modal>
  );
}

// ---- Sub-components ----

function PaymentTable({ payments }: { payments: PaymentRow[] }) {
  return (
    <div className="overflow-hidden rounded-md border border-slate-200">
      <table className="w-full text-sm">
        <thead className="bg-slate-50">
          <tr>
            <th className="px-3 py-2 text-left font-medium text-slate-600">Term</th>
            <th className="px-3 py-2 text-right font-medium text-slate-600">Monthly Payment</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100">
          {payments.map((p) => (
            <tr key={p.term}>
              <td className="px-3 py-2 text-slate-700">{p.term} months</td>
              <td className="px-3 py-2 text-right font-medium text-slate-900">
                ${p.monthlyPayment.toFixed(2)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

function AccessoryCard({
  ra,
  idx,
  itemPayments,
  itemTerms,
  swapOpen,
  onToggleSwap,
  onSwap,
}: {
  ra: ResolvedAccessory;
  idx: number;
  itemPayments: PaymentRow[];
  itemTerms: number[];
  swapOpen: boolean;
  onToggleSwap: () => void;
  onSwap: (product: Product) => void;
}) {
  const itemPaymentMap = useMemo(() => {
    const m: Record<number, number> = {};
    for (const p of itemPayments) m[p.term] = p.monthlyPayment;
    return m;
  }, [itemPayments]);

  return (
    <div className="rounded-lg border border-slate-200 bg-white p-4 space-y-3">
      <div className="flex items-center justify-between">
        <div className="flex items-center gap-2">
          <h4 className="text-sm font-semibold text-slate-900">{ra.categoryName}</h4>
          {ra.tierBump && (
            <span className="rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-700">
              Tier unlocked
            </span>
          )}
        </div>
        {ra.allProducts.length > 1 && (
          <button
            onClick={onToggleSwap}
            className="inline-flex items-center gap-1 text-xs text-brand-600 hover:text-brand-700"
          >
            <RefreshCw className="h-3 w-3" /> Swap
          </button>
        )}
      </div>

      {ra.matchMode === "show_all" && !ra.suggestedProduct ? (
        <div className="space-y-1">
          <p className="text-xs text-slate-500">Select a product:</p>
          <ul className="max-h-40 overflow-y-auto divide-y divide-slate-100 rounded-md border border-slate-200">
            {ra.allProducts.map((p) => (
              <li
                key={p.id}
                onClick={() => onSwap(p)}
                className="flex cursor-pointer items-center justify-between px-3 py-1.5 text-sm hover:bg-slate-50"
              >
                <span className="text-slate-700">{p.item_name}</span>
                <span className="text-slate-500">
                  ${getEffectivePrice(p).toFixed(2)}
                  {p.sale_price !== null && p.sale_price < (p.price ?? Infinity) && (
                    <span className="ml-1 text-xs text-slate-400 line-through">${p.price?.toFixed(2)}</span>
                  )}
                </span>
              </li>
            ))}
          </ul>
        </div>
      ) : ra.suggestedProduct ? (
        <>
          <div className="flex items-center justify-between text-sm">
            <span className="text-slate-700">
              {ra.suggestedProduct.item_name}
              {ra.suggestedProduct.brand && (
                <span className="ml-1 text-slate-400">({ra.suggestedProduct.brand})</span>
              )}
            </span>
            <span className="font-medium text-slate-900">
              ${getEffectivePrice(ra.suggestedProduct).toFixed(2)}
              {ra.suggestedProduct.sale_price !== null && ra.suggestedProduct.sale_price < (ra.suggestedProduct.price ?? Infinity) && (
                <span className="ml-1 text-xs text-slate-400 line-through">${ra.suggestedProduct.price?.toFixed(2)}</span>
              )}
              {ra.defaultQty > 1 && <span className="text-slate-400"> x{ra.defaultQty}</span>}
            </span>
          </div>

          {ra.combinedPayments.length > 0 && (
            <div className="overflow-hidden rounded-md border border-slate-200">
              <table className="w-full text-sm">
                <thead className="bg-slate-50">
                  <tr>
                    <th className="px-3 py-1.5 text-left text-xs font-medium text-slate-600">Term</th>
                    <th className="px-3 py-1.5 text-right text-xs font-medium text-slate-600">Added $/mo</th>
                    <th className="px-3 py-1.5 text-right text-xs font-medium text-slate-600">New Total $/mo</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {ra.combinedPayments.map((cp) => {
                    const itemPmt = itemPaymentMap[cp.term];
                    const added =
                      itemPmt !== undefined
                        ? Math.round((cp.monthlyPayment - itemPmt) * 100) / 100
                        : cp.monthlyPayment;
                    const isNew = !itemTerms.includes(cp.term);
                    return (
                      <tr key={cp.term} className={isNew ? "bg-green-50" : ""}>
                        <td className="px-3 py-1.5 text-slate-700">
                          {cp.term} mo
                          {isNew && (
                            <span className="ml-1.5 text-xs font-medium text-green-600">NEW</span>
                          )}
                        </td>
                        <td className="px-3 py-1.5 text-right text-slate-600">
                          +${added.toFixed(2)}
                        </td>
                        <td className="px-3 py-1.5 text-right font-medium text-slate-900">
                          ${cp.monthlyPayment.toFixed(2)}
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}

          {ra.unlockedTerms.length > 0 && (
            <p className="text-xs text-green-600">
              Adding this accessory unlocks {ra.unlockedTerms.join(", ")}-month terms!
            </p>
          )}
        </>
      ) : (
        <p className="text-sm text-slate-400">No products in this category yet.</p>
      )}

      {/* Swap panel */}
      {swapOpen && ra.allProducts.length > 1 && (
        <div className="border-t border-slate-100 pt-2">
          <p className="mb-1 text-xs text-slate-500">Choose a different product:</p>
          <ul className="max-h-40 overflow-y-auto divide-y divide-slate-100 rounded-md border border-slate-200">
            {ra.allProducts.map((p) => (
              <li
                key={p.id}
                onClick={() => onSwap(p)}
                className={`flex cursor-pointer items-center justify-between px-3 py-1.5 text-sm hover:bg-slate-50 ${
                  p.id === ra.suggestedProduct?.id ? "bg-brand-50" : ""
                }`}
              >
                <span className="text-slate-700">{p.item_name}</span>
                <span className="text-slate-500">
                  ${getEffectivePrice(p).toFixed(2)}
                  {p.sale_price !== null && p.sale_price < (p.price ?? Infinity) && (
                    <span className="ml-1 text-xs text-slate-400 line-through">${p.price?.toFixed(2)}</span>
                  )}
                </span>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
