"use client";

import { useCallback, useEffect, useState } from "react";
import { useParams } from "next/navigation";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import {
  fetchCurrentEmployee,
  fetchStores,
  type Employee,
  type Store,
} from "@/lib/journeys/queries";
import { Printer } from "lucide-react";
import type { Product } from "@/lib/inventory/queries";
import {
  fetchPurchaseOrder,
  fetchPOProducts,
  fetchPOEvents,
  poTotal,
  PO_EDITABLE_STATUSES,
  type PurchaseOrder,
  type POLine,
  type POProduct,
  type POEvent,
} from "@/lib/purchase-orders/queries";
import LineEditor from "../LineEditor";
import ReceiveModal from "../ReceiveModal";
import Modal from "@/components/Modal";
import ProductSearch from "../ProductSearch";
import ShipTo from "../ShipTo";

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

export default function PurchaseOrderDetailPage() {
  const params = useParams();
  const poId = params?.id as string;

  const [employee, setEmployee] = useState<Employee | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [products, setProducts] = useState<POProduct[]>([]);
  const [po, setPO] = useState<PurchaseOrder | null>(null);
  const [events, setEvents] = useState<POEvent[]>([]);
  const [loading, setLoading] = useState(true);
  const [lineEdits, setLineEdits] = useState<
    Record<string, { quantity_ordered: number; unit_cost: number }>
  >({});
  const [receiveOpen, setReceiveOpen] = useState(false);
  const [historyOpen, setHistoryOpen] = useState(false);
  const [shipOpen, setShipOpen] = useState(false);
  const [tracking, setTracking] = useState("");
  const [shipping, setShipping] = useState(false);

  const canWrite = ["owner", "admin", "manager"].includes(
    employee?.role ?? "",
  );
  const isDropShip = po?.fulfillment_type === "drop_ship";
  const editable =
    canWrite && po !== null && PO_EDITABLE_STATUSES.includes(po.status);
  const hasOpenLines =
    po?.lines.some((l) => l.quantity_received < l.quantity_ordered) ?? false;

  const load = useCallback(async () => {
    const [e, st, pr, p, ev] = await Promise.all([
      fetchCurrentEmployee(),
      fetchStores(true),
      fetchPOProducts(),
      fetchPurchaseOrder(poId),
      fetchPOEvents(poId),
    ]);
    setEmployee(e);
    setStores(st);
    setProducts(pr);
    setPO(p);
    setEvents(ev);
    setLoading(false);
  }, [poId]);

  useEffect(() => {
    void load();
  }, [load]);

  async function submit() {
    if (!po) return;
    await createClient()
      .from("purchase_orders")
      .update({ status: "submitted", submitted_at: new Date().toISOString() })
      .eq("id", po.id);
    await load();
  }

  async function markShipped() {
    if (!po) return;
    setShipping(true);
    const { error: err } = await createClient()
      .from("purchase_orders")
      .update({
        status: "shipped",
        tracking_number: tracking.trim() || null,
      })
      .eq("id", po.id);
    setShipping(false);
    if (err) {
      window.alert(err.message);
      return;
    }
    setShipOpen(false);
    setTracking("");
    await load();
  }

  // --- Line editing (RLS + triggers restrict this to editable statuses) ---

  function lineEditValue(
    l: POLine,
    key: "quantity_ordered" | "unit_cost",
  ): number {
    return lineEdits[l.id]?.[key] ?? l[key];
  }

  function stageLineEdit(
    l: POLine,
    key: "quantity_ordered" | "unit_cost",
    value: number,
  ) {
    setLineEdits((m) => {
      const current = m[l.id] ?? {
        quantity_ordered: l.quantity_ordered,
        unit_cost: l.unit_cost,
      };
      return { ...m, [l.id]: { ...current, [key]: value } };
    });
  }

  async function commitLineEdit(l: POLine) {
    const e = lineEdits[l.id];
    if (!e) return;
    setLineEdits((m) => {
      const next = { ...m };
      delete next[l.id];
      return next;
    });
    const quantity_ordered = Math.max(1, Math.floor(e.quantity_ordered) || 1);
    const unit_cost = Math.max(0, e.unit_cost) || 0;
    if (quantity_ordered < l.quantity_received) {
      window.alert(
        `Ordered quantity can't be less than already received (${l.quantity_received}).`,
      );
      return;
    }
    if (
      quantity_ordered === l.quantity_ordered &&
      unit_cost === l.unit_cost
    ) {
      return;
    }
    const { error: err } = await createClient()
      .from("purchase_order_line_items")
      .update({ quantity_ordered, unit_cost })
      .eq("id", l.id);
    if (err) window.alert(err.message);
    await load();
  }

  async function removeLine(l: POLine) {
    const { error: err } = await createClient()
      .from("purchase_order_line_items")
      .delete()
      .eq("id", l.id);
    if (err) window.alert(err.message);
    await load();
  }

  async function addLine(p: Product) {
    if (!po || po.lines.some((l) => l.variant_id === p.id)) return;
    const { error: err } = await createClient()
      .from("purchase_order_line_items")
      .insert({
        purchase_order_id: po.id,
        variant_id: p.id,
        quantity_ordered: 1,
        unit_cost: p.cost ?? 0,
      });
    if (err) window.alert(err.message);
    await load();
  }

  function describeEvent(ev: POEvent): string {
    const d = ev.event_data ?? {};
    const name = products.find((p) => p.id === d.variant_id)?.item_name;
    const label = name ?? "line item";
    switch (ev.event_type) {
      case "line_added":
        return `Added ${label} — qty ${d.quantity_ordered} @ $${d.unit_cost}`;
      case "line_removed":
        return `Removed ${label} (was qty ${d.quantity_ordered})`;
      case "line_modified": {
        const parts: string[] = [];
        const q = d.quantity_ordered as { from?: number; to?: number } | undefined;
        if (q && q.from !== q.to) parts.push(`qty ${q.from} → ${q.to}`);
        const c = d.unit_cost as { from?: number; to?: number } | undefined;
        if (c && c.from !== c.to) parts.push(`cost $${c.from} → $${c.to}`);
        return `Changed ${label}${parts.length ? ": " + parts.join(", ") : ""}`;
      }
      case "partially_received":
        return `Received ${d.quantity} × ${label}`;
      case "received":
        return `Received ${d.quantity} × ${label} — order complete`;
      case "shipped":
        return `Marked shipped to customer${
          d.tracking_number ? ` — tracking ${d.tracking_number}` : ""
        }`;
      default:
        return ev.event_type.replace(/_/g, " ");
    }
  }

  if (loading) {
    return (
      <main className="min-h-screen bg-slate-50 p-6">
        <div className="mx-auto max-w-3xl">
          <p className="text-sm text-slate-500">Loading…</p>
        </div>
      </main>
    );
  }

  if (!po) {
    return (
      <main className="min-h-screen bg-slate-50 p-6">
        <div className="mx-auto max-w-3xl">
          <p className="text-sm text-slate-600">
            Purchase order not found.{" "}
            <Link href="/purchase-orders" className="text-brand-600">
              Back to list
            </Link>
          </p>
        </div>
      </main>
    );
  }

  return (
    <main className="min-h-screen bg-slate-50 p-6">
      <div className="mx-auto max-w-3xl">
        <Link
          href="/purchase-orders"
          className="text-sm text-slate-500 hover:text-slate-700"
        >
          ← Purchase Orders
        </Link>

        <div className="mt-2 flex items-center justify-between">
          <div className="flex items-center gap-3">
            {po.reference_code && (
              <span className="rounded-md bg-brand-50 px-2.5 py-1 text-sm font-semibold text-brand-700">
                {po.reference_code}
              </span>
            )}
            <h1 className="text-2xl font-semibold text-slate-900">
              {po.vendor_name}
            </h1>
            {isDropShip && (
              <span className="inline-block rounded-full bg-violet-50 px-2 py-0.5 text-xs font-medium text-violet-700">
                Drop Ship
              </span>
            )}
            <span
              className={`inline-block rounded-full px-2 py-0.5 text-xs font-medium ${
                STATUS_CLASS[po.status] ?? "text-slate-600 bg-slate-100"
              }`}
            >
              {STATUS_LABEL[po.status] ?? po.status.replace("_", " ")}
            </span>
          </div>
          <div className="flex items-center gap-3">
            <Link
              href={`/purchase-orders/${po.id}/print`}
              className="inline-flex items-center gap-1.5 rounded border bg-white px-3 py-2 text-sm text-slate-700"
            >
              <Printer className="h-4 w-4" /> Print
            </Link>
            <Link
              href="/purchase-orders"
              className="inline-flex items-center rounded border bg-white px-3 py-2 text-sm text-slate-700"
            >
              Done
            </Link>
            {canWrite && (
              <div className="flex gap-3">
                {po.status === "draft" && (
                  <button
                    onClick={() => void submit()}
                    className="rounded bg-brand-600 px-4 py-2 text-sm text-white"
                  >
                    Submit
                  </button>
                )}
                {!isDropShip &&
                  ["submitted", "partially_received"].includes(po.status) &&
                  hasOpenLines && (
                    <button
                      onClick={() => setReceiveOpen(true)}
                      className="rounded bg-brand-600 px-4 py-2 text-sm text-white"
                    >
                      Receive
                    </button>
                  )}
                {isDropShip && po.status === "submitted" && (
                  <button
                    onClick={() => setShipOpen(true)}
                    className="rounded bg-brand-600 px-4 py-2 text-sm text-white"
                  >
                    Mark as Shipped
                  </button>
                )}
              </div>
            )}
          </div>
        </div>
        <p className="mt-1 text-sm text-slate-500">
          {isDropShip ? "Attributed to " : ""}
          {stores.find((s) => s.id === po.destination_location_id)?.name ??
            "—"}{" "}
          · Created {new Date(po.created_at).toLocaleDateString()}
          {po.shipped_at &&
            ` · Shipped ${new Date(po.shipped_at).toLocaleDateString()}`}
          {po.tracking_number && ` · Tracking: ${po.tracking_number}`}
        </p>

        <div className="mt-4 rounded-lg border bg-white p-4">
          <ShipTo
            po={po}
            destination={stores.find(
              (s) => s.id === po.destination_location_id,
            )}
          />
        </div>

        <section className="mt-6 rounded-lg border bg-white p-5">
          <h2 className="mb-1 font-semibold">Line items</h2>
          {po.lines.length === 0 && (
            <p className="py-3 text-sm text-slate-500">No line items.</p>
          )}
          {po.lines.map((l) =>
            editable ? (
              <LineEditor
                key={l.id}
                name={
                  products.find((p) => p.id === l.variant_id)?.item_name ??
                  l.variant_id
                }
                quantity={lineEditValue(l, "quantity_ordered")}
                unitCost={lineEditValue(l, "unit_cost")}
                minQty={Math.max(1, l.quantity_received)}
                onQuantity={(v) => stageLineEdit(l, "quantity_ordered", v)}
                onCost={(v) => stageLineEdit(l, "unit_cost", v)}
                onBlurCommit={() => void commitLineEdit(l)}
                onRemove={
                  l.quantity_received === 0
                    ? () => void removeLine(l)
                    : undefined
                }
              />
            ) : (
              <div
                key={l.id}
                className="mt-2 flex justify-between border-t pt-2 text-sm"
              >
                <span>
                  {products.find((p) => p.id === l.variant_id)?.item_name}
                </span>
                <span className="text-slate-500">
                  Ordered: {l.quantity_ordered} · Received:{" "}
                  {l.quantity_received}
                </span>
              </div>
            ),
          )}
          {editable && (
            <div className="mt-3">
              <ProductSearch
                placeholder="Add product to this order — search…"
                excludeIds={po.lines.map((l) => l.variant_id)}
                onSelect={(p) => void addLine(p)}
              />
            </div>
          )}
          {po.lines.length > 0 && (
            <div className="mt-4 flex justify-end border-t pt-3 text-sm">
              <span className="font-semibold text-slate-900">
                Total: $
                {poTotal(po.lines).toLocaleString(undefined, {
                  minimumFractionDigits: 2,
                  maximumFractionDigits: 2,
                })}
              </span>
            </div>
          )}
          {editable && po.status !== "draft" && (
            <p className="mt-3 text-xs text-slate-500">
              This order has already been submitted. Changes to line items are
              recorded on the order's event log.
            </p>
          )}
        </section>

        <section className="mt-4 rounded-lg border bg-white">
          <button
            type="button"
            onClick={() => setHistoryOpen((o) => !o)}
            className="flex w-full items-center justify-between px-5 py-3 text-left"
          >
            <h2 className="font-semibold">
              History
              {events.length > 0 && (
                <span className="ml-2 text-xs font-normal text-slate-500">
                  {events.length} event{events.length === 1 ? "" : "s"}
                </span>
              )}
            </h2>
            <span className="text-sm text-slate-400">
              {historyOpen ? "▲" : "▼"}
            </span>
          </button>
          {historyOpen && (
            <div className="border-t px-5 py-3">
              {events.length === 0 ? (
                <p className="text-sm text-slate-500">No events yet.</p>
              ) : (
                <ul className="space-y-2">
                  {events.map((ev) => (
                    <li key={ev.id} className="text-sm">
                      <span className="text-slate-900">
                        {describeEvent(ev)}
                      </span>
                      <span className="ml-2 text-xs text-slate-400">
                        {ev.actor?.name ?? "system"} ·{" "}
                        {new Date(ev.created_at).toLocaleString()}
                      </span>
                    </li>
                  ))}
                </ul>
              )}
            </div>
          )}
        </section>

        {receiveOpen && (
          <ReceiveModal
            po={po}
            products={products}
            onClose={() => setReceiveOpen(false)}
            onDone={async () => {
              await load();
            }}
          />
        )}

        {shipOpen && (
          <Modal
            onClose={() => setShipOpen(false)}
            overlayClassName="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
            dirty={tracking.trim() !== ""}
            saving={shipping}
          >
            <div className="w-full max-w-md rounded-lg bg-white p-6 shadow-xl">
              <h3 className="text-lg font-semibold">Mark as Shipped</h3>
              <p className="mt-1 text-sm text-slate-500">
                Confirms the vendor shipped this order directly to the
                customer. Nothing is added to store inventory.
              </p>
              <label className="mt-4 block text-xs text-slate-500">
                Tracking number (optional)
                <input
                  value={tracking}
                  onChange={(e) => setTracking(e.target.value)}
                  className="mt-0.5 block w-full rounded border px-3 py-2 text-sm"
                />
              </label>
              <div className="mt-5 flex justify-end gap-2">
                <button
                  onClick={() => setShipOpen(false)}
                  disabled={shipping}
                  className="rounded border px-3 py-1.5 text-sm"
                >
                  Cancel
                </button>
                <button
                  onClick={() => void markShipped()}
                  disabled={shipping}
                  className="rounded bg-brand-600 px-4 py-1.5 text-sm text-white disabled:opacity-50"
                >
                  {shipping ? "Saving…" : "Mark as Shipped"}
                </button>
              </div>
            </div>
          </Modal>
        )}
      </div>
    </main>
  );
}
