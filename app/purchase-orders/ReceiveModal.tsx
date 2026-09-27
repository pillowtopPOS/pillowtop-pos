"use client";

import { useState } from "react";
import { createClient } from "@/lib/supabase/client";
import Modal from "@/components/Modal";
import type { PurchaseOrder, POProduct } from "@/lib/purchase-orders/queries";

export default function ReceiveModal({
  po,
  products,
  onClose,
  onDone,
}: {
  po: PurchaseOrder;
  products: POProduct[];
  onClose: () => void;
  onDone: () => Promise<void>;
}) {
  const [values, setValues] = useState<Record<string, string>>({});
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function recordReceipt() {
    const entries = po.lines
      .map((l) => ({
        line: l,
        qty: Math.floor(Number(values[l.id] ?? "")),
      }))
      .filter((x) => x.qty > 0);

    if (!entries.length) {
      setError("Enter a quantity for at least one line.");
      return;
    }
    for (const { line, qty } of entries) {
      const remaining = line.quantity_ordered - line.quantity_received;
      if (qty > remaining) {
        const name =
          products.find((p) => p.id === line.variant_id)?.item_name ??
          "a line";
        setError(
          `${name}: cannot receive ${qty}, only ${remaining} remaining.`,
        );
        return;
      }
    }

    setSubmitting(true);
    setError(null);
    const s = createClient();
    for (const { line, qty } of entries) {
      const r = await s.rpc("receive_purchase_order_line", {
        p_line_item_id: line.id,
        p_quantity: qty,
      });
      if (r.error) {
        setError(r.error.message);
        setSubmitting(false);
        await onDone();
        return;
      }
    }
    setSubmitting(false);
    onClose();
    await onDone();
  }

  return (
    <Modal
      onClose={onClose}
      overlayClassName="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
      dirty={Object.values(values).some((v) => v.trim() !== "")}
      saving={submitting}
    >
      <div className="max-h-[90vh] w-full max-w-lg overflow-y-auto rounded-lg bg-white p-6 shadow-xl">
        <h3 className="text-lg font-semibold">
          Receive — {po.vendor_name}
          {po.reference_code && (
            <span className="ml-2 rounded bg-brand-50 px-1.5 py-0.5 text-xs font-semibold text-brand-700">
              {po.reference_code}
            </span>
          )}
        </h3>
        <p className="mt-1 text-sm text-slate-500">
          Enter how much of each item arrived in this delivery. Lines left
          blank or at 0 are not received.
        </p>
        <div className="mt-4 space-y-3">
          {po.lines.map((l) => {
            const remaining = l.quantity_ordered - l.quantity_received;
            return (
              <div
                key={l.id}
                className="flex items-center justify-between gap-3 text-sm"
              >
                <div>
                  <p className="font-medium">
                    {products.find((p) => p.id === l.variant_id)?.item_name ??
                      l.variant_id}
                  </p>
                  <p className="text-xs text-slate-500">
                    Ordered: {l.quantity_ordered} · Received so far:{" "}
                    {l.quantity_received} · Remaining: {remaining}
                  </p>
                </div>
                <label className="text-xs text-slate-500">
                  Receive now
                  <input
                    type="number"
                    min={0}
                    max={remaining}
                    disabled={remaining === 0}
                    value={values[l.id] ?? ""}
                    placeholder="0"
                    onChange={(e) =>
                      setValues((v) => ({ ...v, [l.id]: e.target.value }))
                    }
                    className="mt-0.5 block w-24 rounded border px-2 py-1 text-sm disabled:bg-slate-100"
                  />
                </label>
              </div>
            );
          })}
        </div>
        {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
        <div className="mt-5 flex justify-end gap-2">
          <button
            onClick={onClose}
            disabled={submitting}
            className="rounded border px-3 py-1.5 text-sm"
          >
            Cancel
          </button>
          <button
            onClick={() => void recordReceipt()}
            disabled={submitting}
            className="rounded bg-brand-600 px-4 py-1.5 text-sm text-white disabled:opacity-50"
          >
            {submitting ? "Recording…" : "Record receipt"}
          </button>
        </div>
      </div>
    </Modal>
  );
}
