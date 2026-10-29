"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import Modal from "@/components/Modal";
import { activityShortDate } from "@/lib/journeys/activityLabels";
import {
  cancelSleepTrialAction,
  completeSleepTrialAction,
  centsToDollars,
  createQuarantineArea,
  dollarsToCents,
  recordExchangeRefund,
  receiveReturnedUnit,
  voidExchangeRefund,
  voidReturnedReceipt,
  type ExchangeActionRead,
  type ExchangeMilestone,
  type ExchangeRefundMethod,
} from "@/lib/journeys/exchange";
import { fetchStores, type Store } from "@/lib/journeys/queries";
import { createClient } from "@/lib/supabase/client";

// EB-3b: the milestone card on the original journey's Sleep Trial section.
// Every flag (can_cancel, can_record_refund, can_void_refund,
// can_complete) and every blocker is computed server-side by
// get_exchange_action (091) — nothing is recomputed here.

const MILESTONES: { key: keyof ExchangeActionRead["milestones"]; label: string }[] = [
  { key: "replacement_reserved", label: "Replacement reserved" },
  { key: "replacement_delivered", label: "Replacement delivered" },
  { key: "original_received", label: "Original received" },
  { key: "money_settled", label: "Money settled" },
  { key: "completed", label: "Completed" },
];

const REFUND_METHODS: { value: ExchangeRefundMethod; label: string }[] = [
  { value: "card", label: "Card" },
  { value: "cash", label: "Cash" },
  { value: "check", label: "Check" },
  { value: "store_credit", label: "Store credit" },
  { value: "none", label: "None" },
];

const PAID_CUSTOMER_MESSAGE =
  "The replacement already has a payment on record. Record a refund for the payment first (Journey Activity, Payments), then come back and cancel the exchange. Make sure the money has actually gone back to the customer first, because PillowTop only records it.";

function fmt(cents: number | null | undefined): string {
  return `$${((cents ?? 0) / 100).toFixed(2)}`;
}

function MilestoneLine({ label, m }: { label: string; m: ExchangeMilestone }) {
  return (
    <li className="flex items-baseline gap-1.5 text-xs">
      <span
        className={`inline-block h-2 w-2 shrink-0 self-center rounded-full ${
          m.done ? "bg-teal-500" : "bg-slate-300"
        }`}
      />
      <span className={m.done ? "text-slate-700" : "text-slate-500"}>
        {label}
      </span>
      {m.done && m.at && (
        <span className="text-slate-400">· {activityShortDate(m.at)}</span>
      )}
      {m.done && m.by && <span className="text-slate-400">· {m.by}</span>}
    </li>
  );
}

