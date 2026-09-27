// ---- Database row types ----

export type ProductCategory = {
  id: string;
  company_id: string;
  name: string;
  sleep_trial_eligible: boolean;
  created_at: string;
};

export type FinancingTier = {
  id: string;
  company_id: string;
  min_price: number;
  max_price: number | null; // null = ∞
  term_lengths: number[];
  sort_order: number;
  created_at: string;
};

export type AccessoryMatchMode = "auto_rank" | "manual_pin" | "show_all";

export type AccessoryCategory = {
  id: string;
  company_id: string;
  category_id: string;
  enabled_for_suggestions: boolean;
  default_qty: number;
  sort_order: number;
  match_mode: AccessoryMatchMode;
  created_at: string;
  // joined
  category_name?: string;
};

export type AccessoryPin = {
  id: string;
  company_id: string;
  accessory_category_id: string;
  financing_tier_id: string;
  product_id: string;
  created_at: string;
};

export type AccessoryBundle = {
  id: string;
  company_id: string;
  name: string;
  created_at: string;
};

export type AccessoryBundleComponent = {
  id: string;
  bundle_id: string;
  accessory_category_id: string;
};
