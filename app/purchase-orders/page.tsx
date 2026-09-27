"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import {
  fetchCurrentEmployee,
  fetchStores,
  type Employee,
  type Store,
} from "@/lib/journeys/queries";
import {
  fetchPurchaseOrders,
  type PurchaseOrder,
} from "@/lib/purchase-orders/queries";

const STATUS_CLASS: Record<string, string> = {
  draft: "text-slate-600 bg-slate-100",
  submitted: "text-blue-700 bg-blue-50",
  partially_received: "text-amber-700 bg-amber-50",
  received: "text-emerald-700 bg-emerald-50",
  shipped: "text-emerald-700 bg-emerald-50",
  cancelled: "text-slate-500 bg-slate-100",
};

const STATUS_LABEL: Record<string, string> = {
  draft: "Draft",
  submitted: "Submitted",
  partially_received: "Partially received",
  received: "Received",
  shipped: "Shipped",
  cancelled: "Cancelled",
};

export default function PurchaseOrdersPage() {
  const [employee, setEmployee] = useState<Employee | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [orders, setOrders] = useState<PurchaseOrder[]>([]);
  const [statusFilter, setStatusFilter] = useState("");
  const [loading, setLoading] = useState(true);
  const canWrite = ["owner", "admin", "manager"].includes(
    employee?.role ?? "",
  );

  useEffect(() => {
    Promise.all([fetchCurrentEmployee(), fetchStores(), fetchPurchaseOrders()])
      .then(([e, st, po]) => {
        setEmployee(e);
        setStores(st);
        setOrders(po);
      })
      .finally(() => setLoading(false));
  }, []);

  const filtered = statusFilter
    ? orders.filter((o) => o.status === statusFilter)
    : orders;

  return (
    <main className="min-h-screen bg-slate-50 p-6">
      <div className="mx-auto max-w-5xl">
        <div className="mb-6 flex items-center justify-between">
          <h1 className="text-2xl font-semibold text-slate-900">
            Purchase Orders
          </h1>
          <div className="flex items-center gap-3">
            <Link
              href="/inventory"
              className="rounded border bg-white px-3 py-2 text-sm text-slate-700"
            >
              Inventory
            </Link>
            {canWrite && (
              <Link
                href="/purchase-orders/new"
                className="rounded bg-brand-600 px-4 py-2 text-sm text-white"
              >
                New Purchase Order
              </Link>
            )}
          </div>
        </div>

        <div className="mb-4 flex items-center gap-2">
          <select
            value={statusFilter}
            onChange={(e) => setStatusFilter(e.target.value)}
            className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm"
          >
            <option value="">All statuses</option>
            {Object.entries(STATUS_LABEL).map(([v, l]) => (
              <option key={v} value={v}>
                {l}
              </option>
            ))}
          </select>
        </div>

        <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
          <table className="w-full">
            <thead className="border-b border-slate-200 bg-slate-50">
              <tr>
                <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wide text-slate-500">
                  Ref
                </th>
                <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wide text-slate-500">
                  Vendor
                </th>
                <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wide text-slate-500">
                  Destination
                </th>
                <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wide text-slate-500">
                  Status
                </th>
                <th className="px-4 py-3 text-left text-xs font-medium uppercase tracking-wide text-slate-500">
                  Created
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {!loading && filtered.length === 0 && (
                <tr>
                  <td
                    colSpan={5}
                    className="px-4 py-8 text-center text-sm text-slate-500"
                  >
                    No purchase orders yet.
                  </td>
                </tr>
              )}
              {filtered.map((o) => (
                <tr key={o.id} className="hover:bg-slate-50">
                  <td className="px-4 py-3 text-sm font-medium">
                    <Link
                      href={`/purchase-orders/${o.id}`}
                      className="text-brand-700 hover:underline"
                    >
                      {o.reference_code ?? "—"}
                    </Link>
                  </td>
                  <td className="px-4 py-3 text-sm font-medium text-slate-900">
                    {o.vendor_name}
                  </td>
                  <td className="px-4 py-3 text-sm text-slate-700">
                    {stores.find((s) => s.id === o.destination_location_id)
                      ?.name ?? "—"}
                  </td>
                  <td className="px-4 py-3">
                    <span
                      className={`inline-block rounded-full px-2 py-0.5 text-xs font-medium ${
                        STATUS_CLASS[o.status] ??
                        "text-slate-600 bg-slate-100"
                      }`}
                    >
                      {STATUS_LABEL[o.status] ?? o.status.replace("_", " ")}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-sm text-slate-500">
                    {new Date(o.created_at).toLocaleDateString()}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </div>
    </main>
  );
}
