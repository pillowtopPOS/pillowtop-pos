"use client";

import { useEffect, useRef, useState } from "react";
import Modal from "@/components/Modal";
import { localTodayISO } from "@/lib/dates";
import { hasPermission } from "@/lib/inventory/queries";
import {
  buildCompletionRequest,
  completionNeedsReason,
  completionShowsDateField,
  completionStockTag,
  effectiveLineFulfillment,
  linePickupLocationId,
  pickupLocationNote,
  STOCK_TAG_LABEL,
  type CompletionReadState,
} from "@/lib/journeys/completion";
import {
  fetchJourneyRequirementStatuses,
  recordJourneyFulfillment,
  type JourneyLineItem,
  type JourneyWithDetails,
  type Store,
} from "@/lib/journeys/queries";

// Slice 2a: per-unit pickup handover. Lets the user choose how many units
// of each pickup line leave now; the record_journey_fulfillment RPC
// re-checks every rule on write and its errors are shown inline.
export default function HandoverDialog({
  journey,
  lineItems,
  handed,
  stores,
  activeStoreId,
  canPickupAnyLocation,
  onClose,
  onSuccess,
}: {
  journey: JourneyWithDetails;
  lineItems: JourneyLineItem[];
  // Units already handed over, keyed by line_item_id.
  handed: Record<string, number>;
  stores: Store[];
  activeStoreId: string | null;
  canPickupAnyLocation: boolean;
  onClose: () => void;
  onSuccess: () => void;
}) {
  const today = localTodayISO();
  const storeName = (id: string) =>
    stores.find((s) => s.id === id)?.name ??
    (id === journey.store_id ? journey.store?.name ?? null : null) ??
    "another location";

  const pickupLines = lineItems.filter(
    (li) =>
      effectiveLineFulfillment(li, journey.fulfillment_type) === "pickup" &&
      li.quantity - (handed[li.id] ?? 0) > 0
  );

  const [quantities, setQuantities] = useState<Record<string, number>>(() =>
    Object.fromEntries(pickupLines.map((li) => [li.id, li.quantity - (handed[li.id] ?? 0)]))
  );
  const [reqStatus, setReqStatus] = useState<Record<string, string>>({});
  const [stockState, setStockState] = useState<CompletionReadState>("loading");
  const [canBackdate, setCanBackdate] = useState<boolean | null>(null);
  const [completedOn, setCompletedOn] = useState(today);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const inFlight = useRef(false);

  useEffect(() => {
    let alive = true;
    fetchJourneyRequirementStatuses(journey.id)
      .then((statuses) => {
        if (!alive) return;
        setReqStatus(statuses);
        setStockState("loaded");
      })
      .catch(() => {
        if (alive) setStockState("failed");
      });
    hasPermission("orders.backdate_fulfillment").then((ok) => {
      if (alive) setCanBackdate(ok);
    });
    return () => {
      alive = false;
    };
  }, [journey.id]);

  const totalChosen = Object.values(quantities).reduce((a, b) => a + b, 0);

  const request = buildCompletionRequest({
    canBackdate: canBackdate === true,
    today,
    completedOn,
    reason,
  });

  const confirmDisabled =
    busy ||
    stockState !== "loaded" ||
    canBackdate === null ||
    totalChosen === 0 ||
    !!request.error;

  async function confirm() {
    if (inFlight.current) return;
    if (request.error) {
      setError(request.error);
      return;
    }
    inFlight.current = true;
    setBusy(true);
    setError(null);
    try {
      await recordJourneyFulfillment(
        journey.id,
        pickupLines
          .filter((li) => (quantities[li.id] ?? 0) > 0)
          .map((li) => ({ lineItemId: li.id, quantity: quantities[li.id] })),
        { completedOn: request.completedOn, reason: request.reason }
      );
      onSuccess();
    } catch (e: any) {
      setError(e.message ?? "Failed to record the handover");
    } finally {
      inFlight.current = false;
      setBusy(false);
    }
  }

  return (
    <Modal onClose={onClose} saving={busy}>
      <div className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
        <h2 className="mb-1 text-lg font-semibold text-slate-900">
          Items being picked up
        </h2>
        <p className="mb-4 text-sm text-slate-500">
          Choose what is leaving today. Anything left behind stays on the
          order.
        </p>

        {stockState === "failed" && (
          <p className="mb-3 text-sm text-slate-600">
            Could not load stock for this order. Close this window and open
            it again.
          </p>
        )}

        <div className="space-y-3">
          {pickupLines.map((li) => {
            const remaining = li.quantity - (handed[li.id] ?? 0);
            const locId = linePickupLocationId(li, journey.store_id);
            const locName = storeName(locId);
            const locationLocked =
              !canPickupAnyLocation && locId !== activeStoreId;
            const tag = li.product_id
              ? completionStockTag(reqStatus[li.product_id])
              : null;
            const outOfStock = tag === "not_in_stock";
            const editable = !locationLocked && !outOfStock;
            const qty = editable ? quantities[li.id] ?? 0 : 0;
            return (
              <div
                key={li.id}
                className="rounded-md border border-slate-200 px-3 py-2"
              >
                <div className="flex items-center justify-between gap-3">
                  <div className="min-w-0">
                    <div className="truncate text-sm font-medium text-slate-900">
                      {li.item_name}
                    </div>
                    <div className="text-xs text-slate-500">
                      At {locName}
                      {(handed[li.id] ?? 0) > 0 &&
                        ` · Out ${handed[li.id]} of ${li.quantity}`}
                    </div>
                  </div>
                  <div className="flex items-center gap-2">
                    <button
                      type="button"
                      disabled={!editable || qty <= 0}
                      onClick={() =>
                        setQuantities((q) => ({ ...q, [li.id]: Math.max(0, (q[li.id] ?? 0) - 1) }))
                      }
                      className="h-7 w-7 rounded-md border border-slate-300 text-sm text-slate-700 disabled:opacity-40"
                    >
                      -
                    </button>
                    <span className="w-8 text-center text-sm font-medium text-slate-900">
                      {qty}
                    </span>
                    <button
                      type="button"
                      disabled={!editable || qty >= remaining}
                      onClick={() =>
                        setQuantities((q) => ({ ...q, [li.id]: Math.min(remaining, (q[li.id] ?? 0) + 1) }))
                      }
                      className="h-7 w-7 rounded-md border border-slate-300 text-sm text-slate-700 disabled:opacity-40"
                    >
                      +
                    </button>
                    <span className="text-xs text-slate-500">of {remaining}</span>
                  </div>
                </div>
                {locationLocked && (
                  <p className="mt-1 text-xs text-slate-500">
                    {pickupLocationNote([locName])}
                  </p>
                )}
                {outOfStock && (
                  <p className="mt-1 text-xs text-amber-700">
                    {STOCK_TAG_LABEL.not_in_stock} at {locName}
                  </p>
                )}
              </div>
            );
          })}
        </div>

        {completionShowsDateField(canBackdate === true) && (
          <div className="mt-4">
            <label className="block text-sm font-medium text-slate-700">
              Completed on
            </label>
            <input
              type="date"
              max={today}
              value={completedOn}
              onChange={(e) => setCompletedOn(e.target.value)}
              className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
            />
            <p className="mt-1 text-xs text-slate-500">
              Leave as today unless this was completed earlier.
            </p>
          </div>
        )}
        {completionNeedsReason(completedOn, today) &&
          completionShowsDateField(canBackdate === true) && (
            <div className="mt-3">
              <label className="block text-sm font-medium text-slate-700">
                Reason for the earlier date
              </label>
              <input
                type="text"
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              />
            </div>
          )}

        {error && (
          <p
            role="alert"
            className="mt-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700"
          >
            {error}
          </p>
        )}

        <div className="mt-5 flex gap-2">
          <button
            onClick={confirm}
            disabled={confirmDisabled}
            className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
          >
            {busy ? "Saving..." : "Mark picked up"}
          </button>
          <button
            onClick={onClose}
            disabled={busy}
            className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
          >
            Cancel
          </button>
        </div>
      </div>
    </Modal>
  );
}
