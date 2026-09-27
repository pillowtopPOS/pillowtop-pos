"use client";

import { useEffect, useState } from "react";
import { useParams, useRouter } from "next/navigation";
import { Printer } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { fetchStores, type Store } from "@/lib/journeys/queries";
import {
  fetchPurchaseOrder,
  fetchPOProducts,
  poTotal,
  type PurchaseOrder,
  type POProduct,
} from "@/lib/purchase-orders/queries";
import ShipTo from "../../ShipTo";

export default function PurchaseOrderPrintPage() {
  const params = useParams();
  const router = useRouter();
  const poId = params?.id as string;

  const [po, setPO] = useState<PurchaseOrder | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [products, setProducts] = useState<POProduct[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getSession().then(async ({ data: { session } }) => {
      if (!session?.user) {
        router.push("/login");
        return;
      }
      const [p, st, pr] = await Promise.all([
        fetchPurchaseOrder(poId),
        fetchStores(true),
        fetchPOProducts(),
      ]);
      setPO(p);
      setStores(st);
      setProducts(pr);
      setLoading(false);
    });
  }, [router, poId]);

  if (loading) {
    return (
      <div className="flex min-h-screen items-center justify-center">
        <p className="text-sm text-slate-500">Loading…</p>
      </div>
    );
  }

  if (!po) {
    return (
      <div className="p-6">
        <p className="text-sm text-slate-500">Purchase order not found.</p>
      </div>
    );
  }

  const destination = stores.find(
    (s) => s.id === po.destination_location_id,
  );
  const money = (n: number) =>
    n.toLocaleString(undefined, {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    });

  return (
    <div className="mx-auto max-w-3xl bg-white p-8 text-slate-900">
      <div className="mb-6 flex items-start justify-between print:hidden">
        <p className="text-sm text-slate-500">
          Print this purchase order to send to the vendor or file.
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
          Purchase Order
          {po.reference_code && (
            <span className="ml-3 text-base font-semibold text-slate-600">
              {po.reference_code}
            </span>
          )}
        </h1>
        <div className="mt-2 flex justify-between text-sm">
          <span>
            Vendor: <strong>{po.vendor_name}</strong>
          </span>
          <span>
            Type:{" "}
            <strong>
              {po.fulfillment_type === "drop_ship" ? "Drop Ship" : "Stock"}
            </strong>
          </span>
          <span>Date: {new Date(po.created_at).toLocaleDateString()}</span>
        </div>
      </div>

      <div className="mt-4 rounded border border-slate-300 p-3">
        <ShipTo po={po} destination={destination} />
      </div>

      <table className="mt-4 w-full border-collapse text-sm">
        <thead>
          <tr>
            <th className="border-b border-slate-400 py-2 pr-2 text-left font-semibold">
              Item
            </th>
            <th className="border-b border-slate-400 py-2 pr-2 text-left font-semibold">
              SKU
            </th>
            <th className="border-b border-slate-400 py-2 pr-2 text-right font-semibold">
              Qty
            </th>
            <th className="border-b border-slate-400 py-2 pr-2 text-right font-semibold">
              Unit cost
            </th>
            <th className="border-b border-slate-400 py-2 text-right font-semibold">
              Total
            </th>
          </tr>
        </thead>
        <tbody>
          {po.lines.map((l) => {
            const p = products.find((x) => x.id === l.variant_id);
            return (
              <tr key={l.id}>
                <td className="border-b border-slate-200 py-2.5 pr-2">
                  {p?.item_name ?? l.variant_id}
                </td>
                <td className="border-b border-slate-200 py-2.5 pr-2 text-slate-600">
                  {p?.sku ?? "—"}
                </td>
                <td className="border-b border-slate-200 py-2.5 pr-2 text-right">
                  {l.quantity_ordered}
                </td>
                <td className="border-b border-slate-200 py-2.5 pr-2 text-right">
                  ${money(Number(l.unit_cost))}
                </td>
                <td className="border-b border-slate-200 py-2.5 text-right">
                  ${money(l.quantity_ordered * Number(l.unit_cost))}
                </td>
              </tr>
            );
          })}
        </tbody>
        <tfoot>
          <tr>
            <td
              colSpan={4}
              className="py-3 pr-2 text-right font-semibold"
            >
              Order total
            </td>
            <td className="py-3 text-right font-semibold">
              ${money(poTotal(po.lines))}
            </td>
          </tr>
        </tfoot>
      </table>

      {po.fulfillment_type === "drop_ship" && po.tracking_number && (
        <p className="mt-4 text-sm text-slate-600">
          Tracking: {po.tracking_number}
        </p>
      )}
    </div>
  );
}
