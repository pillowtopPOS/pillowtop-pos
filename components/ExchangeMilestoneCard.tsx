"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import Modal from "@/components/Modal";
import { activityShortDate } from "@/lib/journeys/activityLabels";
import {
  actionCompleteBlockers,
  actionMilestoneKeys,
  refundIsFinalBlocker,
  REFUND_COMPLETE_BLOCKER,
  cancelSleepTrialAction,
  completeSleepTrialAction,
  centsToDollars,
  dollarsToCents,
  recordExchangeRefund,
  receiveReturnedUnit,
  recordOriginalHandover,
  voidOriginalHandover,
  originalPickupCustodyLine,
  cancelWarningFor,
  reopenSleepTrialAction,
  voidExchangeRefund,
  voidReturnedReceipt,
  type ExchangeActionRead,
  type OriginalPickupOutcome,
  type ExchangeMilestone,
  type ExchangeMilestones,
  type ExchangeRefundMethod,
} from "@/lib/journeys/exchange";
import {
  fetchJourneyEvents,
  fetchStores,
  type JourneyEvent,
  type Store,
} from "@/lib/journeys/queries";
import {
  pickRefundPayment,
  refundablePaymentEvents,
} from "@/lib/journeys/paid";
import {
  actionRefundBlockReason,
  refundLinkedLine,
} from "@/lib/journeys/returns";
import RecordRefundModal from "@/components/RecordRefundModal";
import { createClient } from "@/lib/supabase/client";

// EB-3b: the milestone card on the original journey's Sleep Trial section.
// Every flag (can_cancel, can_record_refund, can_void_refund,
// can_complete) and every blocker is computed server-side by
// get_exchange_action (091) — nothing is recomputed here.

const MILESTONE_LABELS: Record<keyof ExchangeMilestones, string> = {
  replacement_reserved: "Replacement reserved",
  replacement_delivered: "Replacement delivered",
  original_received: "Original received",
  money_settled: "Money settled",
  completed: "Completed",
};

const REFUND_METHODS: { value: ExchangeRefundMethod; label: string }[] = [
  { value: "card", label: "Card" },
  { value: "cash", label: "Cash" },
  { value: "check", label: "Check" },
  { value: "store_credit", label: "Store credit" },
  { value: "none", label: "None" },
];

