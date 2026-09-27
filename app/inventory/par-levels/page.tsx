"use client";

import { useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { fetchStores, type Store } from "@/lib/journeys/queries";

type Product = { id: string; sku: string; item_name: string };
type ParLevel = {
  id: string;
  store_id: string;
  variant_id: string;
  reorder_point: number;
  target_quantity: number;
};

export default function ParLevelsPage() {
  const supabase = createClient();
  const [stores, setStores] = useState<Store[]>([]);
  const [products, setProducts] = useState<Product[]>([]);
  const [rows, setRows] = useState<ParLevel[]>([]);
  const [store, setStore] = useState("");
  const [search, setSearch] = useState("");
  const [rowVersions, setRowVersions] = useState<Record<string, number>>({});

  useEffect(() => {
    (async () => {
      const [storesResult, productsResult, rowsResult] = await Promise.all([
        fetchStores(),
        supabase.from("products_public").select("id, sku, item_name").order("item_name"),
        supabase.from("par_levels").select("id, store_id, variant_id, reorder_point, target_quantity"),
      ]);
      setStores(storesResult);
      setStore(storesResult[0]?.id ?? "");
      setProducts(productsResult.data ?? []);
      if (rowsResult.error) window.alert(rowsResult.error.message);
      setRows(rowsResult.data ?? []);
    })();
  }, []);

  const filteredProducts = useMemo(() => {
    const term = search.trim().toLowerCase();
    if (!term) return products;
    return products.filter(
      (product) =>
        product.item_name.toLowerCase().includes(term) ||
        product.sku.toLowerCase().includes(term)
    );
  }, [products, search]);

  async function save(
    id: string | undefined,
    variantId: string,
    field: "reorder_point" | "target_quantity",
    value: string
  ) {
    const quantity = Math.max(0, Number(value) || 0);
    const parLevel = rows.find(
      (row) => row.store_id === store && row.variant_id === variantId
    );
    const values = {
      reorder_point: field === "reorder_point" ? quantity : parLevel?.reorder_point ?? 0,
      target_quantity: field === "target_quantity" ? quantity : parLevel?.target_quantity ?? 0,
    };
    const { data, error } = id
      ? await supabase
          .from("par_levels")
          .update({ ...values, updated_at: new Date().toISOString() })
          .eq("id", id)
          .select("id")
          .maybeSingle()
      : await supabase
          .from("par_levels")
          .upsert(
            { store_id: store, variant_id: variantId, ...values },
            { onConflict: "store_id,variant_id" }
          )
          .select("id")
          .maybeSingle();

    if (error) {
      window.alert(error.message);
      setRowVersions((prev) => ({
        ...prev,
        [`${store}-${variantId}`]: (prev[`${store}-${variantId}`] ?? 0) + 1,
      }));
      return;
    }

    if (!data) {
      window.alert("You don't have permission to edit par levels.");
      setRowVersions((prev) => ({
        ...prev,
        [`${store}-${variantId}`]: (prev[`${store}-${variantId}`] ?? 0) + 1,
      }));
      return;
    }

    const refreshed = await supabase
      .from("par_levels")
      .select("id, store_id, variant_id, reorder_point, target_quantity");
    if (refreshed.error) window.alert(refreshed.error.message);
    else setRows(refreshed.data ?? []);
  }

  return (
    <main className="min-h-screen bg-slate-50 p-6">
      <div className="mx-auto max-w-4xl">
        <header className="mb-4 flex items-center justify-between gap-4">
          <h1 className="text-2xl font-semibold text-slate-900">Par Levels</h1>
          <Link
            href="/inventory"
            className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            Back to Inventory
          </Link>
        </header>

        <div className="mb-4 flex flex-wrap gap-3">
          <select
            value={store}
            onChange={(e) => setStore(e.target.value)}
            className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm"
          >
            {stores.map((location) => (
              <option key={location.id} value={location.id}>
                {location.name}
              </option>
            ))}
          </select>
          <input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search products by name or SKU"
            className="w-72 rounded-md border border-slate-300 px-3 py-2 text-sm"
          />
        </div>

        <div className="rounded-lg border border-slate-200 bg-white">
          <div className="grid grid-cols-[minmax(0,1fr)_120px_120px] items-center gap-3 border-b border-slate-200 px-3 py-2 text-xs font-medium text-slate-500">
            <span>Product</span>
            <span className="text-right">Reorder point</span>
            <span className="text-right">Target level</span>
          </div>
          {filteredProducts.map((product) => {
            const parLevel = rows.find(
              (row) => row.store_id === store && row.variant_id === product.id
            );
            return (
              <div
                key={`${store}-${product.id}-${rowVersions[`${store}-${product.id}`] ?? 0}`}
                className="grid grid-cols-[minmax(0,1fr)_120px_120px] items-center gap-3 border-b border-slate-100 p-3 last:border-b-0"
              >
                <span className="min-w-0 text-sm text-slate-900 break-words pr-4">
                  {product.item_name} <span className="text-slate-500">({product.sku})</span>
                </span>
                <input
                  type="number"
                  min={0}
                  max={parLevel?.target_quantity ?? undefined}
                  defaultValue={parLevel?.reorder_point ?? 0}
                  onBlur={(e) =>
                    save(parLevel?.id, product.id, "reorder_point", e.target.value)
                  }
                  className="w-full rounded-md border border-slate-300 px-2 py-1 text-right text-sm text-slate-900"
                />
                <input
                  type="number"
                  min={parLevel?.reorder_point ?? 0}
                  defaultValue={parLevel?.target_quantity ?? 0}
                  onBlur={(e) =>
                    save(parLevel?.id, product.id, "target_quantity", e.target.value)
                  }
                  className="w-full rounded-md border border-slate-300 px-2 py-1 text-right text-sm text-slate-900"
                />
              </div>
            );
          })}
        </div>
      </div>
    </main>
  );
}
