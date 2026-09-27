"use client";

import { useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { Printer } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import type { Product } from "@/lib/inventory/queries";
import {
  fetchCount,
  fetchCountItems,
  fetchProductsByIds,
  type InventoryCount,
  type CountItem,
} from "@/lib/counts/queries";

// Printable blind count sheet — expected quantities are never rendered here,
// regardless of the count's status.
export default function CountSheetPage() {
  const params = useParams();
  const router = useRouter();
  const countId = params?.id as string;

  const [count, setCount] = useState<InventoryCount | null>(null);
  const [items, setItems] = useState<CountItem[]>([]);
  const [products, setProducts] = useState<Record<string, Product>>({});
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getSession().then(async ({ data: { session } }) => {
      if (!session?.user) {
        router.push("/login");
        return;
      }
      const [c, its] = await Promise.all([
        fetchCount(countId),
        fetchCountItems(countId),
      ]);
      setCount(c);
      setItems(its);
      setProducts(await fetchProductsByIds(its.map((i) => i.variant_id)));
      setLoading(false);
    });
  }, [router, countId]);

  const sorted = [...items].sort((a, b) =>
    (products[a.variant_id]?.item_name ?? "").localeCompare(
      products[b.variant_id]?.item_name ?? ""
    )
  );

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <p className="text-sm text-slate-500">Loading…</p>
      </div>
    );
  }

  if (!count) {
    return (
      <div className="p-6">
        <p className="text-sm text-slate-500">Count not found.</p>
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-3xl bg-white p-8 text-slate-900">
      <div className="mb-6 flex items-start justify-between print:hidden">
        <p className="text-sm text-slate-500">
          Print this sheet for pen-and-paper counting. Expected quantities are
          intentionally not shown.
        </p>
        <button
          type="button"
          onClick={() => window.print()}
          className="inline-flex items-center gap-2 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700"
        >
          <Printer className="h-4 w-4" /> Print
        </button>
      </div>

      <div className="border-b-2 border-slate-900 pb-4">
        <h1 className="text-xl font-bold">
          Inventory Count Sheet
          {count.reference_code && (
            <span className="ml-3 text-base font-semibold text-slate-600">
              {count.reference_code}
            </span>
          )}
        </h1>
        <div className="mt-2 flex justify-between text-sm">
          <span>
            Store: <strong>{count.store?.name ?? "—"}</strong>
          </span>
          <span>
            Type: <strong>{count.count_type === "full" ? "Full" : "Cycle"}</strong>
          </span>
          <span>Date: {new Date().toLocaleDateString()}</span>
        </div>
        <div className="mt-1 text-sm">
          Counted by: ______________________________
        </div>
      </div>

      <table className="mt-4 w-full border-collapse text-sm">
        <thead>
          <tr>
            <th className="border-b border-slate-400 py-2 pr-2 text-left font-semibold">#</th>
            <th className="border-b border-slate-400 py-2 pr-2 text-left font-semibold">Item</th>
            <th className="border-b border-slate-400 py-2 pr-2 text-left font-semibold">SKU</th>
            <th className="border-b border-slate-400 py-2 text-left font-semibold">Counted qty</th>
          </tr>
        </thead>
        <tbody>
          {sorted.map((item, idx) => {
            const p = products[item.variant_id];
            return (
              <tr key={item.id}>
                <td className="border-b border-slate-200 py-2.5 pr-2 text-slate-500">
                  {idx + 1}
                </td>
                <td className="border-b border-slate-200 py-2.5 pr-2">
                  {p?.item_name ?? item.variant_id}
                  {p?.brand && (
                    <span className="ml-2 text-xs text-slate-500">{p.brand}</span>
                  )}
                </td>
                <td className="border-b border-slate-200 py-2.5 pr-2 text-slate-600">
                  {p?.sku ?? "—"}
                </td>
                <td className="border-b border-slate-200 py-2.5">
                  <span className="inline-block h-6 w-24 border-b border-slate-400" />
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
