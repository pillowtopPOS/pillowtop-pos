import { createClient } from "@/lib/supabase/client";
import type {
  ProductCategory,
  FinancingTier,
  AccessoryCategory,
  AccessoryPin,
  AccessoryBundle,
  AccessoryBundleComponent,
} from "./types";

// ---- Product Categories ----

export async function fetchProductCategories(companyId: string): Promise<ProductCategory[]> {
  const supabase = createClient();
  const { data, error } = await (supabase as any)
    .from("product_categories")
    .select("*")
    .eq("company_id", companyId)
    .order("name");
  if (error) { console.error("fetchProductCategories", error); return []; }
  return (data ?? []) as ProductCategory[];
}

export async function upsertProductCategory(cat: Partial<ProductCategory> & { company_id: string; name: string }) {
  const supabase = createClient();
  if (cat.id) {
    const updates: Record<string, unknown> = { name: cat.name };
    if (cat.sleep_trial_eligible !== undefined) {
      updates.sleep_trial_eligible = cat.sleep_trial_eligible;
    }
    const { error } = await (supabase as any)
      .from("product_categories")
      .update(updates)
      .eq("id", cat.id);
    if (error) throw new Error(error.message);
    return cat.id;
  }
  const { data, error } = await (supabase as any)
    .from("product_categories")
    .insert({
      company_id: cat.company_id,
      name: cat.name,
      sleep_trial_eligible: cat.sleep_trial_eligible ?? false,
    })
    .select("id")
    .single();
  if (error) throw new Error(error.message);
  return (data as { id: string }).id;
}

export async function deleteProductCategory(id: string) {
  const supabase = createClient();
  const { error } = await (supabase as any)
    .from("product_categories")
    .delete()
    .eq("id", id);
  if (error) throw new Error(error.message);
}

// ---- Financing Tiers ----

export async function fetchFinancingTiers(companyId: string): Promise<FinancingTier[]> {
  const supabase = createClient();
  const { data, error } = await (supabase as any)
    .from("financing_tiers")
    .select("*")
    .eq("company_id", companyId)
    .order("sort_order");
  if (error) { console.error("fetchFinancingTiers", error); return []; }
  return (data ?? []) as FinancingTier[];
}

export async function saveFinancingTiers(companyId: string, tiers: FinancingTier[]) {
  const supabase = createClient();

  // Delete existing tiers for the company
  const { error: delErr } = await (supabase as any)
    .from("financing_tiers")
    .delete()
    .eq("company_id", companyId);
  if (delErr) throw new Error(delErr.message);

  if (tiers.length === 0) return;

  // Insert all tiers in one batch — the constraint trigger validates on commit
  const rows = tiers.map((t, i) => ({
    company_id: companyId,
    min_price: t.min_price,
    max_price: t.max_price,
    term_lengths: t.term_lengths,
    sort_order: i,
  }));

  const { error: insErr } = await (supabase as any)
    .from("financing_tiers")
    .insert(rows);
  if (insErr) throw new Error(insErr.message);
}

// ---- Accessory Categories ----

export async function fetchAccessoryCategories(companyId: string): Promise<AccessoryCategory[]> {
  const supabase = createClient();
  const { data, error } = await (supabase as any)
    .from("accessory_categories")
    .select("*, product_categories!category_id(name)")
    .eq("company_id", companyId)
    .order("sort_order");
  if (error) { console.error("fetchAccessoryCategories", error); return []; }
  return ((data ?? []) as any[]).map((d) => ({
    ...d,
    category_name: d.product_categories?.name ?? null,
    product_categories: undefined,
  })) as AccessoryCategory[];
}

export async function upsertAccessoryCategory(
  cat: Partial<AccessoryCategory> & { company_id: string; category_id: string }
) {
  const supabase = createClient();
  const payload = {
    company_id: cat.company_id,
    category_id: cat.category_id,
    enabled_for_suggestions: cat.enabled_for_suggestions ?? true,
    default_qty: cat.default_qty ?? 1,
    sort_order: cat.sort_order ?? 0,
    match_mode: cat.match_mode ?? "auto_rank",
  };

  if (cat.id) {
    const { error } = await (supabase as any)
      .from("accessory_categories")
      .update(payload)
      .eq("id", cat.id);
    if (error) throw new Error(error.message);
    return cat.id;
  }
  const { data, error } = await (supabase as any)
    .from("accessory_categories")
    .insert(payload)
    .select("id")
    .single();
  if (error) throw new Error(error.message);
  return (data as { id: string }).id;
}

