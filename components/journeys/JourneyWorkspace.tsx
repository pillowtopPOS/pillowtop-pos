"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { Check, MoreHorizontal, Trash2, Truck, X, Copy,
} from "lucide-react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import {
  resolveLineItemLocation,
  lineItemFulfillmentPayload,
  pickupCollectionLabel,
} from "@/lib/journeys/fulfillment";
import { formatPhone } from "@/lib/format/phone";
import {
  getExchangeAction,
  getJourneyExchangeActions,
  type ExchangeActionRead,
  type ExchangeParentLink,
} from "@/lib/journeys/exchange";
import {
  fetchProductAvailabilityByLocation,
  fetchProductStock,
  hasPermission,
  type LocationAvailability,
} from "@/lib/inventory/queries";
import { fetchInTransitArrivals } from "@/lib/transfers/queries";
import {
  completeFollowUp,
  createJourneyLineItem,
  deleteJourneyLineItem,
  fetchJourneyLineItems,
  reconcilePayment,
  reassignJourneyEmployee,
  reassignJourneyStore,
  updateJourneyFulfillment,
  updateJourneyLineItem,
  canFinalizeDelivery,
  fetchJourneyLiveTrialStatuses,
  fetchJourneyFulfillmentSummary,
  totalUnits,
  type JourneyFulfillmentSummary,
  FOLLOW_UP_METHOD_LABELS,
  FOLLOW_UP_TYPE_LABELS,
  type Employee,
  type FollowUp,
  type JourneyEvent,
  type JourneyLineItem,
  type JourneyReassignmentEvent,
  type JourneyWithDetails,
  type PaymentOutcome,
  type Store,
} from "@/lib/journeys/queries";
import {
  fetchCustomerContacts,
  type CustomerContact,
} from "@/lib/journeys/interactions";
import {
  effectiveShipTo,
  formatShipToLine,
} from "@/lib/customers/shipTo";
import {
  addCustomerAddress,
  setJourneyShipTo,
  getCustomer,
  updateCustomer,
  type CustomerAddress,
} from "@/lib/customers/api";
import {
  STATE_TRANSITIONS,
  getStateIndex,
  transitionAppliesToFulfillment,
  type JourneyEventType,
} from "@/lib/journeys/state";
import { computeNetPaid } from "@/lib/journeys/paid";
import {
  completionButtonDecision,
  completionClosesOrder,
  completionDestination as completionDestinationFor,
  effectiveLineFulfillment,
  type CompletionButtonDecision,
} from "@/lib/journeys/completion";
import {
  mostUrgentEvaluation,
  type SleepTrialEvaluation,
} from "@/lib/journeys/sleepTrial";
import Modal from "@/components/Modal";
import ConfirmModal from "@/components/ConfirmModal";
import ProductPicker, { type ProductSelection } from "@/components/ProductPicker";
import JourneyActivity from "@/components/JourneyActivity";
import {
  activityEventDetail,
  activityEventTitle,
} from "@/lib/journeys/activityLabels";
import SleepTrialSection from "@/components/SleepTrialSection";
import JourneyDelivery from "@/components/delivery/JourneyDelivery";

// The inventory-ready flag is a one-time notification marker, not a live
// status. It only surfaces while the journey is Ready to Schedule — a
// journey that dropped back to Waiting for Inventory has items that
// aren't ready, so the banner would be a false positive there, and in
// any later state the flag is history, not status.
const INVENTORY_READY_STATES = new Set(["Ready to Schedule"]);

// A scheduled follow-up is a real next step even when it has no notes —
// the detail card shows notes when present and falls back to the type
// label ("Quote follow-up", "Follow-up", …).
function followUpLabel(f: FollowUp): string {
  const notes = f.notes?.trim();
  if (notes) return notes;
  const type = FOLLOW_UP_TYPE_LABELS[f.type] ?? "Follow-up";
  return f.type === "interaction" ? type : `${type} follow-up`;
}

// Short date used across the workspace: "Nov 30", with the year only
// when it isn't the current one. Accepts date-only strings AND full
// timestamps — date-only values parse as local midnight so the day
// can't slip back a timezone, timestamps parse with their own offset.
function shortDate(iso: string): string {
  const d = iso.includes("T") ? new Date(iso) : new Date(`${iso}T00:00:00`);
  return d.toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
    ...(d.getFullYear() === new Date().getFullYear() ? {} : { year: "numeric" }),
  });
}

function formatHistoryEntry(e: JourneyEvent) {
  // Shares the Journey Activity wording map so the reconcile block can
  // never show a raw event name or contradict the feed's title.
  return {
    title: activityEventTitle(e),
    detail: activityEventDetail(e),
  };
}

type MenuItem = {
  label: string;
  danger?: boolean;
  disabled?: boolean;
  onSelect: () => void;
};