function localDateString(d = new Date()): string {
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const day = String(d.getDate()).padStart(2, "0");
  return `${y}-${m}-${day}`;
}

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
  productName,
  onChanged,
}: {
  action: ExchangeActionRead;
  // Original item's product name for the refund dialog's linked line.
  productName?: string | null;
  onChanged: () => void | Promise<void>;
}) {
  const router = useRouter();
  const [dialog, setDialog] = useState<
    | "cancel"
    | "refund"
    | "void"
    | "receive"
    | "voidReceipt"
    | "reopen"
    | "pickup"
    | "voidPickup"
    | null
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
  const [reopenReason, setReopenReason] = useState("");
  // 165: old-mattress custody dialog state
  const [pickupOutcome, setPickupOutcome] =
    useState<OriginalPickupOutcome | null>(null);
  const [pickupReason, setPickupReason] = useState("");
  const [pickupLocationId, setPickupLocationId] = useState("");
  const [pickupLocations, setPickupLocations] = useState<Store[]>([]);
  const [callerEmployeeId, setCallerEmployeeId] = useState<string | null>(
    null
  );
  // EB-4a: receive + void-receipt state
  const [receiveDate, setReceiveDate] = useState("");
  const [receiveLocationId, setReceiveLocationId] = useState("");
  const [receiveLocations, setReceiveLocations] = useState<Store[]>([]);
  const [callerCan, setCallerCan] = useState({
    startExchange: false,
    completeExchange: false,
    recordRefund: false,
    adjustRefund: false,
    inspectReturns: false,
    markFulfilled: false,
    canFinalizeDelivery: false,
  });
  const [receivedLine, setReceivedLine] = useState<string | null>(null);
  const [callerIsWarehouseBased, setCallerIsWarehouseBased] =
    useState(false);
  const [callerStoreId, setCallerStoreId] = useState<string | null>(null);
  const [locationsReady, setLocationsReady] = useState(false);
  const [loadFailed, setLoadFailed] = useState(false);
  // RETURN only: the shared refund dialog needs the journey's payments.
  const [refundRead, setRefundRead] = useState<
    "idle" | "loading" | "ready" | "failed"
  >("idle");
  const [refundData, setRefundData] = useState<{
    events: JourneyEvent[];
    payments: JourneyEvent[];
    initialPaymentId: string | null;
  } | null>(null);

  const isReturn = action.action === "RETURN";
  const noun = isReturn ? "return" : "exchange";

  useEffect(() => {
    // Server enforces regardless; this only decides whether the buttons
    // render at all.
    const supabase = createClient();
    Promise.all([
      supabase.rpc("has_permission", { p_key: "sleep_trial.start_exchange" }),
      supabase.rpc("has_permission", { p_key: "sleep_trial.complete_exchange" }),
      supabase.rpc("has_permission", { p_key: "payments.record_refund" }),
      supabase.rpc("has_permission", { p_key: "payments.adjust_refund_amount" }),
      supabase.rpc("has_permission", { p_key: "inventory.inspect_returns" }),
      supabase.rpc("has_permission", { p_key: "orders.mark_fulfilled" }),
      supabase.rpc("can_finalize_delivery"),
    ]).then(([a, b, c, d, e, f, g]) =>
      setCallerCan((prev) => ({
        ...prev,
        startExchange: !!a.data,
        completeExchange: !!b.data,
        recordRefund: !!c.data,
        adjustRefund: !!d.data,
        inspectReturns: !!e.data,
        markFulfilled: !!f.data,
        canFinalizeDelivery: !!g.data,
      }))
    );
    // Warehouse-based employees may receive without the inspect_returns
    // key (server rule), so the button must not hide from them either.
    supabase.auth.getUser().then(({ data: u }) => {
      if (!u.user) return;
      supabase
        .from("employees")
        .select("id, home_store_id, role, stores(location_type)")
        .eq("auth_user_id", u.user.id)
        .eq("is_active", true)
        .maybeSingle()
        .then(({ data: emp }) => {
          const t = (emp as any)?.stores?.location_type;
          setCallerIsWarehouseBased(t === "WAREHOUSE");
          setCallerStoreId((emp as any)?.home_store_id ?? null);
          setCallerEmployeeId((emp as any)?.id ?? null);
        });
    });
  }, []);

  useEffect(() => {
    if (dialog !== "receive") return;
    let cancelled = false;
    setError(null);
    (async () => {
      try {
        const stores = await fetchStores(true);
        const warehouses = stores.filter(
          (l) => l.location_type === "WAREHOUSE"
        );
        // A quarantine child row marks the warehouse that already has an
        // area; default the picker to it.
        const quarantineParentIds = new Set(
          stores
            .filter((l) => l.location_type === "WAREHOUSE_QUARANTINE")
            .map((l) => (l as Store & { parent_location_id?: string }).parent_location_id)
        );
        const withArea = warehouses.filter((l) =>
          quarantineParentIds.has(l.id)
        );
        const ordered =
          withArea.length > 0
            ? [...withArea, ...warehouses.filter((l) => !quarantineParentIds.has(l.id))]
            : warehouses;
        // Default to the real main warehouse: the caller's store's
        // assigned warehouse when it is listed, else the oldest
        // warehouse by created_at (test-named rows sort first by name).
        const callerWarehouseId = stores.find(
          (s) => s.id === callerStoreId
        )?.assigned_warehouse_id;
        const preferred =
          (callerWarehouseId &&
            ordered.find((l) => l.id === callerWarehouseId)) ||
          [...ordered].sort((a, b) =>
            (a.created_at ?? "").localeCompare(b.created_at ?? "")
          )[0];
        if (cancelled) return;
        setReceiveLocations(ordered);
        setReceiveLocationId((cur) =>
          cur && ordered.some((l) => l.id === cur)
            ? cur
            : preferred?.id ?? ""
        );
        setLocationsReady(true);
      } catch {
        if (!cancelled) {
          setLoadFailed(true);
          setError("Could not load locations. Close this window and try again.");
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [dialog, callerStoreId]);

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

  function open(
    which:
      | "cancel"
      | "refund"
      | "void"
      | "receive"
      | "voidReceipt"
      | "reopen"
      | "pickup"
      | "voidPickup"
  ) {
    setError(null);
    if (which === "refund") {
      if (isReturn) {
        // Returns refund through record_payment_refund (161): fetch the
        // journey's payments so the shared dialog can offer a picker.
        setRefundRead("loading");
        setRefundData(null);
        fetchJourneyEvents(action.journey_id)
          .then((evs) => {
            const payments = refundablePaymentEvents(evs);
            const pick = pickRefundPayment(payments, evs, owed);
            setRefundData({
              events: evs,
              payments,
              initialPaymentId: pick.payment?.id ?? null,
            });
            setRefundRead("ready");
          })
          .catch(() => setRefundRead("failed"));
      } else {
        setRefundMethod("card");
        setRefundAmount(centsToDollars(owed));
        setRefundReference("");
      }
    }
    if (which === "cancel") setCancelReason("");
    if (which === "void") setVoidReason("");
    if (which === "receive") {
      setReceiveDate(localDateString());
      setLocationsReady(false);
      setLoadFailed(false);
    }
    if (which === "voidReceipt") setVoidReason("");
    if (which === "reopen") setReopenReason("");
    if (which === "pickup") {
      setPickupOutcome(
        (action.original_pickup_outcome as OriginalPickupOutcome) ?? null
      );
      setPickupReason(action.original_pickup_reason ?? "");
      setPickupLocationId(
        action.original_pickup_location_id ?? callerStoreId ?? ""
      );
      // The handover picker lists every company location - handovers
      // are not limited to warehouses.
      fetchStores(true)
        .then((all) => setPickupLocations(all.filter((l) => l.is_active)))
        .catch(() => setPickupLocations([]));
    }
    if (which === "voidPickup") setPickupReason("");
    setDialog(which);
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
      setError(`A reason is required to cancel a ${noun}`);
      return;
    }
    await submit(() => cancelSleepTrialAction(action.action_id, cancelReason));
  }

  async function submitPickup() {
    setError(null);
    if (!pickupOutcome) {
      setError("Choose what happened to the old mattress.");
      return;
    }
    if (
      (pickupOutcome === "NOT_PICKED_UP" ||
        pickupOutcome === "NOT_HANDED_OVER") &&
      !pickupReason.trim()
    ) {
      setError("A reason is required.");
      return;
    }
    const handoverLoc =
      pickupOutcome === "HANDED_OVER" ? pickupLocationId || null : null;
    if (pickupOutcome === "HANDED_OVER" && !handoverLoc) {
      setError("Choose where the mattress was handed over.");
      return;
    }
    // A handover at a location with a quarantine area is received in
    // the same step when the caller may receive - nobody presses a
    // second button. A failed receive keeps the handover; the error
    // says exactly where to finish it.
    await submit(async () => {
      await recordOriginalHandover(
        action.action_id,
        pickupOutcome,
        handoverLoc,
        pickupReason.trim() || null
      );
      if (
        pickupOutcome === "HANDED_OVER" &&
        handoverLoc &&
        (callerCan.inspectReturns || callerIsWarehouseBased) &&
        pickupLocations.some(
          (l) =>
            l.location_type === "WAREHOUSE_QUARANTINE" &&
            (l as Store & { parent_location_id?: string })
              .parent_location_id === handoverLoc
        )
      ) {
        try {
          await receiveReturnedUnit(
            action.action_id,
            handoverLoc,
            localDateString()
          );
        } catch {
          throw new Error(
            "Handed over, but not marked received. Mark it received from this card."
          );
        }
      }
    });
  }

  async function submitVoidPickup() {
    setError(null);
    if (!pickupReason.trim()) {
      setError("A reason is required to undo the pickup record.");
      return;
    }
    await submit(() =>
      voidOriginalHandover(action.action_id, pickupReason.trim())
    );
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

  const blockers = actionCompleteBlockers(
    action.complete_blockers,
    action.action
  );
  async function submitReceive() {
    setError(null);
    if (!receiveDate) {
      setError("Pick a received date.");
      return;
    }
    if (!receiveLocationId) {
      setError("Pick a receiving location.");
      return;
    }
    await submit(async () => {
      await receiveReturnedUnit(action.action_id, receiveLocationId, receiveDate);
    });
  }

  async function submitReopen() {
    setError(null);
    if (!reopenReason.trim()) {
      setError(`A reason is required to reopen a completed ${noun}`);
      return;
    }
    // Refresh before closing so the card never shows the pre-reopen
    // state (same pattern as the refund dialog).
    await submit(async () => {
      await reopenSleepTrialAction(action.action_id, reopenReason.trim());
      await onChanged();
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

  // 162: receiving is the gate that unlocks the refund, so the button
  // shows only to warehouse staff and inventory.inspect_returns holders.
  const canMarkReceived =
    action.status === "COMMITTED" && !action.original_received_on &&
    (callerCan.inspectReturns || callerIsWarehouseBased);
  // 164: voiding a receipt uses the same rule as receiving it (the
  // forward step must always be undoable by the same person), and the
  // server only accepts it while the action is still COMMITTED.
  const canVoidThisReceipt =
    action.status === "COMMITTED" &&
    !!action.original_received_on &&
    (callerCan.inspectReturns || callerIsWarehouseBased);
  // 165: recording the custody answer needs the fulfillment gate
  // (orders.mark_fulfilled or can_finalize_delivery); undoing it needs
  // a manager or the recorder, the same rule the server applies.
  const canRecordPickup =
    action.status === "COMMITTED" &&
    !action.original_received_on &&
    (callerCan.markFulfilled || callerCan.canFinalizeDelivery);
  const canVoidPickup =
    action.status === "COMMITTED" &&
    !action.original_received_on &&
    action.original_pickup_outcome != null &&
    (callerCan.completeExchange ||
      (callerEmployeeId != null &&
        action.original_pickup_by === callerEmployeeId));
  const refundBlockReason = actionRefundBlockReason(action);
  // The refund completes the action only when it is the last open
  // blocker; any other open blocker is what still has to happen after
  // the refund is recorded.
  const refundIsFinal = refundIsFinalBlocker(
    action.complete_blockers,
    action.action
  );
  const refundStillNeeded = blockers.filter(
    (b) => b !== REFUND_COMPLETE_BLOCKER
  );

  return (
    <div className="mt-1.5 rounded-md border border-teal-300 bg-white p-2.5">
      <div className="flex items-center justify-between gap-2">
        <p className="text-xs font-semibold text-teal-800">
          {action.status === "COMPLETED"
            ? isReturn
              ? "Return completed"
              : "Exchange completed"
            : isReturn
              ? "Return in progress"
              : "Exchange in progress"}
          {!isReturn && action.replacement_product_name
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
        {actionMilestoneKeys(action.action).map((key) => (
          <MilestoneLine
            key={key}
            label={MILESTONE_LABELS[key]}
            m={action.milestones[key]}
          />
        ))}
      </ul>

      {action.original_received_on && receivedLine && (
        <p className="mt-1 text-xs text-slate-500">{receivedLine}</p>
      )}

      {/* 165: where the old mattress is, while it is still out. */}
      {action.status === "COMMITTED" && !action.original_received_on && (
        <p className="mt-1 text-xs text-slate-600">
          Old mattress:{" "}
          {originalPickupCustodyLine(action) ?? "not yet picked up"}
        </p>
      )}

      {action.status === "COMMITTED" && (
        <p className="mt-1 text-xs text-slate-500">
          {isReturn
            ? "Completes automatically when the mattress is received and the refund is recorded."
            : "Completes automatically when the mattress is received, the replacement is delivered and any refund is recorded."}
        </p>
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
        action.can_reopen ||
        canMarkReceived ||
        canVoidThisReceipt ||
        canRecordPickup ||
        canVoidPickup) && (
        <div className="mt-2 flex flex-wrap items-start gap-2">
          {action.can_cancel && !action.original_received_on && (
            <button
              onClick={() => open("cancel")}
              className="rounded-md border border-red-200 bg-white px-2 py-1 text-xs font-medium text-red-700 hover:bg-red-50"
            >
              {isReturn ? "Cancel return" : "Cancel exchange"}
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
          {action.status === "COMMITTED" &&
            !action.original_received_on &&
            !canMarkReceived && (
              <p className="self-center text-xs text-slate-500">
                The warehouse marks the original received.
              </p>
            )}
          {canVoidThisReceipt && (
            <button
              onClick={() => open("voidReceipt")}
              className="rounded-md border border-slate-300 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
            >
              Void receipt
            </button>
          )}
          {((!isReturn && action.can_record_refund) ||
            (isReturn &&
              callerCan.recordRefund &&
              action.status === "COMMITTED" &&
              owed > 0 &&
              !refundRecorded)) && (
            <div>
              <button
                onClick={() => open("refund")}
                disabled={
                  saving ||
                  refundRead === "loading" ||
                  refundBlockReason !== null
                }
                className="rounded-md border border-slate-300 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:cursor-not-allowed disabled:border-slate-200 disabled:bg-slate-100 disabled:text-slate-400"
              >
                Record refund
              </button>
              {refundBlockReason && (
                <p className="mt-1 text-xs text-slate-500">
                  {refundBlockReason}
                </p>
              )}
            </div>
          )}
          {/* 164: a COMPLETED action's correction is the Reopen button
              (the void and the reopen are the same path), so the plain
              Void refund button stays COMMITTED-only. */}
          {!isReturn &&
            action.can_void_refund &&
            action.status !== "COMPLETED" && (
            <button
              onClick={() => open("void")}
              className="rounded-md border border-slate-300 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
            >
              Void refund
            </button>
          )}
          {canRecordPickup && (
            <button
              onClick={() => open("pickup")}
              className="rounded-md border border-slate-300 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
            >
              Record old mattress pickup
            </button>
          )}
          {canVoidPickup && (
            <button
              onClick={() => open("voidPickup")}
              className="rounded-md border border-slate-300 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
            >
              Undo pickup
            </button>
          )}
          {action.status === "COMPLETED" && action.can_reopen && (
            <button
              onClick={() => open("reopen")}
              className="rounded-md border border-amber-300 bg-amber-50 px-2 py-1 text-xs font-medium text-amber-800 hover:bg-amber-100"
            >
              Reopen
            </button>
          )}
          {action.can_complete &&
            action.status === "COMMITTED" &&
            blockers.length === 0 && (
              <div>
                <button
                  onClick={submitComplete}
                  disabled={saving}
                  className="rounded-md bg-teal-700 px-2 py-1 text-xs font-medium text-white hover:bg-teal-800 disabled:opacity-50"
                >
                  {isReturn ? "Complete return" : "Complete exchange"}
                </button>
              </div>
            )}
        </div>
      )}
      {/* 164: when the unit already left quarantine the server refuses
          the reopen - the plain-language reason shows in place of the
          button so the card explains itself. */}
      {action.status === "COMPLETED" &&
        !action.can_reopen &&
        action.reopen_block_reason && (
          <p className="mt-1.5 text-xs text-slate-500">
            {action.reopen_block_reason}
          </p>
        )}

      {error && !dialog && (
        <p className="mt-1.5 text-xs font-medium text-red-700">{error}</p>
      )}

      {dialog === "reopen" && (
        <Modal
          onClose={() => setDialog(null)}
          saving={saving}
          dirty={reopenReason.trim() !== ""}
        >
          <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-xl">
            <h3 className="text-sm font-semibold text-slate-900">
              {isReturn ? "Reopen completed return" : "Reopen completed exchange"}
            </h3>
            <p className="mt-2 text-sm text-slate-700">
              {refundRecorded
                ? "Reopening voids the recorded refund and holds that amount again. The returned mattress stays received. You can then record the correct refund."
                : `Reopening puts this ${noun} back in progress so its remaining steps can be corrected.`}
            </p>
            {!isReturn && (
              <p className="mt-1.5 text-xs text-slate-500">
                The replacement order is not changed and the exchange
                cannot be cancelled after the original was received.
              </p>
            )}
            <label className="mt-3 block text-xs font-medium text-slate-700">
              Why is it being reopened? (required)
            </label>
            <textarea
              value={reopenReason}
              onChange={(e) => setReopenReason(e.target.value)}
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
                Keep completed
              </button>
              <button
                onClick={submitReopen}
                disabled={saving}
                className="rounded-md bg-amber-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-amber-700 disabled:opacity-50"
              >
                {saving ? "Reopening…" : "Reopen"}
              </button>
            </div>
          </div>
        </Modal>
      )}

      {dialog === "cancel" && (
        <Modal
          onClose={() => setDialog(null)}
          saving={saving}
          dirty={cancelReason.trim() !== ""}
        >
          <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-xl">
            <h3 className="text-sm font-semibold text-slate-900">
              {isReturn ? "Cancel return" : "Cancel exchange"}
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
                    Keep {noun}
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
                    Keep {noun}
                  </button>
                </div>
              </>
            ) : (
              <>
                <p className="mt-2 text-sm font-semibold text-slate-900">
                  Cancel this {noun}?
                </p>
                <p className="mt-1 text-sm text-slate-700">
                  This puts the original mattress back on the customer&apos;s
                  sleep trial{isReturn ? "." : " and cancels the replacement order."}{" "}
                  {!isReturn &&
                    "The approved exception used for this exchange is used up and will NOT come back. If the customer wants another exchange, a new exception is needed."}
                </p>
                {cancelWarningFor(action) && (
                  <p className="mt-2 rounded-md border border-amber-200 bg-amber-50 px-2 py-1.5 text-xs font-medium text-amber-800">
                    {cancelWarningFor(action)}
                  </p>
                )}
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
                    Keep {noun}
                  </button>
                  <button
                    onClick={submitCancel}
                    disabled={saving}
                    className="rounded-md bg-red-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
                  >
                    {saving
                      ? "Cancelling…"
                      : isReturn
                        ? "Cancel return"
                        : "Cancel exchange"}
                  </button>
                </div>
              </>
            )}
          </div>
        </Modal>
      )}

      {dialog === "refund" && isReturn && (
        <>
          {refundRead === "loading" && (
            <Modal onClose={() => setDialog(null)}>
              <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-xl">
                <p className="text-sm text-slate-600">Loading payments...</p>
              </div>
            </Modal>
          )}
          {refundRead === "failed" && (
            <Modal onClose={() => setDialog(null)}>
              <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-xl">
                <h3 className="text-sm font-semibold text-slate-900">
                  Record refund
                </h3>
                <p className="mt-2 text-sm text-red-700">
                  Could not load the order's payments. Try again.
                </p>
                <div className="mt-4 flex justify-end">
                  <button
                    onClick={() => setDialog(null)}
                    className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
                  >
                    Close
                  </button>
                </div>
              </div>
            </Modal>
          )}
          {refundRead === "ready" &&
            refundData &&
            (refundData.payments.length === 0 ? (
              <Modal onClose={() => setDialog(null)}>
                <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-xl">
                  <h3 className="text-sm font-semibold text-slate-900">
                    Record refund
                  </h3>
                  <p className="mt-2 text-sm text-slate-700">
                    No refundable payment was found on this order.
                  </p>
                  <div className="mt-4 flex justify-end">
                    <button
                      onClick={() => setDialog(null)}
                      className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
                    >
                      Close
                    </button>
                  </div>
                </div>
              </Modal>
            ) : (
              <RecordRefundModal
                payments={refundData.payments}
                events={refundData.events}
                defaultAmountCents={owed}
                initialPaymentId={refundData.initialPaymentId ?? undefined}
                actionId={action.action_id}
                returnProductName={productName}
                lockedAmountCents={
                  callerCan.adjustRefund ? null : owed
                }
                completesAction={
                  refundIsFinal ? (isReturn ? "RETURN" : "EXCHANGE") : null
                }
                onClose={() => setDialog(null)}
                onRecorded={async () => {
                  await onChanged();
                  setDialog(null);
                }}
              />
            ))}
        </>
      )}
      {dialog === "refund" && !isReturn && (
        <Modal onClose={() => setDialog(null)} saving={saving}>
          <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-xl">
            <h3 className="text-sm font-semibold text-slate-900">
              Record refund
            </h3>
            <p className="mt-2 text-sm text-slate-700">
              PillowTop records the refund. Issue it in your payment system
              first.
            </p>
            <p className="mt-2 rounded-md border border-violet-200 bg-violet-50 px-2.5 py-1.5 text-xs text-violet-800">
              {refundLinkedLine("EXCHANGE", productName)}
            </p>
            {refundIsFinal ? (
              <p className="mt-2 text-sm font-semibold text-slate-900">
                Recording this refund completes the exchange.
              </p>
            ) : (
              refundStillNeeded.length > 0 && (
                <div className="mt-2 text-xs text-slate-500">
                  <p>Still needed before the exchange completes:</p>
                  <ul className="mt-0.5 list-disc pl-4">
                    {refundStillNeeded.map((b) => (
                      <li key={b}>{b}</li>
                    ))}
                  </ul>
                </div>
              )
            )}
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
                  readOnly={!callerCan.adjustRefund}
                  onChange={(e) => setRefundAmount(e.target.value)}
                  inputMode="decimal"
                  className="mt-1 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm focus:border-brand-500 focus:outline-none read-only:bg-slate-50 read-only:text-slate-600"
                />
                {!callerCan.adjustRefund && (
                  <span className="mt-1 block text-[11px] text-slate-500">
                    The system sets this amount. A manager can change it.
                  </span>
                )}
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

      {dialog === "pickup" && (
        <Modal onClose={() => setDialog(null)} saving={saving}>
          <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            <h2 className="mb-2 text-lg font-semibold text-slate-900">
              Record old mattress pickup
            </h2>
            <p className="mb-3 text-xs text-slate-500">
              Recording a new answer replaces the old one. The previous
              answer is kept in the history.
            </p>
            <div className="space-y-1.5">
              {(
                [
                  ["PICKED_UP", "Picked up by the driver"],
                  ["HANDED_OVER", "Handed over at a location"],
                  ["NOT_PICKED_UP", "Not picked up"],
                  ["NOT_HANDED_OVER", "Not handed over"],
                ] as [OriginalPickupOutcome, string][]
              ).map(([value, label]) => (
                <label
                  key={value}
                  className="flex items-center gap-2 text-sm text-slate-700"
                >
                  <input
                    type="radio"
                    name="pickup-outcome"
                    checked={pickupOutcome === value}
                    onChange={() => {
                      setPickupOutcome(value);
                      setError(null);
                    }}
                  />
                  {label}
                </label>
              ))}
            </div>
            {pickupOutcome === "HANDED_OVER" && (
              <select
                value={pickupLocationId}
                onChange={(e) => {
                  setPickupLocationId(e.target.value);
                  setError(null);
                }}
                className="mt-2 w-full rounded-md border border-slate-300 bg-white px-2 py-1.5 text-sm text-slate-700"
              >
                {pickupLocations.map((l) => (
                  <option key={l.id} value={l.id}>
                    {l.name}
                  </option>
                ))}
              </select>
            )}
            {(pickupOutcome === "NOT_PICKED_UP" ||
              pickupOutcome === "NOT_HANDED_OVER") && (
              <input
                type="text"
                value={pickupReason}
                onChange={(e) => {
                  setPickupReason(e.target.value);
                  setError(null);
                }}
                placeholder="Why? (required)"
                className="mt-2 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm text-slate-700"
              />
            )}
            {error && (
              <p className="mt-2 text-xs font-medium text-red-700">
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
                onClick={submitPickup}
                disabled={saving}
                className="rounded-md bg-slate-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-slate-800 disabled:opacity-50"
              >
                {saving ? "Saving..." : "Save"}
              </button>
            </div>
          </div>
        </Modal>
      )}

      {dialog === "voidPickup" && (
        <Modal onClose={() => setDialog(null)} saving={saving}>
          <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            <h2 className="mb-2 text-lg font-semibold text-slate-900">
              Undo pickup record
            </h2>
            <p className="mb-3 text-xs text-slate-500">
              This clears the recorded answer back to not-yet. The old
              answer stays in the history.
            </p>
            <label className="block text-xs font-medium text-slate-700">
              Why is it being undone? (required)
            </label>
            <textarea
              value={pickupReason}
              onChange={(e) => {
                setPickupReason(e.target.value);
                setError(null);
              }}
              rows={3}
              className="mt-1 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm"
            />
            {error && (
              <p className="mt-2 text-xs font-medium text-red-700">
                {error}
              </p>
            )}
            <div className="mt-4 flex justify-end gap-2">
              <button
                onClick={() => setDialog(null)}
                className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Keep it
              </button>
              <button
                onClick={submitVoidPickup}
                disabled={saving}
                className="rounded-md bg-red-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
              >
                {saving ? "Saving..." : "Undo record"}
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
            {(action.original_pickup_outcome === "PICKED_UP" ||
              action.original_pickup_outcome === "HANDED_OVER") &&
              originalPickupCustodyLine(action) && (
                <p className="mb-2 text-xs text-slate-500">
                  {action.original_pickup_outcome === "PICKED_UP"
                    ? `The driver picked it up${
                        action.original_pickup_on
                          ? ` ${new Date(
                              `${action.original_pickup_on}T00:00:00`
                            ).toLocaleDateString(undefined, {
                              month: "short",
                              day: "numeric",
                            })}`
                          : ""
                      }.`
                    : originalPickupCustodyLine(action)}
                </p>
              )}
            {error && (
              <p key="receive-error" className="mt-3 text-sm text-red-600">
                {error}
              </p>
            )}
            {!locationsReady && !loadFailed && (
              <p key="receive-loading" className="text-sm text-slate-500">
                Loading locations...
              </p>
            )}
            {loadFailed && (
              <div key="receive-failed" className="mt-4 flex gap-2">
                <button
                  onClick={() => setDialog(null)}
                  className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                >
                  Cancel
                </button>
              </div>
            )}
            {locationsReady && (
              <div key="receive-body">
                <label className="block text-xs font-medium text-slate-600">
                  Received date
                </label>
                <input
                  type="date"
                  value={receiveDate}
                  max={localDateString()}
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
                <p
                  key="receive-no-warehouse"
                  hidden={receiveLocations.length !== 0}
                  className="mt-1 text-sm text-amber-800"
                >
                  No warehouse with a quarantine area was found. Ask an
                  owner or admin.
                </p>
                <select
                  key="receive-loc-select"
                  value={receiveLocationId}
                  disabled={receiveLocations.length <= 1}
                  onChange={(e) => {
                    setReceiveLocationId(e.target.value);
                    setError(null);
                  }}
                  className="mt-1 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm disabled:bg-slate-50 disabled:text-slate-600"
                >
                  {receiveLocations.map((l) => (
                    <option key={l.id} value={l.id}>
                      {l.name}
                    </option>
                  ))}
                </select>
                <div className="mt-4 flex gap-2">
                  <button
                    key="mark-received"
                    onClick={submitReceive}
                    disabled={saving || !receiveLocationId}
                    className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                  >
                    {saving ? "Working..." : "Mark received"}
                  </button>
                  <button
                    onClick={() => setDialog(null)}
                    className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                  >
                    Cancel
                  </button>
                </div>
              </div>
            )}
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
