import type { FinancingTier, AccessoryCategory, AccessoryPin, AccessoryMatchMode } from "./types";
import type { Product } from "@/lib/inventory/queries";

function getEffectivePrice(product: Product | null): number {
  return product?.sale_price ?? product?.price ?? 0;
}

// ---- Tier lookup ----

export function getTier(price: number, tiers: FinancingTier[]): FinancingTier | null {
  if (tiers.length === 0) return null;
  const sorted = [...tiers].sort((a, b) => a.sort_order - b.sort_order);
  for (const t of sorted) {
    const inLower = price >= t.min_price;
    const inUpper = t.max_price === null || price < t.max_price;
    if (inLower && inUpper) return t;
  }
  return null;
}

export function getTerms(price: number, tiers: FinancingTier[]): number[] {
  const tier = getTier(price, tiers);
  return tier ? [...tier.term_lengths].sort((a, b) => a - b) : [];
}

export function getTierIndex(tier: FinancingTier, tiers: FinancingTier[]): number {
  const sorted = [...tiers].sort((a, b) => a.sort_order - b.sort_order);
  return sorted.findIndex((t) => t.id === tier.id);
}

// ---- Payment math ----

export type PaymentRow = {
  term: number;
  monthlyPayment: number; // price / term, rounded to cent
};

export function computePayments(price: number, terms: number[]): PaymentRow[] {
  return terms.map((term) => ({
    term,
    monthlyPayment: Math.round((price / term) * 100) / 100,
  }));
}

// ---- Accessory resolution ----

export type ResolvedAccessory = {
  accessoryCategoryId: string;
  categoryName: string;
  matchMode: AccessoryMatchMode;
  defaultQty: number;
  // The resolved product(s)
  suggestedProduct: Product | null;  // for auto_rank / manual_pin
  allProducts: Product[];            // for show_all, or swap list
  // Combined payment info
  combinedPrice: number;
  combinedTier: FinancingTier | null;
  combinedTerms: number[];
  combinedPayments: PaymentRow[];
  tierBump: boolean; // true if combined tier is higher than the item-alone tier
  unlockedTerms: number[]; // terms in combinedTerms not in the item-alone terms
};

export function resolveAccessory(opts: {
  accCat: AccessoryCategory;
  itemPrice: number;
  itemTier: FinancingTier | null;
  itemTerms: number[];
  tiers: FinancingTier[];
  pins: AccessoryPin[];
  candidateProducts: Product[]; // products in the matching product_category
}): ResolvedAccessory {
  const { accCat, itemPrice, itemTier, itemTerms, tiers, pins, candidateProducts } = opts;
  const qty = accCat.default_qty;
  const sorted = [...candidateProducts].sort((a, b) => (a.price ?? 0) - (b.price ?? 0));

  let suggestedProduct: Product | null = null;

  if (accCat.match_mode === "manual_pin" && itemTier) {
    const pin = pins.find(
      (p) => p.accessory_category_id === accCat.id && p.financing_tier_id === itemTier.id
    );
    if (pin) {
      suggestedProduct = sorted.find((p) => p.id === pin.product_id) ?? null;
    }
    // fallback to auto_rank if no pin found
    if (!suggestedProduct && sorted.length > 0) {
      suggestedProduct = sorted[0];
    }
  } else if (accCat.match_mode === "auto_rank" && itemTier) {
    if (sorted.length > 0) {
      const tierIdx = getTierIndex(itemTier, tiers);
      const numTiers = tiers.length;
      const idx = Math.min(
        Math.floor((tierIdx * sorted.length) / numTiers),
        sorted.length - 1
      );
      suggestedProduct = sorted[idx];
    }
  } else if (accCat.match_mode === "show_all") {
    // No single suggestion — associate picks from the list
    suggestedProduct = null;
  } else if (sorted.length > 0) {
    suggestedProduct = sorted[0];
  }

  const accessoryPrice = getEffectivePrice(suggestedProduct);
  const combinedPrice = itemPrice + accessoryPrice * qty;
  const combinedTier = getTier(combinedPrice, tiers);
  const combinedTerms = combinedTier
    ? [...combinedTier.term_lengths].sort((a, b) => a - b)
    : [];
  const combinedPayments = computePayments(combinedPrice, combinedTerms);

  const tierBump =
    !!combinedTier &&
    !!itemTier &&
    combinedTier.id !== itemTier.id &&
    combinedTier.sort_order > itemTier.sort_order;

  const itemTermSet = new Set(itemTerms);
  const unlockedTerms = combinedTerms.filter((t) => !itemTermSet.has(t));

  return {
    accessoryCategoryId: accCat.id,
    categoryName: accCat.category_name ?? "Accessory",
    matchMode: accCat.match_mode,
    defaultQty: qty,
    suggestedProduct,
    allProducts: sorted,
    combinedPrice,
    combinedTier,
    combinedTerms,
    combinedPayments,
    tierBump,
    unlockedTerms,
  };
}

// Recompute a resolved accessory with a different product selection
export function recomputeWithProduct(
  resolved: ResolvedAccessory,
  product: Product,
  itemPrice: number,
  tiers: FinancingTier[],
  itemTerms: number[]
): ResolvedAccessory {
  const qty = resolved.defaultQty;
  const accessoryPrice = getEffectivePrice(product);
  const combinedPrice = itemPrice + accessoryPrice * qty;
  const combinedTier = getTier(combinedPrice, tiers);
  const combinedTerms = combinedTier
    ? [...combinedTier.term_lengths].sort((a, b) => a - b)
    : [];
  const combinedPayments = computePayments(combinedPrice, combinedTerms);

  const itemTier = getTier(itemPrice, tiers);
  const tierBump =
    !!combinedTier &&
    !!itemTier &&
    combinedTier.id !== itemTier.id &&
    combinedTier.sort_order > itemTier.sort_order;

  const itemTermSet = new Set(itemTerms);
  const unlockedTerms = combinedTerms.filter((t) => !itemTermSet.has(t));

  return {
    ...resolved,
    suggestedProduct: product,
    combinedPrice,
    combinedTier,
    combinedTerms,
    combinedPayments,
    tierBump,
    unlockedTerms,
  };
}