// "..." overflow menu in the workspace header. Rarely used / destructive
// actions live here so the default view stays calm.
function HeaderMenu({ items }: { items: MenuItem[] }) {
  const [open, setOpen] = useState(false);
  const menuRef = useRef<HTMLDivElement>(null);
  const buttonRef = useRef<HTMLButtonElement>(null);

  function close(returnFocus = true) {
    setOpen(false);
    if (returnFocus) buttonRef.current?.focus();
  }

  // On open, move focus into the menu so arrow keys land here, and
  // install a CAPTURE-phase native Esc handler. Modal's close-on-Esc is
  // a bubble-phase document listener that React's synthetic
  // stopPropagation cannot reach — only a native capture listener that
  // runs first can intercept it. stopImmediatePropagation covers any
  // other same-phase document listeners.
  useEffect(() => {
    if (!open) return;
    menuRef.current
      ?.querySelector<HTMLButtonElement>('[role="menuitem"]')
      ?.focus();

    function onEscape(e: globalThis.KeyboardEvent) {
      if (e.key !== "Escape") return;
      e.preventDefault();
      e.stopPropagation();
      e.stopImmediatePropagation();
      close();
    }
    document.addEventListener("keydown", onEscape, true);
    return () => document.removeEventListener("keydown", onEscape, true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  function onMenuKeyDown(e: React.KeyboardEvent) {
    if (!open) return;
    const buttons = menuRef.current?.querySelectorAll<HTMLButtonElement>(
      '[role="menuitem"]'
    );
    if (!buttons || buttons.length === 0) return;
    const menuItems = Array.from(buttons);
    const idx = menuItems.indexOf(document.activeElement as HTMLButtonElement);
    if (e.key === "ArrowDown") {
      e.preventDefault();
      menuItems[(idx + 1) % menuItems.length].focus();
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      menuItems[(idx - 1 + menuItems.length) % menuItems.length].focus();
    }
  }

  if (items.length === 0) return null;
  return (
    <div className="relative" onKeyDown={onMenuKeyDown}>
      <button
        ref={buttonRef}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label="More actions"
        onClick={() => setOpen((o) => !o)}
        className="flex h-10 w-10 items-center justify-center rounded-md text-slate-500 hover:bg-slate-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500"
      >
        <MoreHorizontal className="h-5 w-5" />
      </button>
      {open && (
        <>
          <div className="fixed inset-0 z-10" onClick={() => close(false)} />
          <div
            ref={menuRef}
            role="menu"
            className="absolute right-0 z-20 mt-1 w-52 rounded-md border border-slate-200 bg-white py-1 shadow-lg"
          >
            {items.map((item) => (
              <button
                key={item.label}
                role="menuitem"
                disabled={item.disabled}
                onClick={() => {
                  if (item.disabled) return;
                  close();
                  item.onSelect();
                }}
                className={`block w-full px-3 py-2.5 text-left text-sm focus-visible:outline-none ${
                  item.disabled
                    ? "cursor-not-allowed text-slate-400"
                    : `hover:bg-slate-50 focus-visible:bg-slate-100 ${
                        item.danger ? "text-red-600" : "text-slate-700"
                      }`
                }`}
              >
                {item.label}
              </button>
            ))}
          </div>
        </>
      )}
    </div>
  );
}

function JourneyWorkspaceHeader({
  journey,
  exchangeParent,
  exchangeAction,
  onOpenParent,
  onClose,
  menuItems,
}: {
  journey: JourneyWithDetails;
  exchangeParent: ExchangeParentLink | null;
  exchangeAction: ExchangeActionRead | null;
  onOpenParent: () => void;
  onClose: () => void;
  menuItems: MenuItem[];
}) {
  return (
    <div className="flex items-start justify-between gap-4">
      <div className="min-w-0">
        <div className="flex flex-wrap items-center gap-2">
          <h2 className="text-xl font-semibold text-slate-900">
            {journey.customer
              ? `${journey.customer.first_name} ${journey.customer.last_name}`
              : "Unknown customer"}
          </h2>
          <span className="rounded-full bg-slate-100 px-2.5 py-0.5 text-xs font-medium text-slate-700">
            {journey.current_state}
          </span>
          {journey.journey_number && (
            <span className="inline-flex items-center gap-1 font-mono text-xs text-slate-500">
              {journey.journey_number}
              <button
                type="button"
                title="Copy journey number"
                onClick={() =>
                  navigator.clipboard?.writeText(journey.journey_number!)
                }
                className="text-slate-400 hover:text-slate-600"
              >
                <Copy className="h-3.5 w-3.5" />
              </button>
            </span>
          )}
          {journey.sale_kind === "EXCHANGE" && (
            <span className="rounded-full bg-indigo-100 px-2.5 py-0.5 text-xs font-medium text-indigo-700">
              Exchange
            </span>
          )}
          {journey.cancelled_at && (
            <span className="rounded-full bg-red-100 px-2.5 py-0.5 text-xs font-medium text-red-700">
              Cancelled
            </span>
          )}
        </div>
        <p className="mt-0.5 truncate text-xs text-slate-500">
          {journey.store?.name ?? "—"}
          {journey.employee ? ` · Owner: ${journey.employee.name}` : ""}
        </p>
        {exchangeParent && (
          <p className="mt-0.5 text-xs text-slate-500">
            Exchange of{" "}
            {exchangeParent.original_mattress_name ?? "the original mattress"}
            ,{" "}
            <button
              onClick={onOpenParent}
              className="font-medium text-brand-600 hover:underline"
            >
              Journey
            </button>
          </p>
        )}
        {exchangeParent &&
          exchangeAction &&
          // original_received_on arrives with 091; a pre-091 action read
          // lacks it entirely — render nothing rather than guess.
          exchangeAction.original_received_on !== undefined &&
          (exchangeAction.status === "COMMITTED" ? (
            <p className="mt-0.5 text-xs text-slate-500">
              {exchangeAction.original_received_on
                ? `Original mattress received on ${shortDate(
                    exchangeAction.original_received_on
                  )}`
                : "Original mattress not yet received"}
              {exchangeAction.refund_recorded_at != null
                ? ` · Refund recorded: ${
                    exchangeAction.refund_method ?? "—"
                  }, ${shortDate(exchangeAction.refund_recorded_at)}`
                : (exchangeAction.refund_owed_cents ?? 0) > 0
                ? ` · Refund owed to customer: $${(
                    (exchangeAction.refund_owed_cents ?? 0) / 100
                  ).toFixed(2)}`
                : ""}
            </p>
          ) : exchangeAction.status === "COMPLETED" &&
            exchangeAction.original_received_on ? (
            <p className="mt-0.5 text-xs text-slate-500">
              Original mattress received on{" "}
              {shortDate(exchangeAction.original_received_on)}
            </p>
          ) : null)}
      </div>
      <div className="flex shrink-0 items-center gap-1">
        <HeaderMenu items={menuItems} />
        <button
          onClick={onClose}
          aria-label="Close workspace"
          className="flex h-10 w-10 items-center justify-center rounded-md text-slate-500 hover:bg-slate-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500"
        >
          <X className="h-5 w-5" />
        </button>
      </div>
    </div>
  );
}

function SummaryCell({ label, children }: { label: string; children?: React.ReactNode }) {
  return (
    <div className="min-w-0 px-3 py-2">
      <p className="text-[10px] font-semibold uppercase tracking-wide text-slate-400">
        {label}
      </p>
      {children ? (
        <div className="mt-0.5 text-sm font-medium text-slate-800">{children}</div>
      ) : (
        <div className="mt-0.5 text-sm text-slate-400">—</div>
      )}
    </div>
  );
}

type AttentionItem = { text: string; tone: "red" | "amber" };

function JourneyStateSummaryBar({
  journey,
  nextFollowUp,
  stateDetail,
  transferNote,
  attentionItems,
  transitions,
  exchangeAwaitingPayment,
  paymentSettled,
  refreshPending,
  onAction,
}: {
  journey: JourneyWithDetails;
  nextFollowUp: FollowUp | undefined;
  stateDetail: string | null;
  transferNote: { kind: "requested" | "scheduled" | "shipped"; text: string; requestId: string; destName?: string | null } | null;
  attentionItems: AttentionItem[];
  transitions: { label: string; event: JourneyEventType }[];
  // EB-3a: an exchange child sitting in Quoted with a positive balance is
  // waiting on money, not a workflow step (spec 16).
  exchangeAwaitingPayment: boolean;
  // Paid >= price: the Quoted -> Sold flip may still be in flight, but
  // Record Payment must never be offered — a second payment is a
  // double-charge, not a cosmetic glitch.
  paymentSettled: boolean;
  refreshPending?: boolean;
  onAction: (
    j: JourneyWithDetails,
    e: JourneyEventType,
    opts?: { fulfillmentMethod?: "pickup" | "delivery" }
  ) => void;
}) {
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const followUpOverdue =
    nextFollowUp !== undefined && new Date(nextFollowUp.due_at) < today;
  // trial_completed stays excluded: Sleep Trial → Completed is ungated,
  // so "Complete Trial" must never read as the default next step just
  // because no follow-up is scheduled.
  const nextActionTransition = transitions.find(
    (t) =>
      t.event !== "trial_completed" &&
      !(t.event === "payment_completed" && paymentSettled)
  );
  return (
    <div className="mt-3 grid grid-cols-3 divide-x divide-slate-200 rounded-md border border-slate-200 bg-slate-50">
      <SummaryCell label="Current State">
        <span className="inline-flex items-center gap-1.5">
          {journey.current_state}
          {journey.cancelled_at && (
            <span className="text-xs font-normal text-red-600">(cancelled)</span>
          )}
        </span>
        {stateDetail && (
          <span className="block text-xs font-normal text-slate-500">
            {stateDetail}
          </span>
        )}
        {transferNote && (
          <span className="mt-0.5 flex items-center gap-1 text-xs font-semibold text-amber-700">
            <Truck className="h-3.5 w-3.5 shrink-0" aria-hidden />
            <span>
              {transferNote.text}
              {transferNote.kind === "requested" && (
                <>
                  {" "}
                  <Link href="/transfers" className="underline hover:text-amber-800">
                    View request
                  </Link>
                </>
              )}
            </span>
          </span>
        )}
      </SummaryCell>
      <SummaryCell label="Next Action">
        {/* Keyed branches: span↔button swaps at one JSX position made React
            remove a bare node mid-commit — keys force whole-subtree swaps. */}
        {journey.cancelled_at ? (
          <span key="na-none" className="font-normal text-slate-400">No action needed</span>
        ) : exchangeAwaitingPayment ? (
          <span key="na-payment">Waiting for the customer&apos;s payment</span>
        ) : nextFollowUp ? (
          followUpOverdue ? (
            <span key="na-overdue" className="text-red-700">
              Follow-up overdue ({shortDate(nextFollowUp.due_at)})
            </span>
          ) : (
            <span key="na-followup">
              Follow up {shortDate(nextFollowUp.due_at)}
              <span className="block text-xs font-normal text-slate-500">
                {followUpLabel(nextFollowUp)}
              </span>
            </span>
          )
        ) : journey.current_state === "Waiting for Inventory" ? (
          <span key="na-inventory">
            {transferNote
              ? `Wait for transfer. Call customer when it arrives at ${
                  transferNote.destName ?? "the pickup store"
                }.`
              : "Call customer when inventory arrives"}
          </span>
        ) : nextActionTransition ? (
          // trial_completed stays excluded: Sleep Trial → Completed is
          // ungated, so "Complete Trial" must never read as the default
          // next step just because no follow-up is scheduled. A settled
          // payment also never surfaces Record Payment here.
          <button
            key="na-action"
            disabled={refreshPending}
            onClick={() => onAction(journey, nextActionTransition.event)}
            className="text-left font-medium text-brand-600 hover:text-brand-700 disabled:opacity-50"
          >
            {nextActionTransition.label}
          </button>
        ) : (
          <span key="na-idle" className="font-normal text-slate-400">No action needed</span>
        )}
      </SummaryCell>
      <SummaryCell label="Attention">
        {attentionItems.length === 0 ? (
          <span key="attention-none" className="text-xs font-normal text-slate-400">None</span>
        ) : (
          // display:contents — a keyed wrapper for the swap that adds no
          // layout box of its own.
          <span key="attention-items" className="contents">
            {attentionItems.slice(0, 2).map((a) => (
              <span
                key={a.text}
                className={`block text-xs font-normal ${
                  a.tone === "red" ? "text-red-700" : "text-amber-700"
                }`}
              >
                {a.text}
              </span>
            ))}
            {attentionItems.length > 2 && (
              <span className="block text-xs font-normal text-slate-500">
                +{attentionItems.length - 2} more
              </span>
            )}
          </span>
        )}
      </SummaryCell>
    </div>
  );
}

function RailCard({
  title,
  children,
}: {
  title: string;
  children: React.ReactNode;
}) {
  return (
    <section className="py-4 first:pt-0 last:pb-0">
      <h3 className="text-xs font-semibold uppercase tracking-wide text-slate-500">
        {title}
      </h3>
      <div className="mt-2 text-sm">{children}</div>
    </section>
  );
}

function RailRow({
  label,
  children,
  align = "left",
}: {
  label: string;
  children: React.ReactNode;
  align?: "left" | "right";
}) {
  return (
    <div className="flex items-start justify-between gap-3 py-0.5">
      <span className="shrink-0 text-slate-500">{label}</span>
      <span className={`text-slate-800 ${align === "right" ? "text-right" : ""}`}>
        {children}
      </span>
    </div>
  );
}

export default function JourneyWorkspace({
  journey,
  events,
  followUps,
  employees,
  stores,
  reassignments,
  canReassign,
  canReconcile,
  currentEmployee,
  trialEvals,
  onReassigned,
  onClose,
  onAction,
  onCancel,
  onRefresh,
  refreshPending,
  openBookingSignal,
  completionDone,
  onCompletionInfo,
}: {
  journey: JourneyWithDetails;
  events: JourneyEvent[];
  followUps: FollowUp[];
  employees: Employee[];
  stores: Store[];
  reassignments: JourneyReassignmentEvent[];
  canReassign: boolean;
  canReconcile: boolean;
  currentEmployee: Employee | null;
  trialEvals: SleepTrialEvaluation[];
  onReassigned: (journeyId: string) => void | Promise<void>;
  onClose: () => void;
  onAction: (
    j: JourneyWithDetails,
    e: JourneyEventType,
    opts?: { fulfillmentMethod?: "pickup" | "delivery" }
  ) => void;
  onCancel: (j: JourneyWithDetails) => void;
  onRefresh: () => void;
  // True while the board is refetching this journey's row + events after
  // an action — forward actions stay disabled so a stale state can't be
  // acted on twice (e.g. Record Payment on an already-paid order).
  refreshPending?: boolean;
  // ?book=1 on the board URL (My Work handoff) — opens the delivery
  // picker once inside JourneyDelivery, which strips the param.
  openBookingSignal?: boolean;
  // Green note shown after a completion that landed the order on
  // Completed (no live sleep trial item) instead of Sleep Trial.
  completionDone?: string | null;
  // Reports the gated completion decision and the state the order will
  // land in, so the board's completion dialog (opened via onAction) can
  // show the same note and destination. Null while unknown.
  onCompletionInfo?: (
    info: {
      journeyId: string;
      decision: CompletionButtonDecision | null;
      goesTo: "Sleep Trial" | "Completed";
      closing: boolean;
    } | null
  ) => void;
}) {
  const router = useRouter();
  // A3: journey_cancelled leaves current_state at its last value (020),
  // so a cancelled child would still offer its old forward buttons.
  // cancelled_at is the truth — no transitions on a cancelled journey.
  const transitions = journey.cancelled_at
    ? []
    : STATE_TRANSITIONS[journey.current_state].filter((t) =>
        transitionAppliesToFulfillment(t, journey.fulfillment_type)
      );
  const isExchangeChild = journey.sale_kind === "EXCHANGE";

  // Live trial items decide whether completion lands on Sleep Trial or
  // Completed (m149 complete_order_without_trial). null means "unknown"
  // (not read yet, read failed, or a refetch is in flight) and never
  // promises Completed. Refetched on journey/state change and on every
  // panel refresh; the dialog reads again when it opens.
  const [liveTrialStatuses, setLiveTrialStatuses] = useState<
    string[] | null
  >(null);
  const [trialReadSeq, setTrialReadSeq] = useState(0);
  // Any new event on the order (handover, payment, cancellation, ...) must
  // re-run both reads below: events.length plus the newest event's id
  // changes on every insert.
  const eventSignal = `${events.length}:${events[events.length - 1]?.id ?? ""}`;
  useEffect(() => {
    let alive = true;
    setLiveTrialStatuses(null);
    fetchJourneyLiveTrialStatuses(journey.id).then((s) => {
      if (alive) setLiveTrialStatuses(s);
    });
    return () => {
      alive = false;
    };
  }, [journey.id, journey.current_state, trialReadSeq, eventSignal]);

  // Slice 2a: per-unit handover status, same refresh discipline as
  // liveTrialStatuses (journey/state change, every panel refresh, and any
  // new event). Quote-stage orders skip the read entirely. A failed read
  // is flagged and rendered as an error line, never as "nothing handed
  // over". The summary clears only when the order itself changes; a
  // same-order refetch keeps the old values until the new ones land, so
  // the chips never blink.
  const [fulfillmentSummary, setFulfillmentSummary] =
    useState<JourneyFulfillmentSummary | null>(null);
  const [fulfillmentReadFailed, setFulfillmentReadFailed] = useState(false);
  const pastQuoted =
    getStateIndex(journey.current_state) >= getStateIndex("Sold");
  const fulfillmentJourneyRef = useRef(journey.id);
  useEffect(() => {
    if (fulfillmentJourneyRef.current !== journey.id) {
      fulfillmentJourneyRef.current = journey.id;
      setFulfillmentSummary(null);
    }
    if (!pastQuoted) {
      setFulfillmentReadFailed(false);
      return;
    }
    let alive = true;
    setFulfillmentReadFailed(false);
    fetchJourneyFulfillmentSummary(journey.id)
      .then((s) => {
        if (alive) setFulfillmentSummary(s);
      })
      .catch(() => {
        if (alive) setFulfillmentReadFailed(true);
      });
    return () => {
      alive = false;
    };
  }, [journey.id, journey.current_state, trialReadSeq, pastQuoted, eventSignal]);

  const totalHanded = useMemo(
    () =>
      Object.values(fulfillmentSummary?.byLine ?? {}).reduce(
        (sum, n) => sum + n,
        0
      ),
    [fulfillmentSummary]
  );

  const completionGoesTo = useMemo(
    () =>
      completionDestinationFor({
        saleKind: journey.sale_kind,
        liveTrialStatuses,
      }),
    [journey.sale_kind, liveTrialStatuses]
  );

  const paid = computeNetPaid(events);

  // cancelled_at nulls the balance — a cancelled journey shows what was
  // agreed/paid (and any credit due back) but never an amount still owed.
  const balance = journey.cancelled_at
    ? null
    : journey.price !== null && journey.price !== undefined
      ? journey.price - paid
      : null;

  // An exchange child in Quoted with money still owed: Next Action reads
  // "Waiting for the customer's payment" and Record Payment is primary.
  const exchangeAwaitingPayment =
    isExchangeChild &&
    !journey.cancelled_at &&
    journey.current_state === "Quoted" &&
    (journey.price ?? 0) > 0 &&
    paid < (journey.price ?? 0);

  // A $0 journey (e.g. an even-or-credit exchange that flipped straight to
  // Sold, or an exchange child priced at zero) must never offer Record
  // Payment — the payment would write a bad record.
  const paymentAllowed = (journey.price ?? 0) > 0;

  // Paid >= price means no payment is due even if current_state hasn't
  // caught up yet (the Quoted -> Sold flip lands with the same event that
  // paid it). Record Payment must never be offered in that window — a
  // second payment is a real double-charge, not a cosmetic glitch.
  const paymentSettled =
    journey.price != null &&
    journey.price > 0 &&
    paid >= journey.price;

  const nextFollowUp = followUps
    .filter((f) => !f.completed_at)
    .sort((a, b) => new Date(a.due_at).getTime() - new Date(b.due_at).getTime())[0];

  const [lineItems, setLineItems] = useState<JourneyLineItem[]>([]);
  // Lines whose fulfillment dropdown the user explicitly set this
  // session. Picking a pickup location alone does not count; the DB
  // cannot tell a location-pinned 'pickup' override from a chosen one,
  // so explicitness is tracked here.
  const [explicitLineChoices, setExplicitLineChoices] = useState<
    Record<string, "delivery" | "pickup">
  >({});
  const [lineItemsLoading, setLineItemsLoading] = useState(false);
  // True once the first line-items fetch for this journey has resolved —
  // background refetches (every events change re-runs the fetch) must not
  // flash "Loading items…" or hide the empty state again.
  const [lineItemsLoaded, setLineItemsLoaded] = useState(false);
  // Completion permissions, fetched once per panel open (m149). The RPC
  // re-checks every rule on write; these only decide which control to
  // show so the panel never offers a button that cannot succeed.
  const [completionPerms, setCompletionPerms] = useState<{
    activeStoreId: string | null;
    canMarkFulfilled: boolean;
    canPickupAnyLocation: boolean;
    canFinalizeDelivery: boolean;
  } | null>(null);
  const [journeyUnits, setJourneyUnits] = useState<
    {
      requirement_id: string | null;
      variant_id: string;
      unit_id: string;
      unit_number: number;
      status: string;
    }[]
  >([]);
  const [journeyTransfers, setJourneyTransfers] = useState<
    {
      id: string;
      status: string;
      quantity: number;
      origin_location_id: string;
      destination_location_id: string;
      transfer_id: string | null;
      transfers: {
        status: string;
        scheduled_date: string;
        in_transit_at: string | null;
        finalized_at: string | null;
      } | null;
    }[]
  >([]);
  const [unitLocations, setUnitLocations] = useState<Record<string, string>>({});
  const [reassignMode, setReassignMode] = useState<"choose" | "store" | "employee" | null>(null);
  const [reassignTarget, setReassignTarget] = useState("");
  const [reassignReason, setReassignReason] = useState("");
  const [reassignSaving, setReassignSaving] = useState(false);
  const [fulfillmentSaving, setFulfillmentSaving] = useState(false);
  // Ship-to chooser (m145): replaces the old editor that rewrote the
  // customer's primary address on every order.
  const [shipToOpen, setShipToOpen] = useState(false);
  const [shipToLoading, setShipToLoading] = useState(false);
  const [shipToSaving, setShipToSaving] = useState(false);
  const [shipToMode, setShipToMode] = useState<"primary" | "saved" | "new">("primary");
  const [shipToAddressId, setShipToAddressId] = useState<string | null>(null);
  const [shipToNew, setShipToNew] = useState({
    label: "",
    street: "",
    line2: "",
    city: "",
    state: "",
    zip: "",
  });
  const [savedAddresses, setSavedAddresses] = useState<CustomerAddress[]>([]);
  const [primaryOpenOrders, setPrimaryOpenOrders] = useState(0);
  // Lets the chooser's Cancel button run Modal's guarded close (asks
  // "Discard changes?" when the new-address form has typed text).
  const shipToCloseRef = useRef<(() => void) | null>(null);
  const [lineAvailability, setLineAvailability] = useState<Record<string, number>>({});
  const [lineAvailabilityFailed, setLineAvailabilityFailed] = useState<Record<string, boolean>>({});
  // Inline quantity-floor message for the edit-order row that was last
  // blurred below its handed-over count (m153 floor).
  const [lineQtyError, setLineQtyError] = useState<{
    itemId: string;
    text: string;
  } | null>(null);
  const [lineLocationStock, setLineLocationStock] = useState<Record<string, LocationAvailability[]>>({});
  const [lineStockArrivals, setLineStockArrivals] = useState<Record<string, Record<string, number>>>({});
  const [lineStockLoaded, setLineStockLoaded] = useState(false);
  const [lineStockFailed, setLineStockFailed] = useState(false);
  const [otherStoresItemId, setOtherStoresItemId] = useState<string | null>(null);
  const [otherStoresQuery, setOtherStoresQuery] = useState("");
  const [orderEditing, setOrderEditing] = useState(false);
  const [customerContacts, setCustomerContacts] = useState<CustomerContact[]>([]);
  // Inline error for every action on this panel — replaces window.alert.
  // Cleared at the start of each attempt; journey switch remounts the
  // workspace, so a stale error can never linger on another journey.
  const [panelError, setPanelError] = useState<string | null>(null);
  const [confirmFulfillment, setConfirmFulfillment] = useState<
    "delivery" | "pickup" | null
  >(null);
  const [confirmRemoveItem, setConfirmRemoveItem] = useState<string | null>(null);
  const [addressPromptOpen, setAddressPromptOpen] = useState(false);
  // Reassign can be started from the header "..." menu — scroll the
  // Ownership card's chooser into view when it appears.
  const reassignRef = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (reassignMode === "choose") {
      reassignRef.current?.scrollIntoView({
        behavior: "smooth",
        block: "nearest",
      });
    }
  }, [reassignMode]);

  // m149 completion permissions, once per panel open. Active location is
  // user_metadata.active_store_id with the employee's home store as the
  // fallback, the same resolution the RPC applies.
  useEffect(() => {
    let alive = true;
    (async () => {
      const supabase = createClient();
      const {
        data: { session },
      } = await supabase.auth.getSession();
      const activeStoreId =
        (session?.user?.user_metadata?.active_store_id as
          | string
          | undefined) ?? currentEmployee?.home_store_id ?? null;
      const [markFulfilled, pickupAny, canFinalize] = await Promise.all([
        hasPermission("orders.mark_fulfilled"),
        hasPermission("orders.pickup_any_location"),
        canFinalizeDelivery(),
      ]);
      if (alive) {
        setCompletionPerms({
          activeStoreId,
          canMarkFulfilled: markFulfilled,
          canPickupAnyLocation: pickupAny,
          canFinalizeDelivery: canFinalize,
        });
      }
    })();
    return () => {
      alive = false;
    };
  }, [currentEmployee?.home_store_id]);

  // The completion transition for this order, if its state/fulfillment
  // allows one at all. The button-or-note decision below layers the m149
  // permission and location rules on top.
  const completionTransition = transitions.find(
    (t) => t.event === "delivery_completed"
  );

  const storeNameFor = (id: string) =>
    stores.find((s) => s.id === id)?.name ??
    (id === journey.store_id ? journey.store?.name ?? null : null);

  const completionDecision: CompletionButtonDecision | null = useMemo(() => {
    if (!completionTransition || !completionPerms || !lineItemsLoaded) {
      return null;
    }
    return completionButtonDecision({
      fulfillment: journey.fulfillment_type,
      canMarkFulfilled: completionPerms.canMarkFulfilled,
      canPickupAnyLocation: completionPerms.canPickupAnyLocation,
      canFinalizeDelivery: completionPerms.canFinalizeDelivery,
      activeStoreId: completionPerms.activeStoreId,
      items: lineItems,
      journeyStoreId: journey.store_id,
      storeName: storeNameFor,
      handed: fulfillmentSummary?.byLine,
    });
  }, [
    completionTransition,
    completionPerms,
    lineItemsLoaded,
    lineItems,
    journey,
    stores,
    fulfillmentSummary,
  ]);

  const completionAllowed = completionDecision?.kind === "button";

  // Whether the completion button's handover closes the order: false
  // while other-method units remain, so the board's dialog can say the
  // order stays open instead of promising Sleep Trial or Completed.
  const completionClosing = useMemo(
    () =>
      completionClosesOrder({
        fulfillment: journey.fulfillment_type,
        items: lineItems,
        handed: fulfillmentSummary?.byLine,
      }),
    [journey.fulfillment_type, lineItems, fulfillmentSummary]
  );

  // The unified completion dialog is scoped to one method. This is the
  // secondary "Mark picked up" control: it opens the dialog for pickup
  // lines whenever the primary completion control does not already cover
  // them (delivery orders, and pickup orders in states the transition
  // list does not cover like Waiting for Inventory). Same gate the old
  // handover button used: open order in a handover-allowed state with
  // the fulfillment summary loaded.
  const pickupSecondaryActive =
    !journey.cancelled_at &&
    !journey.delivered_at &&
    ["Sold", "Ready to Schedule", "Waiting for Inventory", "Scheduled"].includes(
      journey.current_state
    ) &&
    fulfillmentSummary !== null &&
    !fulfillmentReadFailed &&
    !(journey.fulfillment_type === "pickup" && completionTransition);

  const pickupDecision: CompletionButtonDecision | null = useMemo(() => {
    if (!pickupSecondaryActive || !completionPerms || !lineItemsLoaded) {
      return null;
    }
    return completionButtonDecision({
      fulfillment: "pickup",
      orderFulfillment: journey.fulfillment_type,
      canMarkFulfilled: completionPerms.canMarkFulfilled,
      canPickupAnyLocation: completionPerms.canPickupAnyLocation,
      canFinalizeDelivery: completionPerms.canFinalizeDelivery,
      activeStoreId: completionPerms.activeStoreId,
      items: lineItems,
      journeyStoreId: journey.store_id,
      storeName: storeNameFor,
      handed: fulfillmentSummary?.byLine,
    });
  }, [
    pickupSecondaryActive,
    completionPerms,
    lineItemsLoaded,
    lineItems,
    journey,
    fulfillmentSummary,
  ]);

  // delivery_completed renders through the gated block below, never as a
  // plain transition button. Hidden/note decisions must not leak into
  // the generic action list or the Next Action bar.
  const panelTransitions = transitions.filter(
    (t) => t.event !== "delivery_completed" || completionAllowed
  );

  // Hand the board the same decision and destination the panel shows, so
  // the dialog it opens cannot disagree (permission note, Sleep Trial vs
  // Completed, or stays open). Cleared on unmount so a stale note never
  // leaks.
  useEffect(() => {
    onCompletionInfo?.({
      journeyId: journey.id,
      decision: completionDecision,
      goesTo: completionGoesTo,
      closing: completionClosing,
    });
    return () => onCompletionInfo?.(null);
  }, [
    onCompletionInfo,
    journey.id,
    completionDecision,
    completionGoesTo,
    completionClosing,
  ]);
  // Bumped on every panel refresh so JourneyActivity refetches its
  // interactions — journey.id alone doesn't change on refresh.
  const [activityRefreshKey, setActivityRefreshKey] = useState(0);
  // JourneyActivity reports whether an inline form (pin panel,
  // schedule follow-up) has unsaved input or a save in flight.
  const [activityState, setActivityState] = useState({
    dirty: false,
    saving: false,
  });

  async function handlePanelRefresh() {
    await onRefresh();
    // A1: the exchange action's money figures change on every line
    // edit — refetch alongside the journey data or the refund banner,
    // header line and overpaid banner go stale until reload.
    await refreshExchangeRead();
    setActivityRefreshKey((k) => k + 1);
    // Trial items bind at Sold and on line edits, both of which land
    // through this refresh; re-read so the completion destination cannot
    // be stale. The read above resets to null (unknown) while in flight.
    setTrialReadSeq((k) => k + 1);
  }

  async function refreshExchangeRead() {
    if (!isExchangeChild || !journey.exchange_action_id) return;
    try {
      setExchangeAction(await getExchangeAction(journey.exchange_action_id));
    } catch {
      // Keep the last good read — a transient fetch failure must not
      // blank the refund banner.
    }
  }

  const inventoryStoreId = useMemo(
    () => resolveLineItemLocation({}, journey, stores),
    [stores, journey.store_id, journey.fulfillment_type]
  );
  const shipTo = effectiveShipTo(journey, journey.customer);
  const hasDeliveryAddress = !!shipTo?.street_address?.trim();
  const customerAddress = formatShipToLine(shipTo);
  const shipToLocked =
    journey.fulfillment_type === "pickup" ||
    !!journey.cancelled_at ||
    !!journey.delivered_at;
  // Delivery orders require a primary address (m036), so with none on
  // file the chooser's "new" option writes the primary instead of a
  // saved ship-to row.
  const customerHasPrimary = !!journey.customer?.street_address?.trim();

  // Latest scheduled delivery date, if a delivery_scheduled event
  // carries one — drives the Fulfillment status line. Shown only while
  // the journey is actually Scheduled; the event stays in history after
  // a journey is pulled back to Waiting for Inventory.
  const scheduledDate =
    journey.current_state === "Scheduled"
      ? [...events]
          .filter(
            (e) =>
              e.event_type === "delivery_scheduled" &&
              e.event_data?.delivery_date
          )
          .map((e) => String(e.event_data?.delivery_date))
          .pop() ?? null
      : null;

  const storeOptions = stores.filter((s) => s.is_active && s.id !== journey.store_id);
  const employeeOptions = employees.filter(
    (e) => e.home_store_id === journey.store_id && e.id !== journey.assigned_employee_id
  );

  function openReassign(mode: "choose" | "store" | "employee") {
    setReassignMode(mode);
    setReassignTarget("");
    setReassignReason("");
  }

  function closeReassign() {
    setReassignMode(null);
    setReassignTarget("");
    setReassignReason("");
  }

  async function submitFulfillmentChange(value: "delivery" | "pickup") {
    if (value === "delivery" && !hasDeliveryAddress) {
      setAddressPromptOpen(true);
      return;
    }
    if (value === journey.fulfillment_type) return;
    const hasReservation = [
      "Sold",
      "Waiting for Inventory",
      "Ready to Schedule",
    ].includes(journey.current_state);
    if (hasReservation) {
      setConfirmFulfillment(value);
      return;
    }
    await doFulfillmentChange(value);
  }

  async function doFulfillmentChange(value: "delivery" | "pickup") {
    setPanelError(null);
    setFulfillmentSaving(true);
    try {
      await updateJourneyFulfillment(journey.id, value);
      // Recompute every line against the new order fulfillment. A line
      // follows the order unless the user explicitly set its dropdown;
      // a location-pinned 'pickup' override is not explicit.
      for (const item of lineItems) {
        const stored = item.fulfillment_type_override;
        const explicit =
          explicitLineChoices[item.id] ??
          // A 'pickup' override carrying a location on a journey that was
          // pickup is location-driven, not a chosen override.
          (journey.fulfillment_type === "pickup" &&
          stored === "pickup" &&
          item.pickup_location_id
            ? null
            : stored);
        const payload = lineItemFulfillmentPayload({
          explicitChoice: explicit,
          pickupLocationId: item.pickup_location_id,
          orderFulfillment: value,
        });
        const unchanged =
          payload.fulfillmentTypeOverride === stored &&
          payload.pickupLocationId === (item.pickup_location_id ?? null);
        if (!unchanged) {
          await updateJourneyLineItem(item.id, {
            fulfillment_type_override: payload.fulfillmentTypeOverride,
            pickup_location_id: payload.pickupLocationId,
          });
        }
      }
      await handlePanelRefresh();
    } catch (e: any) {
      setPanelError(e.message ?? "Failed to update fulfillment type");
    } finally {
      setFulfillmentSaving(false);
    }
  }

  async function openShipToChooser(prefillNew = false) {
    if (!journey.customer) return;
    setPanelError(null);
    const hasPrimary = !!journey.customer?.street_address?.trim();
    setShipToMode(
      !hasPrimary
        ? "new"
        : prefillNew
          ? "new"
          : journey.ship_to_address_id
            ? "saved"
            : "primary"
    );
    setShipToAddressId(journey.ship_to_address_id ?? null);
    setShipToNew({ label: "", street: "", line2: "", city: "", state: "", zip: "" });
    setShipToOpen(true);
    setShipToLoading(true);
    try {
      const detail = await getCustomer(journey.customer.id);
      setSavedAddresses(detail.addresses ?? []);
      setPrimaryOpenOrders(detail.primary_open_orders ?? 0);
    } catch (e: any) {
      setPanelError(e?.message ?? "Could not load saved addresses");
    } finally {
      setShipToLoading(false);
    }
  }

  const shipToNewDirty =
    shipToMode === "new" &&
    [shipToNew.label, shipToNew.street, shipToNew.line2, shipToNew.city, shipToNew.state, shipToNew.zip]
      .some((v) => v.trim() !== "");

  async function saveShipTo() {
    if (!journey.customer) return;
    setPanelError(null);
    setShipToSaving(true);
    try {
      let addressId: string | null = null;
      if (shipToMode === "new" && !customerHasPrimary) {
        // No primary on file: save this as the customer's primary
        // address. Delivery requires it; no ship-to row is written.
        if (!shipToNew.street.trim()) {
          setPanelError("Street address is required.");
          setShipToSaving(false);
          return;
        }
        await updateCustomer(journey.customer.id, {
          street_address: shipToNew.street.trim(),
          street_address_line_2: shipToNew.line2.trim() || null,
          city: shipToNew.city.trim() || null,
          state: shipToNew.state.trim() || null,
          zip_code: shipToNew.zip.trim() || null,
        });
        setShipToOpen(false);
        await handlePanelRefresh();
        setShipToSaving(false);
        return;
      }
      if (shipToMode === "new") {
        if (!shipToNew.street.trim()) {
          setPanelError("Street address is required.");
          setShipToSaving(false);
          return;
        }
        const created = await addCustomerAddress(journey.customer.id, {
          label: shipToNew.label.trim() || null,
          street_address: shipToNew.street.trim(),
          street_address_line_2: shipToNew.line2.trim() || null,
          city: shipToNew.city.trim() || null,
          state: shipToNew.state.trim() || null,
          zip_code: shipToNew.zip.trim() || null,
        });
        addressId = created.id;
      } else if (shipToMode === "saved") {
        addressId = shipToAddressId;
      }
      await setJourneyShipTo(journey.id, addressId);
      setShipToOpen(false);
      await handlePanelRefresh();
    } catch (e: any) {
      setPanelError(e?.message ?? "Failed to update delivery address");
    } finally {
      setShipToSaving(false);
    }
  }

  async function submitReassign() {
    setPanelError(null);
    if (reassignMode !== "store" && reassignMode !== "employee") return;
    if (!reassignTarget) return;
    setReassignSaving(true);
    try {
      if (reassignMode === "store") {
        await reassignJourneyStore(journey.id, reassignTarget, reassignReason);
      } else {
        await reassignJourneyEmployee(journey.id, reassignTarget, reassignReason);
      }
      closeReassign();
      await onReassigned(journey.id);
    } catch (e: any) {
      setPanelError(e.message ?? "Failed to reassign journey");
    } finally {
      setReassignSaving(false);
    }
  }

  // Exchange child: who/what it was exchanged from, and any refund owed.
  // Read through the security-definer RPCs (089) — sleep_trial_actions
  // isn't client-readable.
  const [exchangeParent, setExchangeParent] =
    useState<ExchangeParentLink | null>(null);
  const [exchangeAction, setExchangeAction] =
    useState<ExchangeActionRead | null>(null);
  const [exchangeBlockNoticeOpen, setExchangeBlockNoticeOpen] =
    useState(false);
  const [pendingAddOn, setPendingAddOn] = useState<{
    selection: ProductSelection;
    unitPrice: number;
    warnings: string[];
  } | null>(null);
  useEffect(() => {
    if (!isExchangeChild) {
      setExchangeParent(null);
      setExchangeAction(null);
      return;
    }
    getJourneyExchangeActions(journey.id)
      .then((info) => setExchangeParent(info.parent))
      .catch(() => {
        // Keep the last good read — a transient failure must not blank
        // the "Exchange of …" header line.
      });
    if (journey.exchange_action_id) {
      getExchangeAction(journey.exchange_action_id)
        .then(setExchangeAction)
        .catch(() => {
          // Keep the last good read — same reason as above.
        });
    }
    // journey.updated_at: every server-side write to this journey — line
    // changes via sync_journey_price, Schedule Delivery, Mark Delivered —
    // bumps it, so the action read stays fresh on prop updates too.
  }, [journey.id, journey.exchange_action_id, journey.updated_at, isExchangeChild]);

  // Refund banner on the child: only while a COMMITTED action has an
  // owed, unrecorded refund.
  const exchangeRefundCents =
    exchangeAction?.status === "COMMITTED" &&
    exchangeAction.refund_recorded_at == null
      ? exchangeAction.refund_owed_cents ?? 0
      : 0;

  // The original journey while any of its trial items is parked on an
  // open exchange/return (item status, not action status — the item is
  // what the DB guards key on).
  const hasLiveExchange = trialEvals.some(
    (e) =>
      e.item?.status === "EXCHANGE_IN_PROGRESS" ||
      e.item?.status === "RETURN_IN_PROGRESS"
  );

  useEffect(() => {
    setLineItemsLoading(true);
    fetchJourneyLineItems(journey.id).then((items) => {
      setLineItems(items);
      setLineItemsLoading(false);
      setLineItemsLoaded(true);
    });
    setJourneyUnits([]);
    let unitsCancelled = false;
    Promise.resolve(
      createClient().rpc("get_journey_units", { p_journey_id: journey.id })
    )
      .then(({ data }) => {
        if (unitsCancelled) return;
        const rows = (data ?? []) as any[];
        setJourneyUnits(rows);
        const ids = rows.map((r) => r.unit_id).filter(Boolean);
        if (ids.length === 0) {
          setUnitLocations({});
          return;
        }
        createClient()
          .from("units")
          .select("id, location_id")
          .in("id", ids)
          .then(({ data: locs }) => {
            if (unitsCancelled) return;
            setUnitLocations(
              Object.fromEntries(
                ((locs ?? []) as any[]).map((l) => [l.id, l.location_id])
              )
            );
          });
      })
      .catch(() => {
        if (!unitsCancelled) setJourneyUnits([]);
      });
    Promise.resolve(
      createClient()
        .from("transfer_requests")
        .select(
          "id, status, quantity, origin_location_id, destination_location_id, transfer_id, transfers!transfer_id ( status, scheduled_date, in_transit_at, finalized_at )"
        )
        .eq("source_type", "journey_mismatch")
        .eq("source_reference_id", journey.id)
        .in("status", ["pending_approval", "approved", "consolidated"])
    )
      .then(({ data }) => {
        if (!unitsCancelled) setJourneyTransfers((data ?? []) as any);
      })
      .catch(() => {
        if (!unitsCancelled) setJourneyTransfers([]);
      });
    if (journey.customer) {
      fetchCustomerContacts(journey.customer.id).then(setCustomerContacts);
    } else {
      setCustomerContacts([]);
    }
    return () => {
      unitsCancelled = true;
    };
  }, [journey.id, events]);

  const availabilityContext = `${journey.store_id}|${journey.fulfillment_type}|${inventoryStoreId}`;
  const availabilityContextRef = useRef(availabilityContext);
  // Content key for the lookups below: a lineItems refetch produces a new
  // array identity even when nothing changed, and depending on the array
  // itself restarted every in-flight stock read on each panel refresh.
  const lineItemsKey = lineItems
    .map((i) => `${i.id}:${i.product_id ?? ""}:${i.quantity}:${i.fulfillment_type_override ?? ""}:${i.pickup_location_id ?? ""}`)
    .join(",");
  useEffect(() => {
    let ignore = false;

    // Only blank the numbers when the location context actually changes —
    // a lineItems refetch (e.g. after a payment event) keeps the last
    // values visible while fresh ones load, so the card doesn't flicker.
    if (availabilityContextRef.current !== availabilityContext) {
      availabilityContextRef.current = availabilityContext;
      setLineAvailability((previous) => {
        const next = { ...previous };
        for (const item of lineItems) delete next[item.id];
        return next;
      });
      setLineAvailabilityFailed((previous) => {
        const next = { ...previous };
        for (const item of lineItems) delete next[item.id];
        return next;
      });
    }

    Promise.all(
      lineItems.map(async (item) => {
        if (!item.product_id) return null;
        const locationId = resolveLineItemLocation(item, journey, stores);
        try {
          const map = await Promise.race([
            fetchProductStock([item.product_id], locationId),
            new Promise<never>((_, reject) =>
              setTimeout(() => reject(new Error("stock read timed out")), 10000)
            ),
          ]);
          return [item.id, map[item.product_id]?.ats ?? 0] as const;
        } catch {
          return [item.id, { error: true }] as const;
        }
      })
    ).then((values) => {
      if (ignore) return;
      const failed: Record<string, boolean> = {};
      setLineAvailability((previous) => ({
        ...previous,
        ...Object.fromEntries(
          values.filter(
            (v): v is readonly [string, number] =>
              v !== null && typeof v[1] === "number"
          )
        ),
      }));
      for (const v of values) {
        if (v && typeof v[1] !== "number") failed[v[0]] = true;
      }
      setLineAvailabilityFailed((previous) => ({ ...previous, ...failed }));
    }).catch((error) => {
      console.error("line availability load failed", error);
    });
    return () => { ignore = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lineItemsKey, availabilityContext]);

  // Per-location stock for the edit-order rows, batched once per product
  // set while editing (same data the new-order screen uses).
  const stockProductKey = useMemo(
    () =>
      Array.from(
        new Set(
          lineItems
            .map((i) => i.product_id)
            .filter((x): x is string => !!x)
        )
      )
        .sort()
        .join(","),
    [lineItems]
  );

  useEffect(() => {
    if (!orderEditing) return;
    if (!stockProductKey) {
      setLineLocationStock({});
      setLineStockArrivals({});
      setLineStockLoaded(true);
      setLineStockFailed(false);
      return;
    }
    setLineStockLoaded(false);
    setLineStockFailed(false);
    const ids = stockProductKey.split(",");
    let cancelled = false;
    Promise.all([
      fetchProductAvailabilityByLocation(ids),
      fetchInTransitArrivals(ids),
    ])
      .then(([stock, arrivals]) => {
        if (cancelled) return;
        setLineLocationStock(stock);
        setLineStockArrivals(arrivals);
        setLineStockLoaded(true);
      })
      .catch((error) => {
        console.error("line stock load failed", error);
        if (cancelled) return;
        setLineStockFailed(true);
        setLineStockLoaded(true);
      });
    return () => {
      cancelled = true;
    };
  }, [orderEditing, stockProductKey]);

  type LineStockRow = {
    id: string;
    name: string;
    available: number;
    arriving: number;
  };

  function lineStockCountText(r: LineStockRow): string {
    return `${r.available}${r.arriving > 0 ? `, ${r.arriving} arriving` : ""}`;
  }

  function lineStockBreakdown(item: JourneyLineItem): {
    primary: LineStockRow | null;
    primaryLabel: "Pickup store" | "Warehouse" | null;
    others: LineStockRow[];
  } | null {
    if (!item.product_id || !lineStockLoaded || lineStockFailed) return null;

    const stock = lineLocationStock[item.product_id] ?? [];
    const arrivals = lineStockArrivals[item.product_id] ?? {};
    const byLocation = new Map<string, number>();
    for (const row of stock) {
      byLocation.set(
        row.location_id,
        (byLocation.get(row.location_id) ?? 0) + row.available
      );
    }
    const visible = stores.filter(
      (s) => s.location_type !== "WAREHOUSE_QUARANTINE"
    );
    const toRow = (s: Store): LineStockRow => ({
      id: s.id,
      name: s.name,
      available: byLocation.get(s.id) ?? 0,
      arriving: arrivals[s.id] ?? 0,
    });

    const isPickup =
      (item.fulfillment_type_override ?? journey.fulfillment_type) ===
      "pickup";
    const primaryId = resolveLineItemLocation(item, journey, stores);
    const all = visible.map(toRow);
    const primary = all.find((r) => r.id === primaryId) ?? null;
    const others = all
      .filter((r) => r.id !== primaryId)
      .sort(
        (a, b) => b.available - a.available || a.name.localeCompare(b.name)
      );

    return {
      primary,
      primaryLabel: isPickup ? "Pickup store" : "Warehouse",
      others,
    };
  }

  async function addLineItem(selection: ProductSelection) {
    setPanelError(null);
    try {
      const unitPrice = selection.salePrice ?? selection.price ?? 0;

      // EB-2c add-on warnings on an open exchange child — inform, never
      // block. The refund_owed figure IS the unconsumed credit left.
      if (exchangeChildOpen && exchangeAction) {
        const warnings: string[] = [];
        const creditLeftCents = exchangeAction.refund_owed_cents ?? 0;
        // A2: what the customer will owe AFTER this add — the part of the
        // add-on the credit can't absorb becomes new price; anything
        // already paid counts against it. Whole cents only.
        const addOnCents = Math.round(unitPrice * 100);
        const uncoveredAddOnCents = Math.max(
          0,
          addOnCents - creditLeftCents
        );
        const newPriceCents =
          Math.round((journey.price ?? 0) * 100) + uncoveredAddOnCents;
        const paidCents = Math.round(paid * 100);
        const owedCents = Math.max(0, newPriceCents - paidCents);
        if (owedCents > 0) {
          // The mattress hold is only released when the child was fully
          // covered before this add (Sold at $0 or fully paid). An already
          // unpaid child has no hold to lose.
          const holdInPlace = paidCents >= Math.round((journey.price ?? 0) * 100);
          warnings.push(
            holdInPlace && uncoveredAddOnCents > 0
              ? `This is more than the credit left. The customer will owe $${(
                  owedCents / 100
                ).toFixed(2)}, and the mattress hold is released until they pay.`
              : `The customer will owe $${(owedCents / 100).toFixed(2)}.`
          );
        }
        if (selection.productId) {
          try {
            const stock = await fetchProductStock(
              [selection.productId],
              inventoryStoreId
            );
            if ((stock[selection.productId]?.ats ?? 0) <= 0) {
              warnings.push(
                "This item is not in stock. It will hold the delivery until stock arrives."
              );
            }
          } catch {
            // Stock lookup failed — don't block the add on a display query.
          }
        }
        if (warnings.length > 0) {
          setPendingAddOn({ selection, unitPrice, warnings });
          return;
        }
      }

      await doAddLineItem(selection, unitPrice);
    } catch (e: any) {
      setPanelError(e.message ?? "Failed to add item");
    }
  }

  async function doAddLineItem(selection: ProductSelection, unitPrice: number) {
    setPanelError(null);
    try {
      await createJourneyLineItem({
        journey_id: journey.id,
        product_id: selection.productId,
        item_name: selection.productSummary,
        quantity: 1,
        unit_price: unitPrice,
      });
      handlePanelRefresh();
    } catch (e: any) {
      setPanelError(e.message ?? "Failed to add item");
    }
  }

  async function updateLineItem(
    id: string,
    updates: {
      quantity?: number;
      unit_price?: number;
      fulfillment_type_override?: "delivery" | "pickup" | null;
      pickup_location_id?: string | null;
    }
  ) {
    setPanelError(null);
    try {
      await updateJourneyLineItem(id, updates);
      handlePanelRefresh();
    } catch (e: any) {
      setPanelError(e.message ?? "Failed to update item");
    }
  }

  async function removeLineItem(id: string) {
    if (lineItems.length === 1 && paid > 0) {
      setConfirmRemoveItem(id);
      return;
    }
    await doRemoveLineItem(id);
  }

  async function doRemoveLineItem(id: string) {
    setPanelError(null);
    try {
      await deleteJourneyLineItem(id);
      handlePanelRefresh();
    } catch (e: any) {
      setPanelError(e.message ?? "Failed to remove item");
    }
  }

  const lineTotal = lineItems.reduce((sum, item) => sum + item.quantity * item.unit_price, 0);

  // Once delivered, the order is historical fact — line items can't be
  // edited in place; the correct path is the Start Exchange flow.
  // An exchange child's flagged lines are RLS-locked for their whole life
  // (088) — changes happen through the exchange, never direct edits.
  // EB-2c: an exchange child's ORDINARY (non-flagged) lines are editable
  // while the exchange is open — COMMITTED and no refund recorded. The
  // flagged exchange lines themselves stay read-only in every state.
  const exchangeChildOpen =
    isExchangeChild &&
    exchangeAction?.status === "COMMITTED" &&
    exchangeAction.refund_recorded_at == null;
  const orderLocked =
    Boolean(journey.delivered_at) ||
    Boolean(journey.cancelled_at) ||
    (isExchangeChild && !exchangeChildOpen) ||
    ["Sleep Trial", "Completed"].includes(journey.current_state);

  async function markFollowUpComplete(id: string) {
    setPanelError(null);
    try {
      await completeFollowUp(id);
      handlePanelRefresh();
    } catch (e: any) {
      setPanelError(e.message ?? "Failed to complete follow-up");
    }
  }

  async function handleReconcileEvent(paymentEventId: string, newOutcome: PaymentOutcome) {
    setPanelError(null);
    try {
      await reconcilePayment(paymentEventId, newOutcome);
      handlePanelRefresh();
    } catch (e: any) {
      setPanelError(e.message ?? "Reconciliation failed");
    }
  }

  const panelDirty =
    (reassignMode !== null &&
      reassignMode !== "choose" &&
      (reassignTarget !== "" || reassignReason.trim() !== "")) ||
    (shipToOpen && shipToNewDirty) ||
    activityState.dirty;
  const panelSaving =
    reassignSaving ||
    fulfillmentSaving ||
    shipToSaving ||
    activityState.saving;

  // Attention column: a short prioritized list of real signals, all
  // reads of existing data — overdue follow-up, unknown payment outcome,
  // pending exception (manager approval), trial ending within 7 days.
  const urgentTrial = mostUrgentEvaluation(trialEvals);
  const trialStatus = urgentTrial?.headline?.status;
  const today = new Date();
  today.setHours(0, 0, 0, 0);
  const followUpOverdue =
    nextFollowUp !== undefined && new Date(nextFollowUp.due_at) < today;
  const daysToTrialEnd = urgentTrial?.display.end_date
    ? Math.ceil(
        (new Date(`${urgentTrial.display.end_date}T00:00:00`).getTime() -
          today.getTime()) /
          86400000
      )
    : null;
  const attentionItems: AttentionItem[] = [];
  if (followUpOverdue) attentionItems.push({ text: "Follow-up overdue", tone: "red" });
  if (events.some((e) => e.outcome === "UNKNOWN"))
    attentionItems.push({ text: "Payment outcome unknown", tone: "red" });
  if (trialStatus === "APPROVAL_REQUIRED" || urgentTrial?.item?.pending_exception_id)
    attentionItems.push({ text: "Manager approval required", tone: "amber" });
  if (daysToTrialEnd !== null && daysToTrialEnd >= 0 && daysToTrialEnd <= 7)
    attentionItems.push({
      text: `Trial ends ${shortDate(urgentTrial!.display.end_date!)}`,
      tone: "amber",
    });

  // Journey-mismatch transfer stage for the header strip and Order card.
  // Furthest-along open stage wins; a finalized (arrived) transfer shows
  // nothing. Display only — no state changes.
  const nextScheduleLabel = (dow: number) => {
    const d = new Date();
    let add = (dow - d.getDay() + 7) % 7;
    if (add === 0) add = 7;
    d.setDate(d.getDate() + add);
    return d.toLocaleDateString(undefined, {
      weekday: "long",
      month: "short",
      day: "numeric",
    });
  };
  const transferNote = (() => {
    const open = journeyTransfers.filter(
      (r) =>
        !(
          r.status === "consolidated" &&
          r.transfers &&
          (r.transfers.finalized_at || r.transfers.status === "finalized")
        )
    );
    if (open.length === 0) return null;
    const row =
      open.find((r) => r.transfers?.status === "in_transit") ??
      open.find(
        (r) => r.status === "consolidated" && r.transfers && !r.transfers.in_transit_at
      ) ??
      open.find((r) => r.status !== "consolidated");
    if (!row) return null;
    const origin = stores.find((s) => s.id === row.origin_location_id);
    const dest = stores.find((s) => s.id === row.destination_location_id);
    if (row.transfers?.status === "in_transit") {
      return {
        kind: "shipped" as const,
        text: `In transit, shipped ${shortDate(
          (row.transfers.in_transit_at ?? "").slice(0, 10)
        )}`,
        requestId: row.id,
        destName: dest?.name ?? null,
      };
    }
    if (row.status === "consolidated" && row.transfers) {
      return {
        kind: "scheduled" as const,
        text: `Transfer scheduled ${shortDate(row.transfers.scheduled_date)} — ${
          origin?.name ?? "?"
        } to ${dest?.name ?? "?"}`,
        requestId: row.id,
        destName: dest?.name ?? null,
      };
    }
    let text = "Transfer requested. Date not set yet.";
    if (dest?.transfer_schedule_day != null) {
      text += ` Next transfer day: ${nextScheduleLabel(dest.transfer_schedule_day)}.`;
    }
    return {
      kind: "requested" as const,
      text,
      requestId: row.id,
      destName: dest?.name ?? null,
    };
  })();

  // Units assigned to this order but held at a different location.
  const remoteUnitsByVariant = (variantId: string, locationId: string) =>
    journeyUnits.filter(
      (u) =>
        u.requirement_id &&
        u.variant_id === variantId &&
        unitLocations[u.unit_id] &&
        unitLocations[u.unit_id] !== locationId
    );
  const remoteLocationNames = (variantId: string, locationId: string) =>
    Array.from(
      new Set(
        remoteUnitsByVariant(variantId, locationId).map(
          (u) =>
            stores.find((s) => s.id === unitLocations[u.unit_id])?.name ?? "another location"
        )
      )
    ).join(", ");

  // Secondary line under Current State — only where the spec defines one.
  const outstandingLines = lineItems.filter(
    (i) => i.product_id != null && (lineAvailability[i.id] ?? 0) < i.quantity
  );
  const remoteOutstanding = outstandingLines.filter(
    (i) =>
      i.product_id != null &&
      remoteUnitsByVariant(
        i.product_id,
        resolveLineItemLocation(i, journey, stores)
      ).length > 0
  ).length;
  const noStockCount = outstandingLines.length - remoteOutstanding;
  const stateDetail =
    journey.current_state === "Sleep Trial" &&
    urgentTrial?.display.night != null &&
    urgentTrial.display.length_nights != null
      ? `Night ${urgentTrial.display.night} of ${urgentTrial.display.length_nights}`
      : journey.current_state === "Waiting for Inventory" &&
        outstandingLines.length > 0
      ? [
          remoteOutstanding > 0
            ? `${remoteOutstanding} item${remoteOutstanding === 1 ? "" : "s"} at another location`
            : null,
          noStockCount > 0
            ? `${noStockCount} item${noStockCount === 1 ? "" : "s"} not in stock`
            : null,
        ]
          .filter(Boolean)
          .join(" · ")
      : null;

  // Rarely used / destructive actions live in the header "..." menu.
  const menuItems: MenuItem[] = [
    ...(canReassign && !journey.cancelled_at
      ? [{ label: "Reassign", onSelect: () => openReassign("choose") }]
      : []),
    ...(journey.current_state !== "Completed" && !journey.cancelled_at
      ? isExchangeChild
        ? [
            {
              label:
                "Cancel this from the exchange on the original journey",
              disabled: true,
              onSelect: () => {},
            },
          ]
        : hasLiveExchange
        ? [
            {
              label: "Cancel Journey…",
              danger: true,
              onSelect: () => setExchangeBlockNoticeOpen(true),
            },
          ]
        : [
            {
              label: "Cancel Journey…",
              danger: true,
              onSelect: () => onCancel(journey),
            },
          ]
      : []),
  ];

  return (
    <Modal
      onClose={onClose}
      overlayClassName="fixed inset-0 z-40 flex justify-end bg-slate-900/50 p-0"
      dirty={panelDirty}
      saving={panelSaving}
    >
      <div className="w-full overflow-y-auto border-l border-slate-200 bg-white shadow-lg min-[900px]:w-[90vw] min-[1280px]:w-[min(72vw,1200px)]">
        <div className="sticky top-0 z-10 border-b border-slate-200 bg-white px-6 pt-4 pb-3">
          <JourneyWorkspaceHeader
            journey={journey}
            exchangeParent={exchangeParent}
            exchangeAction={exchangeAction}
            onOpenParent={() => {
              if (exchangeParent) {
                router.push(`/board?journey=${exchangeParent.parent_journey_id}`);
              }
            }}
            onClose={onClose}
            menuItems={menuItems}
          />
          <JourneyStateSummaryBar
            journey={journey}
            nextFollowUp={nextFollowUp}
            stateDetail={stateDetail}
            transferNote={transferNote}
            attentionItems={attentionItems}
            transitions={panelTransitions}
            exchangeAwaitingPayment={exchangeAwaitingPayment}
            paymentSettled={paymentSettled}
            refreshPending={refreshPending}
            onAction={onAction}
          />
          {panelError && (
            <p key="panel-error" role="alert" className="mt-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
              {panelError}
            </p>
          )}
        </div>

        <div className="grid grid-cols-1 gap-6 p-6 min-[900px]:grid-cols-[3fr_2fr]">
          <div className="min-w-0">
            <div className="space-y-3 text-sm">
              {journey.inventory_ready_notified_at &&
                INVENTORY_READY_STATES.has(journey.current_state) && (
                <div className="rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm font-medium text-emerald-800">
                  Inventory ready
                </div>
              )}

              {completionDone && (
                <div className="rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm font-medium text-emerald-800">
                  {completionDone}
                </div>
              )}

              {(journey.delivered_at ||
                journey.current_state === "Sleep Trial" ||
                (liveTrialStatuses ?? []).some((s) =>
                  ["ACTIVE", "EXCHANGE_IN_PROGRESS", "RETURN_IN_PROGRESS"].includes(s)
                )) && (
                <SleepTrialSection
                  journey={journey}
                  currentEmployee={currentEmployee}
                  canModerate={canReconcile}
                  onChanged={handlePanelRefresh}
                  followUps={followUps}
                />
              )}
            </div>

            {nextFollowUp && (
              <div className="mt-4 rounded-md border border-amber-200 bg-amber-50 p-3">
                <h3 className="text-xs font-semibold uppercase text-amber-700">Next recommended action</h3>
                <p className="mt-1 text-sm text-slate-800">{followUpLabel(nextFollowUp)}</p>
                <p className="text-xs text-slate-500">
                  Due {new Date(nextFollowUp.due_at).toLocaleString()}
                  {nextFollowUp.method
                    ? ` · ${FOLLOW_UP_METHOD_LABELS[nextFollowUp.method] ?? nextFollowUp.method}`
                    : ""}
                </p>
                <button
                  onClick={() => markFollowUpComplete(nextFollowUp.id)}
                  className="mt-2 inline-flex items-center gap-1 rounded-md bg-white px-2 py-1 text-xs font-medium text-slate-700 border border-slate-200 hover:bg-slate-50"
                >
                  <Check className="h-3 w-3" /> Mark complete
                </button>
              </div>
            )}

            <div className="mt-6">
              {journey.cancelled_at && (
                <p className="mb-3 text-sm text-slate-500">
                  {isExchangeChild
                    ? "This exchange was cancelled."
                    : "This journey was cancelled."}
                </p>
              )}
              <div className="flex flex-wrap gap-2">
                {panelTransitions
                  .filter((t) => t.event !== "delivery_completed")
                  .filter(
                    (t) => t.event !== "payment_completed" || paymentAllowed
                  )
                  .filter(
                    (t) => !(t.event === "trial_completed" && hasLiveExchange)
                  )
                  .map((t) => (
                  <button
                    key={t.event}
                    disabled={refreshPending}
                    onClick={() => onAction(journey, t.event)}
                    className="rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                  >
                    {t.label}
                  </button>
                ))}
                {completionTransition && completionDecision && (
                  completionDecision.kind === "button" ? (
                    <button
                      disabled={refreshPending}
                      onClick={() => onAction(journey, "delivery_completed")}
                      className="rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                    >
                      {completionTransition.label}
                    </button>
                  ) : completionDecision.kind === "note" ? (
                    <p className="w-full text-sm text-slate-600">
                      {completionDecision.text}
                    </p>
                  ) : null
                )}
                {hasLiveExchange &&
                  transitions.some((t) => t.event === "trial_completed") && (
                    <p className="w-full text-sm text-slate-600">
                      Exchange in progress. The sleep trial cannot be
                      completed until the exchange is cancelled or
                      completed.
                    </p>
                  )}
              </div>
            </div>

            <JourneyActivity
              key={journey.id}
              journey={journey}
              events={events}
              followUps={followUps}
              employees={employees}
              stores={stores}
              currentEmployee={currentEmployee}
              canModerate={canReconcile}
              onChanged={handlePanelRefresh}
              refreshKey={activityRefreshKey}
              onDirtyChange={setActivityState}
            />

            {events.some((e) => e.outcome === "UNKNOWN") && canReconcile && (
              <div className="mt-4 rounded-md border border-amber-200 bg-amber-50 p-3">
                <h3 className="text-xs font-semibold uppercase text-amber-700">
                  Unresolved payments
                </h3>
                {events
                  .filter((e) => e.outcome === "UNKNOWN")
                  .map((e) => (
                    <div key={e.id} className="mt-2 flex items-center justify-between gap-2 text-sm">
                      <span className="text-slate-700">{formatHistoryEntry(e).title}</span>
                      <div className="flex gap-2">
                        <button
                          onClick={() => handleReconcileEvent(e.id, "SUCCEEDED")}
                          className="rounded bg-green-600 px-2 py-1 text-xs font-medium text-white hover:bg-green-700"
                        >
                          Mark succeeded
                        </button>
                        <button
                          onClick={() => handleReconcileEvent(e.id, "FAILED")}
                          className="rounded bg-red-600 px-2 py-1 text-xs font-medium text-white hover:bg-red-700"
                        >
                          Mark failed
                        </button>
                      </div>
                    </div>
                  ))}
              </div>
            )}
          </div>

          <aside className="min-w-0 divide-y divide-slate-200">
            <RailCard title="Customer">
              <p className="text-lg font-semibold text-slate-900">
                <span className="sr-only">Name: </span>
                {journey.customer
                  ? `${journey.customer.first_name} ${journey.customer.last_name}`
                  : "Unknown"}
              </p>
              {journey.customer?.phone && (
                <p className="mt-0.5 text-base font-medium text-slate-800">
                  <span className="sr-only">Phone: </span>
                  {formatPhone(journey.customer.phone)}
                </p>
              )}
              {journey.customer?.phone2 && (
                <p className="mt-0.5 text-sm text-slate-500">
                  Second: {formatPhone(journey.customer.phone2)}
                </p>
              )}
              {journey.customer?.email && (
                <p className="mt-0.5 text-sm text-slate-600">
                  <span className="sr-only">Email: </span>
                  {journey.customer.email}
                </p>
              )}
              {customerContacts.length > 0 && (
                <div className="mt-2 text-sm text-slate-600">
                  {customerContacts.map((c) => (
                    <p key={c.id}>
                      <span className="sr-only">Additional contact: </span>
                      {c.name}
                      {c.role_label ? ` · ${c.role_label}` : ""}
                      {c.phone ? ` · ${formatPhone(c.phone)}` : ""}
                    </p>
                  ))}
                </div>
              )}
              {customerAddress ? (
                <p className="mt-0.5 text-sm text-slate-600">
                  <span className="sr-only">Address: </span>
                  {customerAddress}
                </p>
              ) : (
                <p className="mt-0.5 text-sm text-slate-500">No address on file</p>
              )}
              {journey.customer && !shipToLocked && (
                <button
                  onClick={() => openShipToChooser()}
                  className="mt-1.5 text-xs text-brand-600 hover:text-brand-700"
                >
                  Change Delivery Address
                </button>
              )}
            </RailCard>

            <RailCard title="Order">
              <div className="mb-1 flex items-center justify-between">
                <span className="text-xs text-slate-500">{lineItems.length} item{lineItems.length === 1 ? "" : "s"}</span>
                {!orderLocked && (
                  <button
                    onClick={() => setOrderEditing((o) => !o)}
                    className="text-xs font-medium text-brand-600 hover:text-brand-700"
                  >
                    {orderEditing ? "Done editing" : "Edit order"}
                  </button>
                )}
              </div>

              {lineItemsLoading && !lineItemsLoaded && (
                <p className="text-sm text-slate-500">Loading items…</p>
              )}

              {lineItemsLoaded && lineItems.length === 0 && (
                <p className="text-sm text-slate-500">No items on this journey.</p>
              )}

              {lineItemsLoaded && lineItems.length === 0 && !orderLocked && (
                <ProductPicker storeId={inventoryStoreId} onSelect={addLineItem} />
              )}

              {lineItems.length > 0 && !orderEditing && (
                <div className="divide-y divide-slate-100">
                  {lineItems.map((item) => (
                    <div key={item.id} className="py-1.5">
                      <div className="leading-snug text-slate-900">
                        {item.item_name}
                        {(item.exchange_line_role || item.exchange_action_id) && (
                          <span className="ml-1.5 text-xs font-normal text-slate-400">
                            · Part of the exchange
                          </span>
                        )}
                      </div>
                      {!orderLocked &&
                        item.product_id &&
                        (lineAvailabilityFailed[item.id] ||
                          (lineAvailability[item.id] ?? 0) < item.quantity) && (
                          <div className="mt-0.5 text-xs text-slate-500">
                            {lineAvailabilityFailed[item.id]
                              ? "Availability unavailable"
                              : `Availability: ${lineAvailability[item.id] ?? "Loading…"}`}
                          </div>
                        )}
                      <div className="mt-0.5 text-xs text-slate-500">
                        Qty {item.quantity} · ${item.unit_price.toFixed(2)}
                      </div>
                      {(() => {
                        const handed =
                          fulfillmentSummary?.byLine[item.id] ?? 0;
                        if (handed === 0) return null;
                        return (
                          <span className="mt-0.5 inline-block rounded border border-slate-300 bg-slate-100 px-1.5 py-0.5 text-[10px] font-medium text-slate-600">
                            {handed < item.quantity
                              ? `Out ${handed} of ${item.quantity}`
                              : "Out"}
                          </span>
                        );
                      })()}
                      {/* Two lines with the same product share one
                          requirement, so both lines show that product's
                          chips here. */}
                      {item.product_id &&
                        journeyUnits.some(
                          (u) =>
                            u.requirement_id && u.variant_id === item.product_id
                        ) && (
                          <div className="mt-1 flex flex-wrap gap-1">
                            {journeyUnits
                              .filter(
                                (u) =>
                                  u.requirement_id &&
                                  u.variant_id === item.product_id
                              )
                              .map((u) => (
                                <span
                                  key={u.unit_id}
                                  title={u.status}
                                  className="rounded border border-indigo-200 bg-indigo-50 px-1.5 py-0.5 font-mono text-[10px] text-indigo-700"
                                >
                                  Unit {u.unit_number}
                                </span>
                              ))}
                          </div>
                        )}
                      {item.product_id &&
                        (() => {
                          const loc = resolveLineItemLocation(item, journey, stores);
                          const remote = remoteUnitsByVariant(item.product_id, loc);
                          if (remote.length === 0) return null;
                          return (
                            <div className="mt-0.5 text-xs font-medium text-amber-700">
                              {remote.length} unit{remote.length === 1 ? "" : "s"} reserved
                              at {remoteLocationNames(item.product_id, loc)}
                            </div>
                          );
                        })()}
                    </div>
                  ))}
                </div>
              )}

              {fulfillmentReadFailed && (
                <div className="mt-2 text-xs text-slate-500">
                  Item status could not be loaded.
                </div>
              )}
              {!fulfillmentReadFailed &&
                totalHanded > 0 &&
                !journey.delivered_at && (
                  <div className="mt-2 text-xs text-slate-500">
                    {totalHanded} of {totalUnits(lineItems)} items out.
                  </div>
                )}

              {pickupDecision?.kind === "button" && (
                <button
                  type="button"
                  onClick={() =>
                    onAction(journey, "delivery_completed", {
                      fulfillmentMethod: "pickup",
                    })
                  }
                  className="mt-2 rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
                >
                  Mark picked up
                </button>
              )}
              {pickupDecision?.kind === "note" && (
                <p className="mt-2 text-xs text-slate-500">
                  {pickupDecision.text}
                </p>
              )}

              {journeyUnits.some((u) => u.requirement_id === null) && (
                <div className="mt-2 text-xs text-slate-500">
                  <span className="font-medium text-slate-700">
                    Delivered units:
                  </span>{" "}
                  {journeyUnits
                    .filter((u) => u.requirement_id === null)
                    .map((u) => (
                      <span
                        key={u.unit_id}
                        title="Delivered"
                        className="mr-1 inline-block rounded border border-slate-300 bg-slate-100 px-1.5 py-0.5 font-mono text-[10px] text-slate-600"
                      >
                        Unit {u.unit_number}
                      </span>
                    ))}
                </div>
              )}

              {lineItems.length > 0 && orderEditing && !orderLocked && (
                <div className="space-y-2">
                  {lineItems.map((item) => (
                    <div
                      key={item.id}
                      className="rounded-md border border-slate-200 bg-slate-50 p-2 text-xs"
                    >
                      <div className="leading-snug text-slate-900">{item.item_name}</div>
                      {(item.exchange_line_role || item.exchange_action_id) && (
                        <div className="mt-0.5 text-slate-500">
                          Part of the exchange — change or cancel the exchange instead.
                        </div>
                      )}
                      {!(item.exchange_line_role || item.exchange_action_id) && item.product_id && (() => {
                        const bd = lineStockBreakdown(item);
                        if (!bd) {
                          return (
                            <div className="mt-0.5 text-slate-500">
                              {lineStockFailed
                                ? "Stock could not be loaded."
                                : "Loading…"}
                            </div>
                          );
                        }
                        return (
                          <div className="mt-0.5 space-y-0.5 text-slate-500">
                            {bd.primary && bd.primaryLabel && (
                              <div>
                                {bd.primaryLabel}: {bd.primary.name}{" "}
                                {lineStockCountText(bd.primary)}
                              </div>
                            )}
                            {bd.others.length > 0 && (
                              <button
                                type="button"
                                onClick={() => {
                                  setOtherStoresQuery("");
                                  setOtherStoresItemId(item.id);
                                }}
                                className="text-brand-700 hover:underline"
                              >
                                Check other stores ({bd.others.length})
                              </button>
                            )}
                          </div>
                        );
                      })()}
                      {!(item.exchange_line_role || item.exchange_action_id) && (
                      <div className="mt-1.5">
                      <div className="flex items-center gap-2">
                        <input
                          type="number"
                          min={1}
                          defaultValue={item.quantity}
                          onBlur={(e) => {
                            const handed =
                              fulfillmentSummary?.byLine[item.id] ?? 0;
                            const parsed = parseInt(e.target.value);
                            // m153: a line with units already handed over
                            // cannot go below that count. Say so and pin
                            // the field back to the floor instead of
                            // silently writing a different number.
                            if (
                              handed > 0 &&
                              (!Number.isFinite(parsed) || parsed < handed)
                            ) {
                              e.target.value = String(handed);
                              setLineQtyError({
                                itemId: item.id,
                                text: `Quantity cannot go below the number already out (${handed})`,
                              });
                              return;
                            }
                            setLineQtyError(null);
                            updateLineItem(item.id, {
                              quantity: Math.max(1, parsed || 1),
                            });
                          }}
                          className="w-12 rounded-md border border-slate-300 px-1 py-1 text-center text-xs focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                        />
                        <span className="text-slate-400">×</span>
                        <span className="text-slate-400">$</span>
                        <input
                          type="number"
                          min={0}
                          step="0.01"
                          defaultValue={item.unit_price.toFixed(2)}
                          onBlur={(e) =>
                            updateLineItem(item.id, { unit_price: parseFloat(e.target.value) || 0 })
                          }
                          className="w-20 rounded-md border border-slate-300 px-1 py-1 text-xs focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                        />
                        <div className="ml-auto whitespace-nowrap text-slate-600">
                          ${(item.quantity * item.unit_price).toFixed(2)}
                        </div>
                        <button
                          onClick={() => removeLineItem(item.id)}
                          className="rounded p-1 text-slate-400 hover:bg-red-100 hover:text-red-600"
                          aria-label="Remove"
                        >
                          <Trash2 className="h-3 w-3" />
                        </button>
                      </div>
                      {lineQtyError?.itemId === item.id && (
                        <p className="mt-1 text-xs text-red-600">
                          {lineQtyError.text}
                        </p>
                      )}
                      </div>
                      )}
                      {!(item.exchange_line_role || item.exchange_action_id) &&
                        canReassign && (
                        <div className="mt-1.5 space-y-1">
                          <select
                            value={
                              explicitLineChoices[item.id] ??
                              item.fulfillment_type_override ??
                              journey.fulfillment_type
                            }
                            onChange={(e) => {
                              const choice = e.target.value as "delivery" | "pickup";
                              setExplicitLineChoices((m) => ({
                                ...m,
                                [item.id]: choice,
                              }));
                              const payload = lineItemFulfillmentPayload({
                                explicitChoice: choice,
                                pickupLocationId: item.pickup_location_id,
                                orderFulfillment: journey.fulfillment_type,
                              });
                              updateLineItem(item.id, {
                                fulfillment_type_override:
                                  payload.fulfillmentTypeOverride,
                                pickup_location_id: payload.pickupLocationId,
                              });
                            }}
                            className="w-full rounded border border-slate-300 bg-white px-1 py-1 text-xs"
                          >
                            <option value="delivery" disabled={!hasDeliveryAddress}>Delivery</option>
                            <option value="pickup">Pickup</option>
                          </select>
                          {/* Always mounted for the same reason as the
                              new-order form: conditional mount/unmount
                              could orphan the node when the DOM guard
                              skipped React's removeChild. Hidden and
                              disabled unless effectively pickup. */}
                          <select
                            value={item.pickup_location_id ?? journey.store_id}
                            disabled={
                              (explicitLineChoices[item.id] ??
                                item.fulfillment_type_override ??
                                journey.fulfillment_type) !== "pickup"
                            }
                            onChange={(e) => updateLineItem(item.id, {
                              // m032: pickup_location_id requires the
                              // line's own override to be 'pickup';
                              // the location pick itself is not an
                              // explicit fulfillment choice.
                              fulfillment_type_override: "pickup",
                              pickup_location_id: e.target.value,
                            })}
                            className={`w-full rounded border border-slate-300 bg-white px-1 py-1 text-xs${
                              (explicitLineChoices[item.id] ??
                                item.fulfillment_type_override ??
                                journey.fulfillment_type) === "pickup"
                                ? ""
                                : " hidden"
                            }`}
                            aria-hidden={
                              (explicitLineChoices[item.id] ??
                                item.fulfillment_type_override ??
                                journey.fulfillment_type) !== "pickup"
                            }
                          >
                            {stores.filter((s) => s.location_type !== "WAREHOUSE_QUARANTINE").map((s) => (
                              <option key={s.id} value={s.id}>{s.name}</option>
                            ))}
                          </select>
                        </div>
                      )}
                    </div>
                  ))}
                  <ProductPicker storeId={inventoryStoreId} onSelect={addLineItem} />
                </div>
              )}

              {journey.current_state === "Waiting for Inventory" && (
                <p className="mt-2 text-xs text-slate-500">Waiting for inventory</p>
              )}

              {transferNote && (
                <p className="mt-2 flex items-center gap-1.5 text-xs font-semibold text-amber-700">
                  <Truck className="h-3.5 w-3.5 shrink-0" aria-hidden />
                  <span>
                    {transferNote.text}
                    {transferNote.kind === "requested" && (
                      <>
                        {" "}
                        <Link href="/transfers" className="underline hover:text-amber-800">
                          View request
                        </Link>
                      </>
                    )}
                  </span>
                </p>
              )}

              <div className="mt-2 flex items-center justify-between">
                <span>
                  {orderLocked && lineItems.length > 0 && (
                    <span className="text-xs text-slate-500">
                      {journey.cancelled_at
                        ? "This journey was cancelled."
                        : isExchangeChild
                        ? exchangeAction?.refund_recorded_at
                          ? "A refund was already recorded. Void it first if the order needs to change."
                          : "This exchange is closed — its order lines can't be changed."
                        : "Delivered — use Start Exchange to change items."}
                    </span>
                  )}
                </span>
                <span className="text-sm font-medium text-slate-900">
                  Total: ${(journey.price ?? 0).toFixed(2)}
                </span>
              </div>
            </RailCard>

            <RailCard title="Financial">
              {(() => {
                const paymentUnknown = events.some((e) => e.outcome === "UNKNOWN");
                const paidInFull =
                  journey.price !== null &&
                  journey.price !== undefined &&
                  journey.price > 0 &&
                  paid >= journey.price;
                return (
                  <>
                    <p
                      className={`text-sm font-semibold ${
                        paymentUnknown
                          ? "text-amber-700"
                          : paidInFull
                          ? "text-green-700"
                          : "text-slate-900"
                      }`}
                    >
                      {journey.cancelled_at
                        ? "Cancelled"
                        : paymentUnknown
                        ? "Payment outcome unknown"
                        : journey.price === null || journey.price === undefined
                        ? "No price set"
                        : paidInFull
                        ? "Paid in full"
                        : journey.price === 0 && paid > 0
                        ? `No items on this order. $${paid.toFixed(2)} paid, shown as Credit due below.`
                        : paid > 0
                        ? `Deposit paid $${paid.toFixed(2)} of $${journey.price.toFixed(2)}`
                        : `Balance due $${(journey.price - paid).toFixed(2)}`}
                    </p>
                    <div className="mt-1">
                      {journey.price !== null && journey.price !== undefined && (
                        <RailRow label="Agreed price" align="right">
                          ${journey.price.toFixed(2)}
                        </RailRow>
                      )}
                      {journey.price !== null && journey.price !== undefined && (
                        <RailRow label="Paid" align="right">
                          ${paid.toFixed(2)}
                        </RailRow>
                      )}
                      {balance !== null && paid <= (journey.price ?? 0) && (
                        <RailRow label="Balance due" align="right">
                          <span className={balance > 0 ? "text-amber-600" : "text-green-600"}>
                            ${balance.toFixed(2)}
                          </span>
                        </RailRow>
                      )}
                      {journey.price !== null && journey.price !== undefined && paid > journey.price && (
                        <RailRow label="Credit due" align="right">
                          <span className="text-blue-600">
                            ${(paid - journey.price).toFixed(2)}
                          </span>
                        </RailRow>
                      )}
                    </div>
                    {exchangeRefundCents > 0 && (
                      <p className="mt-2 rounded-md border border-amber-200 bg-amber-50 px-2.5 py-1.5 text-xs font-medium text-amber-800">
                        Refund owed to customer: $
                        {(exchangeRefundCents / 100).toFixed(2)}. Issue it in
                        your payment system. PillowTop will record it in a
                        later update.
                      </p>
                    )}
                    {journey.price !== null &&
                      journey.price !== undefined &&
                      Math.round(paid * 100) >
                        Math.round(journey.price * 100) && (
                        <p className="mt-2 rounded-md border border-amber-200 bg-amber-50 px-2.5 py-1.5 text-xs font-medium text-amber-800">
                          The customer has paid $
                          {(
                            (Math.round(paid * 100) -
                              Math.round(journey.price * 100)) /
                            100
                          ).toFixed(2)}{" "}
                          more than the order total. Refund them in your
                          payment system, then record the refund here.
                        </p>
                      )}
                    {/* Inform, don't block: a cancelled journey with money
                        still on it owes the customer a refund. Suppressed
                        when an existing banner already says so (exchange
                        refund owed, or paid over the order total). */}
                    {journey.cancelled_at &&
                      paid > 0 &&
                      exchangeRefundCents <= 0 &&
                      !(
                        journey.price !== null &&
                        journey.price !== undefined &&
                        Math.round(paid * 100) > Math.round(journey.price * 100)
                      ) && (
                        <p className="mt-2 rounded-md border border-amber-200 bg-amber-50 px-2.5 py-1.5 text-xs font-medium text-amber-800">
                          The customer paid ${paid.toFixed(2)} on this
                          cancelled order. Refund them in your payment
                          system, then record the refund here.
                        </p>
                      )}
                    {balance !== null &&
                      balance > 0 &&
                      transitions.find((t) => t.event === "payment_completed") && (
                        <button
                          onClick={() => onAction(journey, "payment_completed")}
                          className="mt-2 w-full rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700"
                        >
                          {transitions.find((t) => t.event === "payment_completed")!.label}
                        </button>
                      )}
                  </>
                );
              })()}
            </RailCard>

            <RailCard title="Fulfillment">
              <p className="text-sm font-semibold text-slate-900">
                {journey.delivered_at
                  ? `Delivered ${shortDate(journey.delivered_at)}`
                  : scheduledDate
                  ? `Scheduled ${shortDate(scheduledDate)}`
                  : "Not yet scheduled"}
              </p>
              <div className="mt-1 text-sm text-slate-600">
                {/* Keyed wrappers: on lock/unlock React removes the whole
                    span, never a bare <select> or text node — a bare
                    select/text swap here crashed the reconciler. */}
                {canReassign && !orderLocked ? (
                  <span key="fulfillment-edit">
                    <select
                      value={journey.fulfillment_type}
                      disabled={fulfillmentSaving}
                      onChange={(e) =>
                        submitFulfillmentChange(e.target.value as "delivery" | "pickup")
                      }
                      className="rounded-md border border-slate-300 bg-white px-2 py-1 text-sm text-slate-700"
                    >
                      <option value="delivery" disabled={!hasDeliveryAddress}>Delivery</option>
                      <option value="pickup">Pickup</option>
                    </select>
                  </span>
                ) : (
                  <span key="fulfillment-read">
                    {journey.fulfillment_type === "pickup" ? "Pickup" : "Delivery"}
                  </span>
                )}
              </div>
              {journey.fulfillment_type === "pickup" && journey.store && (
                <p className="mt-0.5 text-xs text-slate-500">
                  {pickupCollectionLabel({
                    items: lineItems,
                    journeyFulfillment: journey.fulfillment_type,
                    journeyStoreId: journey.store_id,
                    storeName: (id) =>
                      stores.find((s) => s.id === id)?.name ??
                      (id === journey.store_id ? journey.store?.name ?? null : null),
                  }) ?? `Pickup at ${journey.store.name}`}
                </p>
              )}
              {journey.fulfillment_type === "delivery" && customerAddress && (
                <p className="mt-0.5 text-xs text-slate-500">{customerAddress}</p>
              )}
              <JourneyDelivery
                journey={journey}
                // Same path as every other panel action: refreshes the
                // journey AND bumps activityRefreshKey so the feed
                // shows interactions logged from the delivery card.
                onChanged={handlePanelRefresh}
                openBookingSignal={openBookingSignal}
              />
            </RailCard>

            <RailCard title="Ownership">
              <RailRow label="Store">{journey.store?.name ?? "—"}</RailRow>
              <RailRow label="Assigned">{journey.employee?.name ?? "—"}</RailRow>

              {canReassign && !journey.cancelled_at && reassignMode === null && (
                <button
                  onClick={() => setReassignMode("choose")}
                  className="mt-2 w-full rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
                >
                  Reassign
                </button>
              )}

              {canReassign && reassignMode !== null && (
                <div ref={reassignRef} className="scroll-mt-20" />
              )}

              {canReassign && reassignMode === "choose" && (
                <div className="mt-2 flex gap-2">
                  <button
                    onClick={() => openReassign("store")}
                    className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
                  >
                    Store
                  </button>
                  <button
                    onClick={() => openReassign("employee")}
                    className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
                  >
                    Employee
                  </button>
                  <button
                    onClick={closeReassign}
                    className="rounded-md px-2 py-1.5 text-sm text-slate-500 hover:bg-slate-100"
                  >
                    Cancel
                  </button>
                </div>
              )}

              {canReassign && (reassignMode === "store" || reassignMode === "employee") && (
                <div className="mt-2 space-y-2 rounded-md border border-slate-200 bg-slate-50 p-3">
                  <label className="block text-xs font-medium text-slate-700">
                    {reassignMode === "store" ? "New store" : "New employee"}
                  </label>
                  <select
                    value={reassignTarget}
                    onChange={(e) => setReassignTarget(e.target.value)}
                    className="w-full rounded-md border border-slate-300 bg-white px-2 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                  >
                    <option value="">
                      {reassignMode === "store" ? "Select a store" : "Select an employee"}
                    </option>
                    {(reassignMode === "store" ? storeOptions : employeeOptions).map((o) => (
                      <option key={o.id} value={o.id}>
                        {o.name}
                      </option>
                    ))}
                  </select>

                  {reassignMode === "employee" && employeeOptions.length === 0 && (
                    <p className="text-xs text-slate-500">
                      No other employees at {journey.store?.name ?? "this store"}.
                    </p>
                  )}

                  <textarea
                    value={reassignReason}
                    onChange={(e) => setReassignReason(e.target.value)}
                    placeholder="Reason (optional)"
                    rows={2}
                    className="w-full rounded-md border border-slate-300 px-2 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                  />

                  <div className="flex gap-2">
                    <button
                      onClick={submitReassign}
                      disabled={!reassignTarget || reassignSaving}
                      className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                    >
                      {reassignSaving ? "Saving…" : "Confirm"}
                    </button>
                    <button
                      onClick={closeReassign}
                      className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                    >
                      Cancel
                    </button>
                  </div>
                </div>
              )}

              {reassignments.length > 0 &&
                Date.now() - new Date(reassignments[0].created_at).getTime() <
                  7 * 86400000 && (
                  <p className="mt-1 text-xs text-slate-500">
                    Reassigned {shortDate(reassignments[0].created_at.slice(0, 10))}
                  </p>
                )}

              {reassignments.length > 0 && (
                <details className="mt-3 border-t border-slate-100 pt-2">
                  <summary className="cursor-pointer text-xs font-medium text-slate-500 hover:text-slate-700">
                    View reassignment history ({reassignments.length})
                  </summary>
                  <div className="mt-2 space-y-2">
                    {reassignments.map((r) => (
                      <div
                        key={r.id}
                        className="rounded-md border border-slate-200 bg-slate-50 p-2 text-sm"
                      >
                        <p className="font-medium text-slate-700">
                          {r.to_store_id ? "Store" : "Employee"}:{" "}
                          {r.to_store_id
                            ? `${r.from_store?.name ?? "—"} → ${r.to_store?.name ?? "—"}`
                            : `${r.from_employee?.name ?? "Unassigned"} → ${r.to_employee?.name ?? "—"}`}
                        </p>
                        {r.reason && <p className="text-xs text-slate-500">{r.reason}</p>}
                        <p className="text-xs text-slate-400">
                          {new Date(r.created_at).toLocaleString()} by {r.actor?.name ?? "Unknown"}
                        </p>
                      </div>
                    ))}
                  </div>
                </details>
              )}
            </RailCard>
          </aside>
        </div>

        {shipToOpen && journey.customer && (
          <Modal
            onClose={() => setShipToOpen(false)}
            dirty={shipToNewDirty}
            saving={shipToSaving}
            closeRequestRef={shipToCloseRef}
          >
            <div className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
              <h2 className="mb-4 text-lg font-semibold text-slate-900">Change Delivery Address</h2>
              {shipToLoading ? (
                <p className="text-sm text-slate-500">Loading…</p>
              ) : (
                <div className="space-y-3">
                  {customerHasPrimary && (
                    <label className="flex items-start gap-2 text-sm text-slate-700">
                      <input
                        type="radio"
                        name="ship-to"
                        checked={shipToMode === "primary"}
                        onChange={() => setShipToMode("primary")}
                        className="mt-1"
                      />
                      <span>
                        <span className="font-medium">Primary address</span>
                        <span className="block text-xs text-slate-500">
                          {[journey.customer.street_address, journey.customer.street_address_line_2]
                            .filter(Boolean)
                            .join(" ")}
                          {[
                            [journey.customer.city, journey.customer.state, journey.customer.zip_code]
                              .filter(Boolean)
                              .join(" "),
                          ]
                            .filter(Boolean)
                            .map((s) => `, ${s}`)
                            .join("")}
                          {primaryOpenOrders > 0 &&
                            ` · ${primaryOpenOrders} open order${primaryOpenOrders === 1 ? " ships" : "s ship"} here`}
                        </span>
                      </span>
                    </label>
                  )}
                  {customerHasPrimary && savedAddresses.map((a) => (
                    <label key={a.id} className="flex items-start gap-2 text-sm text-slate-700">
                      <input
                        type="radio"
                        name="ship-to"
                        checked={shipToMode === "saved" && shipToAddressId === a.id}
                        onChange={() => {
                          setShipToMode("saved");
                          setShipToAddressId(a.id);
                        }}
                        className="mt-1"
                      />
                      <span>
                        <span className="font-medium">
                          {a.label || "Saved address"}
                        </span>
                        <span className="block text-xs text-slate-500">
                          {[a.street_address, a.street_address_line_2]
                            .filter(Boolean)
                            .join(" ")}
                          {[
                            [a.city, a.state, a.zip_code].filter(Boolean).join(" "),
                          ]
                            .filter(Boolean)
                            .map((s) => `, ${s}`)
                            .join("")}
                          {(a.open_orders ?? 0) > 0 &&
                            ` · ${a.open_orders} open order${a.open_orders === 1 ? "" : "s"}`}
                        </span>
                      </span>
                    </label>
                  ))}
                  <label className="flex items-start gap-2 text-sm text-slate-700">
                    <input
                      type="radio"
                      name="ship-to"
                      checked={shipToMode === "new"}
                      onChange={() => setShipToMode("new")}
                      className="mt-1"
                    />
                    <span className="font-medium">
                      {customerHasPrimary ? "New address" : "Address (none on file yet)"}
                    </span>
                  </label>
                  {shipToMode === "new" && (
                    <div className="space-y-2 rounded-md border border-slate-200 bg-slate-50 p-3">
                      {customerHasPrimary && (
                        <input
                          value={shipToNew.label}
                          onChange={(e) => setShipToNew((a) => ({ ...a, label: e.target.value }))}
                          placeholder="Label (optional, e.g. Cabin)"
                          className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
                        />
                      )}
                      <input
                        value={shipToNew.street}
                        onChange={(e) => setShipToNew((a) => ({ ...a, street: e.target.value }))}
                        placeholder="Street address"
                        className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
                      />
                      <input
                        value={shipToNew.line2}
                        onChange={(e) => setShipToNew((a) => ({ ...a, line2: e.target.value }))}
                        placeholder="Address Line 2 (optional)"
                        className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
                      />
                      <div className="grid grid-cols-3 gap-2">
                        <input value={shipToNew.city} onChange={(e) => setShipToNew((a) => ({ ...a, city: e.target.value }))} placeholder="City" className="rounded-md border border-slate-300 px-3 py-2 text-sm" />
                        <input value={shipToNew.state} onChange={(e) => setShipToNew((a) => ({ ...a, state: e.target.value }))} placeholder="State" className="rounded-md border border-slate-300 px-3 py-2 text-sm" />
                        <input value={shipToNew.zip} onChange={(e) => setShipToNew((a) => ({ ...a, zip: e.target.value }))} placeholder="ZIP" className="rounded-md border border-slate-300 px-3 py-2 text-sm" />
                      </div>
                    </div>
                  )}
                  {panelError && (
                    <p key="shipto-error" role="alert" className="rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
                      {panelError}
                    </p>
                  )}
                  <div className="flex gap-2 pt-2">
                    <button onClick={saveShipTo} disabled={shipToSaving || shipToLoading} className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white disabled:opacity-50">{shipToSaving ? "Saving…" : "Save"}</button>
                    <button onClick={() => (shipToCloseRef.current ?? (() => setShipToOpen(false)))()} className="flex-1 rounded-md border border-slate-300 px-3 py-2 text-sm font-medium text-slate-700">Cancel</button>
                  </div>
                </div>
              )}
            </div>
          </Modal>
        )}

        {exchangeBlockNoticeOpen && (
          <Modal onClose={() => setExchangeBlockNoticeOpen(false)}>
            <div className="w-full max-w-sm rounded-lg bg-white p-5 shadow-xl">
              <p className="text-sm text-slate-700">
                This journey has an exchange in progress. Cancel the
                exchange first.
              </p>
              <div className="mt-4 flex justify-end">
                <button
                  onClick={() => setExchangeBlockNoticeOpen(false)}
                  className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
                >
                  OK
                </button>
              </div>
            </div>
          </Modal>
        )}

        {pendingAddOn && (
          <Modal onClose={() => setPendingAddOn(null)}>
            <div className="w-full max-w-sm rounded-lg bg-white p-5 shadow-xl">
              <h2 className="mb-2 text-sm font-semibold text-slate-900">
                Add {pendingAddOn.selection.productSummary}?
              </h2>
              <div className="space-y-2">
                {pendingAddOn.warnings.map((w) => (
                  <p
                    key={w}
                    className="rounded-md border border-amber-200 bg-amber-50 px-2.5 py-1.5 text-xs font-medium text-amber-800"
                  >
                    {w}
                  </p>
                ))}
              </div>
              <div className="mt-4 flex gap-2">
                <button
                  onClick={() => {
                    const p = pendingAddOn;
                    setPendingAddOn(null);
                    void doAddLineItem(p.selection, p.unitPrice);
                  }}
                  className="flex-1 rounded-md bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700"
                >
                  Add it anyway
                </button>
                <button
                  onClick={() => setPendingAddOn(null)}
                  className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
                >
                  Cancel
                </button>
              </div>
            </div>
          </Modal>
        )}

        {confirmFulfillment && (
          <ConfirmModal
            title="Change fulfillment?"
            message="Changing fulfillment will release and re-source inventory. Continue?"
            actionLabel="Change fulfillment"
            onCancel={() => setConfirmFulfillment(null)}
            onConfirm={() => {
              const v = confirmFulfillment;
              setConfirmFulfillment(null);
              doFulfillmentChange(v);
            }}
          />
        )}

        {confirmRemoveItem && (
          <ConfirmModal
            title="Remove item?"
            message={`Removing the last item leaves $${paid.toFixed(2)} paid with nothing to apply it to. Continue?`}
            actionLabel="Remove item"
            onCancel={() => setConfirmRemoveItem(null)}
            onConfirm={() => {
              const id = confirmRemoveItem;
              setConfirmRemoveItem(null);
              doRemoveLineItem(id);
            }}
          />
        )}

        {addressPromptOpen && (
          <Modal onClose={() => setAddressPromptOpen(false)}>
            <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
              <h2 className="mb-2 text-lg font-semibold text-slate-900">
                Address required
              </h2>
              <p className="mb-3 text-sm text-slate-600">
                Add a delivery address before selecting Delivery.
              </p>
              <div className="mt-4 flex gap-2">
                <button
                  onClick={() => {
                    setAddressPromptOpen(false);
                    openShipToChooser(true);
                  }}
                  className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700"
                >
                  Add address
                </button>
                <button
                  onClick={() => setAddressPromptOpen(false)}
                  className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                >
                  Cancel
                </button>
              </div>
            </div>
          </Modal>
        )}

        {otherStoresItemId && (() => {
          const item = lineItems.find((i) => i.id === otherStoresItemId);
          if (!item) return null;
          const bd = lineStockBreakdown(item);
          const q = otherStoresQuery.trim().toLowerCase();
          const rows = (bd?.others ?? []).filter((r) =>
            r.name.toLowerCase().includes(q)
          );
          return (
            <Modal onClose={() => {
              setOtherStoresItemId(null);
              setOtherStoresQuery("");
            }}>
              <div className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
                <h2 className="mb-4 text-lg font-semibold text-slate-900">
                  {item.item_name}
                </h2>
                {(bd?.others.length ?? 0) > 8 && (
                  <input
                    value={otherStoresQuery}
                    onChange={(e) => setOtherStoresQuery(e.target.value)}
                    placeholder="Filter stores"
                    className="mb-3 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
                  />
                )}
                <div className="max-h-80 space-y-1 overflow-y-auto">
                  {rows.map((r) => (
                    <div
                      key={r.id}
                      className="flex items-center justify-between text-sm"
                    >
                      <span className="text-slate-700">{r.name}</span>
                      <span className="text-slate-500">
                        {lineStockCountText(r)}
                      </span>
                    </div>
                  ))}
                  {rows.length === 0 && (
                    <p className="text-sm text-slate-500">No matching stores.</p>
                  )}
                </div>
                <div className="mt-4 flex justify-end">
                  <button
                    onClick={() => {
                      setOtherStoresItemId(null);
                      setOtherStoresQuery("");
                    }}
                    className="rounded-md border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                  >
                    Close
                  </button>
                </div>
              </div>
            </Modal>
          );
        })()}
      </div>
    </Modal>
  );
}
