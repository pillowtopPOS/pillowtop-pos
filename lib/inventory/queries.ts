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
  search_text: string;
  created_at: string;
  updated_at: string;
};

export type ProductStock = {
  id: string;
  product_id: string;
  store_id: string;
  quantity: number;
  updated_at: string;
};

export type ProductWithStock = Product & { stock: number | null };

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

export async function fetchProductStock(
  productIds: string[],
  storeId: string
): Promise<Record<string, number>> {
  if (productIds.length === 0) return {};

  const supabase = createClient();
  const { data, error } = await supabase
    .from("product_stock")
    .select("product_id, quantity")
    .in("product_id", productIds)
    .eq("store_id", storeId);

  if (error) {
    console.error("fetchProductStock error", error);
    return {};
  }

  const map: Record<string, number> = {};
  for (const row of (data as unknown as ProductStock[]) ?? []) {
    map[row.product_id] = row.quantity;
  }
  return map;
}

export async function fetchProductsWithStock(
  storeId?: string
): Promise<ProductWithStock[]> {
  const supabase = createClient();
  const { data: products, error } = await supabase
    .from("products")
    .select("*")
    .order("item_name");

  if (error) {
    console.error("fetchProductsWithStock error", error);
    return [];
  }

  const list = (products as unknown as Product[]) ?? [];
  if (list.length === 0) return [];

  let stockMap: Record<string, number> = {};
  if (storeId) {
    stockMap = await fetchProductStock(list.map((p) => p.id), storeId);
  }

  return list.map((p) => ({
    ...p,
    stock: stockMap[p.id] ?? null,
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
  };

  const { data, error } = await supabase
    .from("products")
    .upsert(payload, { onConflict: "company_id,sku", ignoreDuplicates: false })
    .select("id")
    .single();

  if (error) throw new Error(error.message);
  return (data as { id: string })?.id;
}

export async function updateProductStock(productId: string, storeId: string, quantity: number) {
  const supabase = createClient();
  const { error } = await supabase.from("product_stock").upsert(
    { product_id: productId, store_id: storeId, quantity: Math.max(0, Math.floor(quantity)) },
    { onConflict: "product_id,store_id", ignoreDuplicates: false }
  );

  if (error) throw new Error(error.message);
}
