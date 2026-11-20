"use client";

import { useRef, useState } from "react";
import Modal from "@/components/Modal";
import {
  recordPaymentRefund,
  type JourneyEvent,
} from "@/lib/journeys/queries";
import {
  paymentAmountCents,
  refundableCentsOnPayment,
} from "@/lib/journeys/paid";
import { refundLinkedLine } from "@/lib/journeys/returns";
import { PAYMENT_METHOD_OPTIONS } from "@/lib/journeys/state";

const REFUND_TIMEOUT_MS = 30000;

function withTimeout<T>(
  work: Promise<T>,
  ms: number,
  message: string
): Promise<T> {
  return Promise.race([
    work,
    new Promise<T>((_, reject) => setTimeout(() => reject(new Error(message)), ms)),
  ]);
}

function paymentOptionLabel(p: JourneyEvent): string {
  const amount = `$${(paymentAmountCents(p) / 100).toFixed(2)}`;
  const method = p.event_data?.payment_method
    ? ` ${String(p.event_data.payment_method)}`
    : "";
  const date = new Date(p.created_at).toLocaleDateString();
  return `${amount}${method} · ${date}`;
}

// One refund form shared by the payment-row button (fixed payment) and
// the Financial rail credit-due button (payment picker). Recording only:
// the money is refunded in the payment system first, this logs it.
export default function RecordRefundModal({
  payments,
  events,
  defaultAmountCents,
  initialPaymentId,
  actionId,
  returnProductName,
  lockedAmountCents,
  completesAction,
  serverCapCents,
  onClose,
  onRecorded,
}: {
  // Refundable SUCCEEDED payments, newest first. A single entry means
  // the caller already picked the payment and no picker renders.
  payments: JourneyEvent[];
  // The journey's full event feed so refundableCentsOnPayment can net
  // refunds already recorded against each payment.
  events: JourneyEvent[];
  // What the amount starts at, capped by the selected payment.
  defaultAmountCents: number;
  // Selected payment on open; defaults to the first entry.
  initialPaymentId?: string;
  // 161: when set the refund is linked to this return action and the
  // server stamps its refund fields in the same transaction.
  actionId?: string;
  // Product name for the "recorded for the return of ..." line shown
  // when actionId is set.
  returnProductName?: string | null;
  // 162: when set the amount is system-computed and read-only; callers
  // without payments.adjust_refund_amount must pass exactly this.
  lockedAmountCents?: number | null;
  // 162: recording this refund lands the last milestone, so the action
  // completes automatically. Drives the confirmation line.
  completesAction?: "RETURN" | "EXCHANGE" | null;
  // 162 held-money mirror: the server's ceiling for an unlinked refund
  // (net paid minus money held for committed actions). The amount field
  // and submit refuse past it instead of surfacing the server error.
  // Pass only for unlinked refunds; linked refunds settle held money and
  // are exempt.
  serverCapCents?: number | null;
  onClose: () => void;
  onRecorded: () => void | Promise<void>;
}) {
  const [paymentId, setPaymentId] = useState(
    initialPaymentId ?? payments[0]?.id ?? ""
  );
  const payment = payments.find((p) => p.id === paymentId) ?? payments[0];
  const maxCents = payment ? refundableCentsOnPayment(payment, events) : 0;
  const [amount, setAmount] = useState(() =>
    ((lockedAmountCents ?? Math.min(defaultAmountCents, maxCents)) / 100).toFixed(2)
  );
  const [method, setMethod] = useState(PAYMENT_METHOD_OPTIONS[0]);
  const [reason, setReason] = useState("");
  const [reference, setReference] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const inFlight = useRef(false);

  // Live mirror of the server's caps so the submit button refuses what
  // the RPC would reject: more than the payment has left, or past the
  // held-money ceiling on an unlinked refund.
  const enteredCents = Math.round(parseFloat(amount) * 100);
  const overPayment =
    lockedAmountCents == null &&
    Number.isFinite(enteredCents) &&
    enteredCents > maxCents;
  const overHeld =
    lockedAmountCents == null &&
    serverCapCents != null &&
    Number.isFinite(enteredCents) &&
    enteredCents > serverCapCents;

  function pickPayment(id: string) {
    setPaymentId(id);
    if (lockedAmountCents != null) return;
    const next = payments.find((p) => p.id === id);
    if (next) {
      const left = refundableCentsOnPayment(next, events);
      setAmount((Math.min(defaultAmountCents, left) / 100).toFixed(2));
    }
  }

  async function submit() {
    if (!payment || inFlight.current) return;
    const cents = Math.round(parseFloat(amount) * 100);
    if (!(cents > 0)) {
      setError("Enter an amount above $0.");
      return;
    }
    if (cents > maxCents) {
      setError(
        `This payment only has $${(maxCents / 100).toFixed(2)} left to refund.`
      );
      return;
    }
    if (!reason.trim()) {
      setError("A reason is required to record a refund.");
      return;
    }
    inFlight.current = true;
    setSaving(true);
    setError(null);
    try {
      await withTimeout(
        recordPaymentRefund(
          payment.id,
          cents / 100,
          method,
          reason.trim(),
          reference.trim() || undefined,
          actionId
        ),
        REFUND_TIMEOUT_MS,
        "The refund request timed out. Check whether it was recorded before trying again."
      );
      // The refund can auto-complete its action, so the dialog waits for
      // the caller's refresh before closing; otherwise the card behind it
      // shows a state that is already done.
      await onRecorded();
      onClose();
    } catch (e: any) {
      setError(e.message ?? "Failed to record the refund");
    } finally {
      inFlight.current = false;
      setSaving(false);
    }
  }

  return (
    <Modal
      onClose={onClose}
      saving={saving}
      dirty={reason.trim() !== "" || reference.trim() !== ""}
    >
      <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
        <h2 className="mb-2 text-lg font-semibold text-slate-900">
          Record refund
        </h2>
        <p className="mb-3 text-sm text-slate-600">
          This records a refund you already made in your payment system.
          PillowTop does not move money.
        </p>
        {actionId && (
          <p className="mb-3 rounded-md border border-violet-200 bg-violet-50 px-2.5 py-1.5 text-xs text-violet-800">
            {refundLinkedLine(completesAction ?? "RETURN", returnProductName)}
          </p>
        )}
        {payments.length > 1 && (
          <label className="mb-3 block text-sm font-medium text-slate-700">
            Refund from
            <select
              value={payment?.id ?? ""}
              onChange={(e) => pickPayment(e.target.value)}
              className="mt-1 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm"
            >
              {payments.map((p) => (
                <option key={p.id} value={p.id}>
                  {paymentOptionLabel(p)} (${(
                    refundableCentsOnPayment(p, events) / 100
                  ).toFixed(2)}{" "}
                  left)
                </option>
              ))}
            </select>
          </label>
        )}
        <label className="mb-3 block text-sm font-medium text-slate-700">
          Refund amount
          <input
            type="number"
            min={0}
            step="0.01"
            value={amount}
            readOnly={lockedAmountCents != null}
            onChange={(e) => setAmount(e.target.value)}
            className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500 read-only:bg-slate-50 read-only:text-slate-600"
          />
          {lockedAmountCents != null && (
            <span className="mt-1 block text-xs text-slate-500">
              The system sets this amount. A manager can change it.
            </span>
          )}
          {overPayment && (
            <span className="mt-1 block text-xs text-amber-700">
              This payment only has ${(maxCents / 100).toFixed(2)} left to
              refund.
            </span>
          )}
          {!overPayment && overHeld && (
            <span className="mt-1 block text-xs text-amber-700">
              This refund would touch money held for a committed return or
              exchange. Record that refund from the return card.
            </span>
          )}
        </label>
        {completesAction && (
          <p className="mb-3 text-sm font-semibold text-slate-900">
            Recording this refund completes the{" "}
            {completesAction === "RETURN" ? "return" : "exchange"}.
          </p>
        )}
        <label className="mb-3 block text-sm font-medium text-slate-700">
          Refund method
          <select
            value={method}
            onChange={(e) => setMethod(e.target.value)}
            className="mt-1 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm"
          >
            {PAYMENT_METHOD_OPTIONS.map((m) => (
              <option key={m} value={m}>
                {m}
              </option>
            ))}
          </select>
        </label>
        <label className="mb-3 block text-sm font-medium text-slate-700">
          Reason
          <input
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            placeholder="Why is this refund being made?"
            className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          />
        </label>
        <label className="block text-sm font-medium text-slate-700">
          Reference (optional)
          <input
            value={reference}
            onChange={(e) => setReference(e.target.value)}
            placeholder="Processor refund id, receipt, etc."
            className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          />
        </label>
        {error && <p className="mt-3 text-sm text-red-600">{error}</p>}
        <div className="mt-4 flex gap-2">
          <button
            onClick={submit}
            disabled={saving || overPayment || overHeld}
            className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
          >
            {saving ? "Recording…" : "Record refund"}
          </button>
          <button
            onClick={onClose}
            className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            Cancel
          </button>
        </div>
      </div>
    </Modal>
  );
}
