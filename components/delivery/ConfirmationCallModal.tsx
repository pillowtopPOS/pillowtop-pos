"use client";

// D1-c2b part 3a: log one night-before confirmation call. Pure modal —
// the parent owns the list refresh. The idempotency key is generated
// once per open and reused across retries so a double-click or a
// retry after an error can never write two rows.
//
// "Needs a different day" offers follow-up actions. The call is ALWAYS
// saved first; the follow-up (reschedule via the booking window, or
// release back to Ready to Schedule via cancel_delivery_stop) runs
// only after the save lands, uses existing RPCs unchanged, and never
// retries on its own.

import { useEffect, useRef, useState } from "react";
import Modal from "@/components/Modal";
import {
  cancelDeliveryStop,
  fetchJourneyDelivery,
  logDeliveryConfirmation,
} from "@/lib/delivery/queries";
import {
  CONFIRMATION_OUTCOMES,
  formatPhoneDashed,
  type ConfirmationOutcome,
} from "@/lib/delivery/calls";

function newIdempotencyKey(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return crypto.randomUUID();
  }
  return `${Date.now()}-${Math.random().toString(36).slice(2)}`;
}

export default function ConfirmationCallModal({
  journeyId,
  stopId,
  customerName,
  customerPhone,
  windowText,
  onClose,
  onSaved,
  onPickNewDay,
}: {
  journeyId: string;
  stopId: string;
  customerName: string | null;
  customerPhone: string | null;
  /** The window (or date, in day_only mode) being confirmed. */
  windowText: string;
  onClose: () => void;
  /** Call logged and any follow-up finished (or declined). `notice`
   *  is an optional plain message for the page to show. */
  onSaved: (notice?: string) => void;
  /** "Pick a new day now": the call is already saved; the parent opens
   *  the reschedule window and owns what happens next. */
  onPickNewDay?: () => void;
}) {
  const [outcome, setOutcome] = useState<ConfirmationOutcome | null>(null);
  const [note, setNote] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Move/release need the same gate the booking RPCs use: an active
  // employee who can see the journey. Probed lazily, only when the
  // outcome needs it.
  const [canMove, setCanMove] = useState<boolean | null>(null);
  // Fresh per modal open; a retry after an error reuses the same key.
  const idemKey = useRef<string | null>(null);
  if (idemKey.current === null) idemKey.current = newIdempotencyKey();

  useEffect(() => {
    if (outcome !== "needs_different_day" || canMove !== null) return;
    let cancelled = false;
    fetchJourneyDelivery(journeyId)
      .then(() => {
        if (!cancelled) setCanMove(true);
      })
      .catch(() => {
        if (!cancelled) setCanMove(false);
      });
    return () => {
      cancelled = true;
    };
  }, [outcome, journeyId, canMove]);

  // The ONE write for the call itself. Returns true when the row is
  // safely stored (fresh or deduplicated); never throws.
  const saveCall = async (): Promise<boolean> => {
    if (!outcome || busy) return false;
    setBusy(true);
    setError(null);
    try {
      await logDeliveryConfirmation({
        journeyId,
        stopId,
        outcome,
        note,
        idempotencyKey: idemKey.current as string,
      });
      return true;
    } catch (e) {
      setError(
        (e as Error)?.message ?? "Couldn't log the call. Please try again."
      );
      return false;
    } finally {
      setBusy(false);
    }
  };

  const handleSave = async () => {
    if (await saveCall()) onSaved();
  };

  const handlePickNewDay = async () => {
    // Call first; the parent takes over for the reschedule window.
    if (await saveCall()) onPickNewDay?.();
  };

  const handleRelease = async () => {
    if (!note.trim()) {
      setError("Add a note first — it is used as the cancel reason.");
      return;
    }
    if (!(await saveCall())) return;
    try {
      await cancelDeliveryStop(stopId, note.trim());
      onSaved();
    } catch {
      // The call is already logged; never pretend the release worked.
      onSaved("Call saved. The delivery was not moved.");
    }
  };

  const needsDay = outcome === "needs_different_day";
  const actionButtons = needsDay && canMove !== false;

  return (
    <Modal onClose={onClose} saving={busy}>
      <div
        data-testid="confirmation-call-modal"
        className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-5 shadow-lg"
      >
        <h2 className="text-lg font-semibold text-slate-900">
          Log confirmation call
        </h2>
        <div className="mt-1 text-sm text-slate-700">
          <p className="font-medium">{customerName ?? "Customer"}</p>
          {customerPhone && <p>{formatPhoneDashed(customerPhone)}</p>}
          <p className="text-slate-500">Confirming: {windowText}</p>
        </div>

        <fieldset className="mt-4">
          <legend className="text-sm font-medium text-slate-700">
            How did it go?
          </legend>
          <div className="mt-2 space-y-1.5">
            {CONFIRMATION_OUTCOMES.map((o) => (
              <label
                key={o.value}
                className="flex cursor-pointer items-center gap-2 rounded-md border border-slate-200 px-3 py-2 text-sm text-slate-700 has-[:checked]:border-slate-400 has-[:checked]:bg-slate-50"
              >
                <input
                  type="radio"
                  name="confirmation-outcome"
                  value={o.value}
                  checked={outcome === o.value}
                  onChange={() => setOutcome(o.value)}
                  className="h-4 w-4 border-slate-300 text-slate-900 focus:ring-slate-500"
                />
                {o.label}
              </label>
            ))}
          </div>
        </fieldset>

        <label
          htmlFor="confirmation-call-note"
          className="mt-4 block text-sm font-medium text-slate-700"
        >
          Note <span className="font-normal text-slate-400">(optional)</span>
        </label>
        <textarea
          id="confirmation-call-note"
          data-testid="confirmation-call-note"
          value={note}
          onChange={(e) => setNote(e.target.value)}
          rows={2}
          className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          placeholder="Anything worth remembering?"
        />

        {needsDay && canMove === false && (
          <p className="mt-3 text-sm text-slate-600">
            Ask a manager to move this delivery.
          </p>
        )}
        {needsDay && (
          <div className="mt-3 space-y-2">
            {actionButtons ? (
              <>
                <button
                  type="button"
                  data-testid="confirmation-pick-new-day"
                  onClick={handlePickNewDay}
                  disabled={busy}
                  className="w-full rounded-md bg-slate-900 px-3 py-2 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-40"
                >
                  Pick a new day now
                </button>
                <button
                  type="button"
                  data-testid="confirmation-release-stop"
                  onClick={handleRelease}
                  disabled={busy}
                  className="w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-40"
                >
                  Put back in Ready to Schedule
                </button>
                <button
                  type="button"
                  data-testid="confirmation-just-log"
                  onClick={handleSave}
                  disabled={busy}
                  className="w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-40"
                >
                  Just log it
                </button>
              </>
            ) : canMove === false ? (
              <button
                type="button"
                data-testid="confirmation-just-log"
                onClick={handleSave}
                disabled={busy}
                className="w-full rounded-md bg-slate-900 px-3 py-2 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-40"
              >
                Just log it
              </button>
            ) : null}
          </div>
        )}

        {error && (
          <p
            data-testid="confirmation-call-error"
            className="mt-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700"
          >
            {error}
          </p>
        )}

        <div className="mt-4 flex gap-2">
          <button
            type="button"
            onClick={onClose}
            disabled={busy}
            className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
          >
            Cancel
          </button>
          {!needsDay && (
            <button
              type="button"
              data-testid="confirmation-call-save"
              onClick={handleSave}
              disabled={!outcome || busy}
              className="flex-1 rounded-md bg-slate-900 px-3 py-2 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-40"
            >
              {busy ? "Saving…" : "Save call"}
            </button>
          )}
        </div>
      </div>
    </Modal>
  );
}
