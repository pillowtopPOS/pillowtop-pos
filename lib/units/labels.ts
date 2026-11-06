import { createClient } from "@/lib/supabase/client";

export type LabelUnit = {
  id: string;
  unit_number: number;
  product_id: string;
  sku: string | null;
  item_name: string | null;
  description: string | null;
  location_name: string | null;
  created_at: string | null;
};

export async function fetchUnitsForLabels(numbers: number[]): Promise<{
  units: LabelUnit[];
  missing: number[];
}> {
  const supabase = createClient();
  const { data: units, error } = await supabase
    .from("units")
    .select("id, unit_number, product_id, location_id, created_at")
    .in("unit_number", numbers);
  if (error) throw new Error(error.message);
  const rows = units ?? [];
  const foundNumbers = new Set(rows.map((r: any) => r.unit_number));
  const missing = numbers.filter((n) => !foundNumbers.has(n));

  const productIds = Array.from(new Set(rows.map((r: any) => r.product_id)));
  const locationIds = Array.from(
    new Set(rows.map((r: any) => r.location_id).filter(Boolean))
  );
  const [prods, locs] = await Promise.all([
    productIds.length
      ? supabase
          .from("products_public")
          .select("id, item_name, sku")
          .in("id", productIds)
      : Promise.resolve({ data: [] }),
    locationIds.length
      ? supabase.from("stores").select("id, name").in("id", locationIds)
      : Promise.resolve({ data: [] }),
  ]);
  const prodMap = new Map((prods.data ?? []).map((p: any) => [p.id, p]));
  const locMap = new Map((locs.data ?? []).map((s: any) => [s.id, s.name]));

  // preserve the order requested
  const ordered = numbers
    .map((n) => rows.find((r: any) => r.unit_number === n))
    .filter(Boolean)
    .map((r: any) => ({
      id: r.id,
      unit_number: r.unit_number,
      product_id: r.product_id,
      sku: prodMap.get(r.product_id)?.sku ?? null,
      item_name: prodMap.get(r.product_id)?.item_name ?? null,
      description: null, // products_public has no description column
      location_name: r.location_id ? locMap.get(r.location_id) ?? null : null,
      created_at: r.created_at ?? null,
    }));
  return { units: ordered, missing };
}