export default function ExchangeMilestoneCard({
  action,
  onChanged,
}: {
  action: ExchangeActionRead;
  onChanged: () => void;
}) {
  const router = useRouter();
  const [dialog, setDialog] = useState<
    "cancel" | "refund" | "void" | "receive" | "voidReceipt" | null
  >(null);
  const submitGuard = useRef(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [cancelReason, setCancelReason] = useState("");
  const [refundMethod, setRefundMethod] =
    useState<ExchangeRefundMethod>("card");
  const [refundAmount, setRefundAmount] = useState("");
  const [refundReference, setRefundReference] = useState("");
  const [voidReason, setVoidReason] = useState("");
  // EB-4a: receive + void-receipt state
  const [receiveDate, setReceiveDate] = useState("");
  const [receiveLocationId, setReceiveLocationId] = useState("");
  const [receiveLocations, setReceiveLocations] = useState<Store[]>([]);
  const [employeeRole, setEmployeeRole] = useState<string | null>(null);
  const [callerCan, setCallerCan] = useState({
    startExchange: false,
    completeExchange: false,
  });
  const [receivedLine, setReceivedLine] = useState<string | null>(null);

  useEffect(() => {
    // Server enforces regardless; this only decides whether the buttons
    // render at all.
    const supabase = createClient();
    Promise.all([
      supabase.rpc("has_permission", { p_key: "sleep_trial.start_exchange" }),
      supabase.rpc("has_permission", { p_key: "sleep_trial.complete_exchange" }),
    ]).then(([a, b]) =>
      setCallerCan({
        startExchange: !!a.data,
        completeExchange: !!b.data,
      })
    );
  }, []);

  useEffect(() => {
    if (!action.original_received_on) {
      setReceivedLine(null);
      return;
    }
    const supabase = createClient();
    supabase
      .from("journey_interactions")
      .select("summary")
      .eq("source_record_id", action.action_id)
      .like("summary", "Original mattress received%")
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle()
      .then(({ data }) => setReceivedLine(data?.summary ?? null));
  }, [action.action_id, action.original_received_on]);

  const owed = action.refund_owed_cents ?? 0;
  const refundRecorded = action.refund_recorded_at != null;
  const history = action.refund_history ?? [];

  function open(which: "cancel" | "refund" | "void" | "receive" | "voidReceipt") {
    setError(null);
    if (which === "refund") {
      setRefundMethod("card");
      setRefundAmount(centsToDollars(owed));
      setRefundReference("");
    }
    if (which === "cancel") setCancelReason("");
    if (which === "void") setVoidReason("");
    if (which === "receive") {
      setReceiveDate(new Date().toISOString().slice(0, 10));
      void primeReceiveForm();
    }
    if (which === "voidReceipt") setVoidReason("");
    setDialog(which);
  }

  // Load the location picker and the employee's role/home store so the
  // default location is their home store and owner/admin get the
  // one-click quarantine fix when the server reports none.
  async function primeReceiveForm() {
    const supabase = createClient();
    const stores = await fetchStores(true);
    const { data: u } = await supabase.auth.getUser();
    let emp: { role: string; home_store_id: string | null } | null = null;
    if (u.user) {
      const res = await supabase
        .from("employees")
        .select("role, home_store_id")
        .eq("auth_user_id", u.user.id)
        .eq("is_active", true)
        .maybeSingle();
      emp = res.data;
    }
    const sellable = stores.filter(
      (l) => l.location_type !== "WAREHOUSE_QUARANTINE"
    );
    setEmployeeRole(emp?.role ?? null);
    const homeId = emp?.home_store_id ?? null;
    const ordered = homeId
      ? [...sellable.filter((l) => l.id === homeId), ...sellable.filter((l) => l.id !== homeId)]
      : sellable;
    setReceiveLocations(ordered);
    setReceiveLocationId(homeId ?? ordered[0]?.id ?? "");
  }

  async function submit(fn: () => Promise<void>) {
    if (submitGuard.current) return;
    submitGuard.current = true;
    setSaving(true);
    setError(null);
    try {
      await fn();
      setDialog(null);
      onChanged();
    } catch (e: any) {
      setError(e.message ?? "Something went wrong");
    } finally {
      setSaving(false);
      submitGuard.current = false;
    }
  }

  async function submitCancel() {
    setError(null);
    if (!cancelReason.trim()) {
      setError("A reason is required to cancel an exchange");
      return;
    }
    await submit(() => cancelSleepTrialAction(action.action_id, cancelReason));
  }

  async function submitRefund() {
    setError(null);
    const cents = dollarsToCents(refundAmount);
    if (cents == null) {
      setError("Enter a non-negative amount.");
      return;
    }
    if (cents !== owed && !refundReference.trim()) {
      setError(
        "The amount differs from the owed refund — a reference is required to document a different settled amount"
      );
      return;
    }
    await submit(() =>
      recordExchangeRefund(
        action.action_id,
        refundMethod,
        cents,
        refundReference
      )
    );
  }

  async function submitVoid() {
    setError(null);
    if (!voidReason.trim()) {
      setError("A reason is required to void a refund");
      return;
    }
    await submit(() => voidExchangeRefund(action.action_id, voidReason));
  }

  async function submitComplete() {
    setSaving(true);
    setError(null);
    try {
      await completeSleepTrialAction(action.action_id);
      onChanged();
    } catch (e: any) {
      setError(e.message ?? "Something went wrong");
    } finally {
      setSaving(false);
      submitGuard.current = false;
    }
  }

  const blockers = action.complete_blockers ?? [];
  async function submitReceive(createAreaFirst = false) {
    setError(null);
    if (!receiveDate) {
      setError("Pick a received date.");
      return;
    }
    if (!receiveLocationId) {
      setError("Pick a receiving location.");
      return;
    }
    if (createAreaFirst) {
      await submit(async () => {
        await createQuarantineArea(receiveLocationId);
        await receiveReturnedUnit(action.action_id, receiveLocationId, receiveDate);
      });
      return;
    }
    await submit(async () => {
      await receiveReturnedUnit(action.action_id, receiveLocationId, receiveDate);
    });
  }

  async function submitVoidReceipt() {
    setError(null);
    if (!voidReason.trim()) {
      setError("Enter a reason to void this receipt.");
      return;
    }
    await submit(() => voidReturnedReceipt(action.action_id, voidReason));
  }

  const canMarkReceived =
    action.status === "COMMITTED" && !action.original_received_on &&
    callerCan.startExchange;
  const canVoidThisReceipt =
    !!action.original_received_on && callerCan.completeExchange;

  const originalReceivedOpen = blockers.some((b) =>
    b.includes("original mattress")
  );

  return (
    <div className="mt-1.5 rounded-md border border-teal-300 bg-white p-2.5">
      <div className="flex items-center justify-between gap-2">
        <p className="text-xs font-semibold text-teal-800">
          Exchange in progress
          {action.replacement_product_name
            ? ` — ${action.replacement_product_name}`
            : ""}
        </p>
        {action.child_journey_id && (
          <button
            onClick={() =>
              router.push(`/board?journey=${action.child_journey_id}`)
            }
            className="shrink-0 text-xs font-medium text-brand-600 hover:underline"
          >
            View replacement sale
          </button>
        )}
      </div>

      <ul className="mt-1.5 space-y-0.5">
        {MILESTONES.map(({ key, label }) => (
          <MilestoneLine key={key} label={label} m={action.milestones[key]} />
        ))}
      </ul>

      {action.original_received_on && receivedLine && (
        <p className="mt-1 text-xs text-slate-500">{receivedLine}</p>
      )}

      {owed > 0 && !refundRecorded && (
        <p className="mt-1.5 text-xs font-medium text-amber-800">
          Refund owed to customer: {fmt(owed)}. Issue it in your payment
          system, then click Record refund.
        </p>
      )}
      {refundRecorded && (
        <p className="mt-1.5 text-xs font-medium text-green-800">
          Refund recorded: {action.refund_method ?? "—"},{" "}
          {fmt(action.refund_amount_cents)}
          {action.refund_recorded_at
            ? ` on ${activityShortDate(action.refund_recorded_at)}`
            : ""}
          {action.refund_recorded_by_name
            ? ` by ${action.refund_recorded_by_name}`
            : ""}
        </p>
      )}

      {history.length > 0 && (
        <div className="mt-1.5 border-t border-slate-100 pt-1.5">
          <p className="text-[10px] font-semibold uppercase text-slate-400">
            Voided refunds
          </p>
          <ul className="mt-0.5 space-y-0.5">
            {history.map((h, i) => (
              <li key={i} className="text-xs text-slate-500">
                {h.refund_method ?? "—"} {fmt(h.refund_amount_cents)}
                {h.refund_reference ? ` (ref ${h.refund_reference})` : ""}
                {h.recorded_at
                  ? ` recorded ${activityShortDate(h.recorded_at)}`
                  : ""}
                {h.recorded_by_name ? ` by ${h.recorded_by_name}` : ""}
                {" — voided"}
                {h.voided_at ? ` ${activityShortDate(h.voided_at)}` : ""}
                {h.voided_by_name ? ` by ${h.voided_by_name}` : ""}
                {h.void_reason ? `: ${h.void_reason}` : ""}
              </li>
            ))}
          </ul>
        </div>
      )}

      {(action.can_cancel ||
        action.can_record_refund ||
        action.can_void_refund ||
        action.can_complete ||
        canMarkReceived ||
        canVoidThisReceipt) && (
        <div className="mt-2 flex flex-wrap items-start gap-2">
          {action.can_cancel && (
            <button
              onClick={() => open("cancel")}
              className="rounded-md border border-red-200 bg-white px-2 py-1 text-xs font-medium text-red-700 hover:bg-red-50"
            >
              Cancel exchange
            </button>
          )}
          {canMarkReceived && (
            <button
              onClick={() => open("receive")}
              className="rounded-md border border-teal-400 bg-teal-50 px-2 py-1 text-xs font-medium text-teal-800 hover:bg-teal-100"
            >
              Mark original received
            </button>
          )}
          {canVoidThisReceipt && (
            <button
              onClick={() => open("voidReceipt")}
              className="rounded-md border border-slate-300 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
            >
              Void receipt
            </button>
          )}
          {action.can_record_refund && (
            <button
              onClick={() => open("refund")}
              className="rounded-md border border-slate-300 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
            >
              Record refund
            </button>
          )}
          {action.can_void_refund && (
            <button
              onClick={() => open("void")}
              className="rounded-md border border-slate-300 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
            >
              Void refund
            </button>
          )}
          {action.can_complete && (
            <div>
              <button
                onClick={submitComplete}
                disabled={blockers.length > 0 || saving}
                className="rounded-md bg-teal-700 px-2 py-1 text-xs font-medium text-white hover:bg-teal-800 disabled:opacity-50"
              >
                Complete exchange
              </button>
              {blockers.length > 0 && (
                <ul className="mt-1 space-y-0.5">
                  {blockers.map((b) => (
                    <li key={b} className="text-xs text-slate-500">
                      {b}
                    </li>
                  ))}
                  {originalReceivedOpen && (
                    <li className="text-xs text-slate-500">
                      Mark the original mattress received first.</li>
                  )}
                </ul>
              )}
            </div>
          )}
        </div>
      )}
      {error && !dialog && (
        <p className="mt-1.5 text-xs font-medium text-red-700">{error}</p>
      )}

      {dialog === "cancel" && (
        <Modal
          onClose={() => setDialog(null)}
          saving={saving}
          dirty={cancelReason.trim() !== ""}
        >
          <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-xl">
            <h3 className="text-sm font-semibold text-slate-900">
              Cancel exchange
            </h3>
            {action.cancel_block_code === "payment_on_record" ? (
              <>
                <p className="mt-2 text-sm text-slate-700">
                  {PAID_CUSTOMER_MESSAGE}
                </p>
                <div className="mt-4 flex justify-end">
                  <button
                    onClick={() => setDialog(null)}
                    className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
                  >
                    Keep exchange
                  </button>
                </div>
              </>
            ) : action.cancel_block_message ? (
              <>
                <p className="mt-2 text-sm text-slate-700">
                  {action.cancel_block_message}
                </p>
                <div className="mt-4 flex justify-end">
                  <button
                    onClick={() => setDialog(null)}
                    className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
                  >
                    Keep exchange
                  </button>
                </div>
              </>
            ) : (
              <>
                <p className="mt-2 text-sm font-semibold text-slate-900">
                  Cancel this exchange?
                </p>
                <p className="mt-1 text-sm text-slate-700">
                  This puts the original mattress back on the customer&apos;s
                  sleep trial and cancels the replacement order. The
                  approved exception used for this exchange is used up and
                  will NOT come back. If the customer wants another
                  exchange, a new exception is needed.
                </p>
                <label className="mt-3 block text-xs font-medium text-slate-700">
                  Why is it being cancelled? (required)
                </label>
                <textarea
                  value={cancelReason}
                  onChange={(e) => setCancelReason(e.target.value)}
                  rows={3}
                  className="mt-1 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm focus:border-brand-500 focus:outline-none"
                />
                {error && (
                  <p className="mt-1.5 text-xs font-medium text-red-700">
                    {error}
                  </p>
                )}
                <div className="mt-4 flex justify-end gap-2">
                  <button
                    onClick={() => setDialog(null)}
                    className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
                  >
                    Keep exchange
                  </button>
                  <button
                    onClick={submitCancel}
                    disabled={saving}
                    className="rounded-md bg-red-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
                  >
                    {saving ? "Cancelling…" : "Cancel exchange"}
                  </button>
                </div>
              </>
            )}
          </div>
        </Modal>
      )}

      {dialog === "refund" && (
        <Modal onClose={() => setDialog(null)} saving={saving}>
          <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-xl">
            <h3 className="text-sm font-semibold text-slate-900">
              Record refund
            </h3>
            <p className="mt-2 text-sm text-slate-700">
              PillowTop records the refund. Issue it in your payment system
              first.
            </p>
            <p className="mt-1 text-xs text-slate-500">
              Refund owed: {fmt(owed)}
            </p>
            <div className="mt-3 grid grid-cols-2 gap-3">
              <div>
                <label className="block text-xs font-medium text-slate-700">
                  Method
                </label>
                <select
                  value={refundMethod}
                  onChange={(e) =>
                    setRefundMethod(e.target.value as ExchangeRefundMethod)
                  }
                  className="mt-1 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm focus:border-brand-500 focus:outline-none"
                >
                  {REFUND_METHODS.map((m) => (
                    <option key={m.value} value={m.value}>
                      {m.label}
                    </option>
                  ))}
                </select>
              </div>
              <div>
                <label className="block text-xs font-medium text-slate-700">
                  Amount
                </label>
                <input
                  value={refundAmount}
                  onChange={(e) => setRefundAmount(e.target.value)}
                  inputMode="decimal"
                  className="mt-1 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm focus:border-brand-500 focus:outline-none"
                />
              </div>
            </div>
            <label className="mt-3 block text-xs font-medium text-slate-700">
              Reference{" "}
              <span className="font-normal text-slate-500">
                (required if the amount differs from what is owed)
              </span>
            </label>
            <input
              value={refundReference}
              onChange={(e) => setRefundReference(e.target.value)}
              className="mt-1 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm focus:border-brand-500 focus:outline-none"
            />
            {error && (
              <p className="mt-1.5 text-xs font-medium text-red-700">
                {error}
              </p>
            )}
            <div className="mt-4 flex justify-end gap-2">
              <button
                onClick={() => setDialog(null)}
                className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Cancel
              </button>
              <button
                onClick={submitRefund}
                disabled={saving}
                className="rounded-md bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
              >
                {saving ? "Recording…" : "Record refund"}
              </button>
            </div>
          </div>
        </Modal>
      )}

      {dialog === "void" && (
        <Modal
          onClose={() => setDialog(null)}
          saving={saving}
          dirty={voidReason.trim() !== ""}
        >
          <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-xl">
            <h3 className="text-sm font-semibold text-slate-900">
              Void refund
            </h3>
            <p className="mt-2 text-sm text-slate-700">
              Recorded refund: {action.refund_method ?? "—"},{" "}
              {fmt(action.refund_amount_cents)}
              {action.refund_reference
                ? ` (ref ${action.refund_reference})`
                : ""}
              {action.refund_recorded_at
                ? `, recorded ${activityShortDate(action.refund_recorded_at)}`
                : ""}
              {action.refund_recorded_by_name
                ? ` by ${action.refund_recorded_by_name}`
                : ""}
              .
            </p>
            <p className="mt-1.5 text-xs text-slate-500">
              The original record is kept. The exchange goes back to
              &quot;Refund owed&quot; and a new refund can be recorded.
            </p>
            <label className="mt-3 block text-xs font-medium text-slate-700">
              Why is it being voided? (required)
            </label>
            <textarea
              value={voidReason}
              onChange={(e) => setVoidReason(e.target.value)}
              rows={3}
              className="mt-1 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm focus:border-brand-500 focus:outline-none"
            />
            {error && (
              <p className="mt-1.5 text-xs font-medium text-red-700">
                {error}
              </p>
            )}
            <div className="mt-4 flex justify-end gap-2">
              <button
                onClick={() => setDialog(null)}
                className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Keep refund
              </button>
              <button
                onClick={submitVoid}
                disabled={saving}
                className="rounded-md bg-red-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
              >
                {saving ? "Voiding…" : "Void refund"}
              </button>
            </div>
          </div>
        </Modal>
      )}

      {dialog === "receive" && (
        <Modal onClose={() => setDialog(null)} saving={saving}>
          <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            <h2 className="mb-2 text-lg font-semibold text-slate-900">
              Mark original received
            </h2>
            <label className="block text-xs font-medium text-slate-600">
              Received date
            </label>
            <input
              type="date"
              value={receiveDate}
              max={new Date().toISOString().slice(0, 10)}
              min={(action.committed_at ?? action.created_at ?? "").slice(0, 10) || undefined}
              onChange={(e) => {
                setReceiveDate(e.target.value);
                setError(null);
              }}
              className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
            />
            <label className="mt-3 block text-xs font-medium text-slate-600">
              Receiving location
            </label>
            <select
              value={receiveLocationId}
              onChange={(e) => {
                setReceiveLocationId(e.target.value);
                setError(null);
              }}
              className="mt-1 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm"
            >
              {receiveLocations.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.name}
                </option>
              ))}
            </select>
            {error && (
              <p key="receive-error" className="mt-3 text-sm text-red-600">
                {error}
              </p>
            )}
            {error && error.includes("quarantine area") &&
              (employeeRole === "owner" || employeeRole === "admin") && (
              <p key="quarantine-hint" className="mt-1 text-xs text-slate-500">
                Create the quarantine area and retry in one step.
              </p>
            )}
            <div className="mt-4 flex gap-2">
              {error && error.includes("quarantine area") &&
              (employeeRole === "owner" || employeeRole === "admin") ? (
                <button
                  key="create-and-receive"
                  onClick={() => submitReceive(true)}
                  disabled={saving}
                  className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                >
                  {saving ? "Working..." : "Create quarantine area and receive"}
                </button>
              ) : (
                <button
                  key="mark-received"
                  onClick={() => submitReceive(false)}
                  disabled={saving || !receiveLocationId}
                  className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                >
                  {saving ? "Working..." : "Mark received"}
                </button>
              )}
              <button
                onClick={() => setDialog(null)}
                className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Cancel
              </button>
            </div>
          </div>
        </Modal>
      )}

      {dialog === "voidReceipt" && (
        <Modal onClose={() => setDialog(null)} saving={saving}>
          <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            <h2 className="mb-2 text-lg font-semibold text-slate-900">
              Void receipt
            </h2>
            <p className="mb-3 text-sm text-slate-600">
              This reverses the received unit out of quarantine and clears
              the received date. Only do this if the receipt was recorded in
              error.
            </p>
            <textarea
              value={voidReason}
              onChange={(e) => {
                setVoidReason(e.target.value);
                setError(null);
              }}
              placeholder="Reason (required)"
              className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
              rows={3}
            />
            {error && (
              <p key="voidreceipt-error" className="mt-3 text-sm text-red-600">
                {error}
              </p>
            )}
            <div className="mt-4 flex gap-2">
              <button
                onClick={submitVoidReceipt}
                disabled={saving}
                className="flex-1 rounded-md bg-red-600 px-3 py-2 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
              >
                {saving ? "Working..." : "Void receipt"}
              </button>
              <button
                onClick={() => setDialog(null)}
                className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Cancel
              </button>
            </div>
          </div>
        </Modal>
      )}
    </div>
  );
}