export async function deleteAccessoryCategory(id: string) {
  const supabase = createClient();
  const { error } = await (supabase as any)
    .from("accessory_categories")
    .delete()
    .eq("id", id);
  if (error) throw new Error(error.message);
}

// ---- Accessory Pins ----

export async function fetchAccessoryPins(companyId: string): Promise<AccessoryPin[]> {
  const supabase = createClient();
  const { data, error } = await (supabase as any)
    .from("accessory_pins")
    .select("*")
    .eq("company_id", companyId);
  if (error) { console.error("fetchAccessoryPins", error); return []; }
  return (data ?? []) as AccessoryPin[];
}

export async function upsertAccessoryPin(pin: {
  company_id: string;
  accessory_category_id: string;
  financing_tier_id: string;
  product_id: string;
}) {
  const supabase = createClient();
  const { data, error } = await (supabase as any)
    .from("accessory_pins")
    .upsert(pin, { onConflict: "accessory_category_id,financing_tier_id" })
    .select("id")
    .single();
  if (error) throw new Error(error.message);
  return (data as { id: string }).id;
}

export async function deleteAccessoryPin(id: string) {
  const supabase = createClient();
  const { error } = await (supabase as any)
    .from("accessory_pins")
    .delete()
    .eq("id", id);
  if (error) throw new Error(error.message);
}

// ---- Accessory Bundles ----

export async function fetchAccessoryBundles(companyId: string): Promise<AccessoryBundle[]> {
  const supabase = createClient();
  const { data, error } = await (supabase as any)
    .from("accessory_bundles")
    .select("*")
    .eq("company_id", companyId)
    .order("name");
  if (error) { console.error("fetchAccessoryBundles", error); return []; }
  return (data ?? []) as AccessoryBundle[];
}

export async function upsertAccessoryBundle(
  bundle: Partial<AccessoryBundle> & { company_id: string; name: string }
) {
  const supabase = createClient();
  if (bundle.id) {
    const { error } = await (supabase as any)
      .from("accessory_bundles")
      .update({ name: bundle.name })
      .eq("id", bundle.id);
    if (error) throw new Error(error.message);
    return bundle.id;
  }
  const { data, error } = await (supabase as any)
    .from("accessory_bundles")
    .insert({ company_id: bundle.company_id, name: bundle.name })
    .select("id")
    .single();
  if (error) throw new Error(error.message);
  return (data as { id: string }).id;
}

export async function deleteAccessoryBundle(id: string) {
  const supabase = createClient();
  const { error } = await (supabase as any)
    .from("accessory_bundles")
    .delete()
    .eq("id", id);
  if (error) throw new Error(error.message);
}

// ---- Bundle Components ----

export async function fetchBundleComponents(bundleId: string): Promise<AccessoryBundleComponent[]> {
  const supabase = createClient();
  const { data, error } = await (supabase as any)
    .from("accessory_bundle_components")
    .select("*")
    .eq("bundle_id", bundleId);
  if (error) { console.error("fetchBundleComponents", error); return []; }
  return (data ?? []) as AccessoryBundleComponent[];
}

export async function saveBundleComponents(bundleId: string, categoryIds: string[]) {
  const supabase = createClient();
  const { error: delErr } = await (supabase as any)
    .from("accessory_bundle_components")
    .delete()
    .eq("bundle_id", bundleId);
  if (delErr) throw new Error(delErr.message);

  if (categoryIds.length === 0) return;
  const rows = categoryIds.map((cid) => ({
    bundle_id: bundleId,
    accessory_category_id: cid,
  }));
  const { error: insErr } = await (supabase as any)
    .from("accessory_bundle_components")
    .insert(rows);
  if (insErr) throw new Error(insErr.message);
}
