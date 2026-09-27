import { createClient } from "@/lib/supabase/client";
import { fetchCurrentEmployee } from "@/lib/journeys/queries";
import type { Product } from "@/lib/inventory/queries";

export type CountType = "full" | "cycle";
export type CountStatus =
  | "pending_start_approval"
  | "in_progress"
  | "submitted"
  | "approved"
  | "rejected"
  | "cancelled";

export type InventoryCount = {
  id: string;
  reference_code: string | null;
  company_id: string;
  store_id: string;
  count_type: CountType;
  status: CountStatus;
  requested_by: string | null;
  started_by: string | null;
  started_at: string | null;
  approved_by: string | null;
  approved_at: string | null;
  created_at: string;
  updated_at: string;
  store: { id: string; name: string } | null;
  requester: { id: string; name: string } | null;
  starter: { id: string; name: string } | null;
  approver: { id: string; name: string } | null;
};

// Read from inventory_count_items_public — expected_quantity is null while the
// parent count is pending_start_approval or in_progress (blindness is
// enforced in the view, not here).
export type CountItem = {
  id: string;
  count_id: string;
  variant_id: string;
  expected_quantity: number | null;
  submitted_quantity: number | null;
  submitted_by: string | null;
  submitted_at: string | null;
  counted_quantity: number | null;
  entered_by: string | null;
  entered_at: string | null;
  created_at: string;
};

export type CountReviewItem = {
  item_id: string;
  variant_id: string;
  item_name: string;
  sku: string | null;
  expected_quantity: number;
  submitted_quantity: number | null;
  submitted_by: string | null;
  submitted_by_name: string | null;
};

export type CycleSuggestion = {
  variant_id: string;
  last_counted_at: string | null;
};

const COUNT_SELECT = `*,
  store:stores!store_id ( id, name ),
  requester:employees!requested_by ( id, name ),
  starter:employees!started_by ( id, name ),
  approver:employees!approved_by ( id, name )`;

export async function fetchCounts(): Promise<InventoryCount[]> {
  const supabase = createClient();
  const { data, error } = await (supabase as any)
    .from("inventory_counts")
    .select(COUNT_SELECT)
    .order("created_at", { ascending: false });
  if (error) {
    console.error("fetchCounts error", error);
    return [];
  }
  return (data as unknown as InventoryCount[]) ?? [];
}

export async function fetchCount(countId: string): Promise<InventoryCount | null> {
  const supabase = createClient();
  const { data, error } = await (supabase as any)
    .from("inventory_counts")
    .select(COUNT_SELECT)
    .eq("id", countId)
    .maybeSingle();
  if (error) {
    console.error("fetchCount error", error);
    return null;
  }
  return (data as unknown as InventoryCount) ?? null;
}

export async function fetchCountItems(countId: string): Promise<CountItem[]> {
  const supabase = createClient();
  const { data, error } = await (supabase as any)
    .from("inventory_count_items_public")
    .select("*")
    .eq("count_id", countId);
  if (error) {
    console.error("fetchCountItems error", error);
    return [];
  }
  return (data as unknown as CountItem[]) ?? [];
}

// Product display info for a set of variants (products_public applies its own
// cost masking; we only need identity fields here anyway).
export async function fetchProductsByIds(
  ids: string[]
): Promise<Record<string, Product>> {
  if (ids.length === 0) return {};
  const supabase = createClient();
  const { data, error } = await supabase
    .from("products_public")
    .select("*")
    .in("id", ids);
  if (error) {
    console.error("fetchProductsByIds error", error);
    return {};
  }
  const map: Record<string, Product> = {};
  for (const p of (data as unknown as Product[]) ?? []) map[p.id] = p;
  return map;
}

export async function createInventoryCount(
  storeId: string,
  countType: CountType,
  variantIds?: string[]
): Promise<string> {
  const supabase = createClient();
  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  const { data, error } = await (supabase as any).rpc("create_inventory_count", {
    p_employee_id: employee.id,
    p_store_id: storeId,
    p_count_type: countType,
    p_variant_ids: variantIds ?? null,
  });
  if (error) throw new Error(error.message);
  return data as string;
}

export async function approveCountStart(countId: string) {
  const supabase = createClient();
  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  const { error } = await (supabase as any).rpc("approve_inventory_count_start", {
    p_count_id: countId,
    p_employee_id: employee.id,
  });
  if (error) throw new Error(error.message);
}

export async function rejectCountStart(countId: string) {
  const supabase = createClient();
  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  const { error } = await (supabase as any).rpc("reject_inventory_count_start", {
    p_count_id: countId,
    p_employee_id: employee.id,
  });
  if (error) throw new Error(error.message);
}

export async function submitCountQuantities(
  countId: string,
  entries: { item_id: string; quantity: number }[]
) {
  const supabase = createClient();
  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  const { error } = await (supabase as any).rpc("submit_count_quantities", {
    p_count_id: countId,
    p_employee_id: employee.id,
    p_entries: entries,
  });
  if (error) throw new Error(error.message);
}

export async function submitInventoryCount(countId: string) {
  const supabase = createClient();
  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  const { error } = await (supabase as any).rpc("submit_inventory_count", {
    p_count_id: countId,
    p_employee_id: employee.id,
  });
  if (error) throw new Error(error.message);
}

// Finalize-screen data — reveals expected_quantity; server-side gated to
// manager-of-store/owner/admin.
export async function fetchCountReviewItems(
  countId: string
): Promise<CountReviewItem[]> {
  const supabase = createClient();
  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  const { data, error } = await (supabase as any).rpc("get_inventory_count_review", {
    p_count_id: countId,
    p_employee_id: employee.id,
  });
  if (error) throw new Error(error.message);
  return (data as unknown as CountReviewItem[]) ?? [];
}

export async function finalizeInventoryCount(
  countId: string,
  counts: Record<string, number>
) {
  const supabase = createClient();
  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  const { error } = await (supabase as any).rpc("finalize_inventory_count", {
    p_count_id: countId,
    p_employee_id: employee.id,
    p_counts: counts,
  });
  if (error) throw new Error(error.message);
}

export async function cancelInventoryCount(countId: string) {
  const supabase = createClient();
  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  const { error } = await (supabase as any).rpc("cancel_inventory_count", {
    p_count_id: countId,
    p_employee_id: employee.id,
  });
  if (error) throw new Error(error.message);
}

// Add a product to an in-progress count (same authorization as entry).
// Returns the count item's id — existing item's id if already present.
export async function addInventoryCountItem(
  countId: string,
  variantId: string
): Promise<string> {
  const supabase = createClient();
  const employee = await fetchCurrentEmployee();
  if (!employee) throw new Error("Employee record not found");

  const { data, error } = await (supabase as any).rpc("add_inventory_count_item", {
    p_count_id: countId,
    p_employee_id: employee.id,
    p_variant_id: variantId,
  });
  if (error) throw new Error(error.message);
  return data as string;
}

export async function suggestCountItems(
  storeId: string,
  limit = 50
): Promise<CycleSuggestion[]> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc("suggest_inventory_count_items", {
    p_store_id: storeId,
    p_limit: limit,
  });
  if (error) throw new Error(error.message);
  return (data as unknown as CycleSuggestion[]) ?? [];
}
