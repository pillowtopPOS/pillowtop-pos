import { createClient } from "@/lib/supabase/client";

export type Product = {
  id: string;
  company_id: string;
  sku: string;
  item_name: string;
  brand: string | null;
  cost: number | null;
  price: number | null;
  sale_price: number | null;
  category_id: string | null;
  sleep_trial_eligible: boolean | null;
  search_text: string;
  created_at: string;
  updated_at: string;
};

export type InventoryPosition = {
  id: string;
  variant_id: string;
  location_id: string;
  sublocation_id: string | null;
  disposition: string;
  on_hand_quantity: number | null;
  ats: number;
  updated_at: string;
};

export type ProductWithStock = Product & {
  stock: number | null;
  physical: number | null;
  ats: number | null;
};

export async function searchProducts(query: string): Promise<Product[]> {
  if (!query.trim()) return [];

  const supabase = createClient();
  const { data, error } = await supabase
    .rpc("search_products", { p_query: query.trim() })
    .select("*");

  if (error) {
    console.error("searchProducts error", error);
    return [];
  }

  return (data as unknown as Product[]) ?? [];
}

type InventoryVisibility = {
  physical: number | null;
  ats: number;
};

export async function fetchProductStock(
  productIds: string[],
  storeId: string
): Promise<Record<string, InventoryVisibility>> {
  if (productIds.length === 0) return {};

  const supabase = createClient();
  const { data, error } = await supabase
    .from("inventory_positions_public")
    .select("variant_id, on_hand_quantity, ats")
    .in("variant_id", productIds)
    .eq("location_id", storeId)
    .eq("disposition", "Prime")
    .is("sublocation_id", null);

  if (error) {
    console.error("fetchProductStock error", error);
    return {};
  }

  const map: Record<string, InventoryVisibility> = {};
  for (const row of (data as unknown as InventoryPosition[]) ?? []) {
    map[row.variant_id] = { physical: row.on_hand_quantity, ats: row.ats };
  }
  return map;
}

export async function fetchProductsWithStock(
  storeId?: string
): Promise<ProductWithStock[]> {
  const supabase = createClient();
  const { data: products, error } = await supabase
    .from("products_public")
    .select("*")
    .order("item_name");

  if (error) {
    console.error("fetchProductsWithStock error", error);
    return [];
  }

  const list = (products as unknown as Product[]) ?? [];
  if (list.length === 0) return [];

  let stockMap: Record<string, InventoryVisibility> = {};
  if (storeId) {
    stockMap = await fetchProductStock(list.map((p) => p.id), storeId);
  }

  return list.map((p) => ({
    ...p,
    stock: stockMap[p.id]?.ats ?? null,
    physical: stockMap[p.id]?.physical ?? null,
    ats: stockMap[p.id]?.ats ?? null,
  }));
}

export async function upsertProduct(product: Partial<Product> & { company_id: string; sku: string }) {
  const supabase = createClient();

  const payload = {
    company_id: product.company_id,
    sku: product.sku,
    item_name: product.item_name,
    brand: product.brand,
    cost: product.cost,
    price: product.price,
    sale_price: product.sale_price,
    category_id: product.category_id ?? null,
    sleep_trial_eligible: product.sleep_trial_eligible ?? null,
  };

  const { data, error } = await supabase
    .from("products")
    .upsert(payload, { onConflict: "company_id,sku", ignoreDuplicates: false })
    .select("id")
    .single();

  if (error) throw new Error(error.message);
  return (data as { id: string })?.id;
}

export async function adjustInventoryPosition(
  productId: string,
  storeId: string,
  quantity: number
) {
  const supabase = createClient();
  const {
    data: { session },
  } = await supabase.auth.getSession();

  if (!session?.user) {
    throw new Error("Not authenticated");
  }

  const { data, error } = await supabase.rpc("adjust_inventory_position", {
    p_variant_id: productId,
    p_location_id: storeId,
    p_sublocation_id: null,
    p_disposition: "Prime",
    p_new_quantity: Math.max(0, Math.floor(quantity)),
    p_reason: "manual_adjustment",
    p_reference_type: "manual",
    p_actor_id: session.user.id,
  });

  if (error) {
    throw new Error(error.message);
  }

  return (data as string) ?? "";
}
