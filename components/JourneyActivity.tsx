"use client";

import { useEffect, useId, useMemo, useState } from "react";
import { Pin, PinOff, Flag, Plus, MessageSquarePlus, CalendarPlus } from "lucide-react";
import {
  fetchJourneyInteractions,
  fetchCustomerContacts,
  createCustomerContact,
  recordJourneyInteraction,
  markInteractionEnteredInError,
  setInteractionImportance,
  scheduleInteractionFollowUp,
  quickTopicsForState,
  INTERACTION_TYPE_OPTIONS,
  INTERACTION_TYPE_LABELS,
  TOPIC_OPTIONS,
  TOPIC_LABELS,
  OUTCOME_OPTIONS,
  OUTCOME_LABELS,
  WAITING_ON_OPTIONS,
  WAITING_ON_LABELS,
  CUSTOMER_REQUEST_CATEGORIES,
  CALL_ATTEMPT_OUTCOMES,
  type CustomerContact,
  type JourneyInteraction,
  type InteractionType,
  type InteractionTopic,
  type InteractionOutcome,
  type WaitingOn,
} from "@/lib/journeys/interactions";
import { localTodayISO } from "@/lib/dates";
import {
  FOLLOW_UP_METHOD_LABELS,
  FOLLOW_UP_TYPE_LABELS,
} from "@/lib/journeys/queries";
import Modal from "@/components/Modal";
import type {
  Employee,
  FollowUp,
  JourneyEvent,
  JourneyWithDetails,
} from "@/lib/journeys/queries";

// ============================================================
// Feed model: one chronological list merging system/domain events,
// employee-entered interactions, and follow-ups.
// ============================================================

type FeedItem =
  | { kind: "event"; at: string; event: JourneyEvent }
  | { kind: "interaction"; at: string; interaction: JourneyInteraction }
  | { kind: "follow_up"; at: string; followUp: FollowUp };

type FeedFilter =
  | "all"
  | "interactions"
  | "notes"
  | "orders"
  | "payments"
  | "fulfillment"
  | "sleep_trial"
  | "follow_ups";

const FILTERS: { value: FeedFilter; label: string }[] = [
  { value: "all", label: "All" },
  { value: "interactions", label: "Interactions" },
  { value: "notes", label: "Notes" },
  { value: "orders", label: "Orders" },
  { value: "payments", label: "Payments" },
  { value: "fulfillment", label: "Fulfillment" },
  { value: "sleep_trial", label: "Sleep Trial" },
  { value: "follow_ups", label: "Follow-Ups" },
];

function eventCategory(e: JourneyEvent): FeedFilter {
  switch (e.event_type) {
    case "deposit_received":
    case "payment_completed":
      return "payments";
    case "delivery_scheduled":
    case "delivery_completed":
      return "fulfillment";
    case "trial_completed":
      return "sleep_trial";
    default:
      return "orders";
  }
}

function interactionCategory(i: JourneyInteraction): FeedFilter {
  if (i.source_domain === "sleep_concern" || i.source_domain === "sleep_trial") {
    return "sleep_trial";
  }
  if (i.source_domain === "sleep_trial_exception") {
    return "sleep_trial";
  }
  return i.is_internal ? "notes" : "interactions";
}

function formatEventTitle(e: JourneyEvent): string {
  const data = e.event_data ?? {};
  if (e.event_type === "deposit_received" || e.event_type === "payment_completed") {
    const amount =
      typeof data.amount === "number" ? data.amount : parseFloat(String(data.amount ?? 0));
    const method = String(data.payment_method ?? "Unknown");
    return `Payment recorded: $${amount.toFixed(2)} via ${method}`;
  }
  switch (e.event_type) {
    case "quote_created":
      return "Quote created";
    case "quote_sent":
      return "Quote sent";
    case "delivery_scheduled":
      return `Delivery scheduled${data.delivery_date ? ` — ${data.delivery_date}` : ""}`;
    case "delivery_completed":
      return "Delivery completed";
    case "inventory_required":
      return "Moved to Waiting for Inventory";
    case "inventory_received":
      return "Inventory received — ready to schedule";
    case "trial_completed":
      return "Sleep trial completed";
    case "journey_cancelled":
      return `Journey cancelled${data.reason ? ` — ${data.reason}` : ""}`;
    case "line_item_added":
      return `Item added to order${data.item_name ? `: ${data.item_name}` : ""}`;
    case "line_item_updated":
      return `Item updated${data.item_name ? `: ${data.item_name}` : ""}`;
    case "line_item_removed":
      return `Item removed from order${data.item_name ? `: ${data.item_name}` : ""}`;
    default:
      return e.event_type;
  }
}

// Detail lines are whitelisted per event type — a type without an explicit
// formatter renders no detail at all. Raw event_data JSON must never be
// visible to an employee.
function eventDetail(e: JourneyEvent): string | undefined {
  const data = e.event_data ?? {};
  switch (e.event_type) {
    case "delivery_completed":
      return data.delivered_at
        ? `Delivered ${new Date(`${String(data.delivered_at)}T00:00:00`).toLocaleDateString()}`
        : undefined;
    case "line_item_added":
    case "line_item_updated":
    case "line_item_removed": {
      const qty = typeof data.quantity === "number" ? data.quantity : null;
      const price =
        typeof data.unit_price === "number" ? `$${data.unit_price.toFixed(2)}` : null;
      const parts = [
        qty !== null ? `Qty ${qty}` : null,
        price !== null ? `${price} each` : null,
      ].filter(Boolean);
      return parts.length > 0 ? parts.join(" · ") : undefined;
    }
    default:
      return undefined;
  }
}

// A pin is live only while important, not entered in error, and either
// permanent or unexpired (local date). Anything else behaves as unpinned.
function isActivelyPinned(i: JourneyInteraction): boolean {
  return (
    i.importance === "important" &&
    !i.entered_in_error_at &&
    (!i.pinned_until || i.pinned_until >= localTodayISO())
  );
}

// Shared pin-expiry choice — used by the feed's pin panel and the Log
// Interaction modal so the two can't drift apart. until=null means
// permanent. Past dates are blocked by min plus the caller's guard.
function PinExpiryOptions({
  until,
  onChange,
}: {
  until: string | null;
  onChange: (until: string | null) => void;
}) {
  const groupName = useId();
  const today = localTodayISO();
  return (
    <div className="flex flex-wrap items-center gap-2">
      <label className="flex items-center gap-1 text-[11px] text-slate-700">
        <input
          type="radio"
          name={groupName}
          checked={until === null}
          onChange={() => onChange(null)}
        />
        Permanently
      </label>
      <label className="flex items-center gap-1 text-[11px] text-slate-700">
        <input
          type="radio"
          name={groupName}
          checked={until !== null}
          onChange={() => onChange(today)}
        />
        Until
      </label>
      {until !== null && (
        <input
          type="date"
          value={until}
          min={today}
          onChange={(e) => onChange(e.target.value)}
          className="rounded border border-slate-300 bg-white px-1.5 py-0.5 text-[11px] text-slate-700"
        />
      )}
    </div>
  );
}

export default function JourneyActivity({
  journey,
  events,
  followUps,
  currentEmployee,
  canModerate,
  onChanged,
  refreshKey = 0,
  onDirtyChange,
}: {
  journey: JourneyWithDetails;
  events: JourneyEvent[];
  followUps: FollowUp[];
  currentEmployee: Employee | null;
  canModerate: boolean;
  onChanged: () => void;
  refreshKey?: number;
  onDirtyChange?: (state: { dirty: boolean; saving: boolean }) => void;
}) {
  const [interactions, setInteractions] = useState<JourneyInteraction[]>([]);
  const [contacts, setContacts] = useState<CustomerContact[]>([]);
  const [filter, setFilter] = useState<FeedFilter>("all");
  const [showAddUpdate, setShowAddUpdate] = useState(false);
  const [correcting, setCorrecting] = useState<JourneyInteraction | null>(null);
  const [pinTarget, setPinTarget] = useState<JourneyInteraction | null>(null);
  const [pinUntil, setPinUntil] = useState<string | null>(null);
  const [scheduleTarget, setScheduleTarget] = useState<JourneyInteraction | null>(null);
  const [scheduleDays, setScheduleDays] = useState("7");
  const [scheduleMethod, setScheduleMethod] = useState("call");
  const [scheduleNote, setScheduleNote] = useState("");
  const [scheduleKey, setScheduleKey] = useState("");
  const [scheduleSaving, setScheduleSaving] = useState(false);
  const [errorReason, setErrorReason] = useState<{
    interaction: JourneyInteraction;
    reason: string;
  } | null>(null);
  const [errorSaving, setErrorSaving] = useState(false);

  const customerId = journey.customer?.id ?? null;

  // Tell the parent panel when an inline form (pin, schedule
  // follow-up) holds unsaved input so the panel can guard closing.
  const inlineDirty =
    (pinTarget !== null && pinUntil !== null) ||
    (scheduleTarget !== null &&
      (scheduleNote.trim() !== "" ||
        scheduleDays !== "7" ||
        scheduleMethod !== "call"));

  useEffect(() => {
    onDirtyChange?.({ dirty: inlineDirty, saving: scheduleSaving });
  }, [inlineDirty, scheduleSaving, onDirtyChange]);

  useEffect(() => {
    fetchJourneyInteractions(journey.id).then(setInteractions);
    if (customerId) {
      fetchCustomerContacts(customerId).then(setContacts);
    }
  }, [journey.id, customerId, refreshKey]);

  const items = useMemo<FeedItem[]>(() => {
    const merged: FeedItem[] = [
      ...events.map((e) => ({ kind: "event" as const, at: e.created_at, event: e })),
      ...interactions.map((i) => ({
        kind: "interaction" as const,
        at: i.occurred_at,
        interaction: i,
      })),
      ...followUps.map((f) => ({
        kind: "follow_up" as const,
        at: f.due_at,
        followUp: f,
      })),
    ];
    merged.sort((a, b) => new Date(b.at).getTime() - new Date(a.at).getTime());
    return merged;
  }, [events, interactions, followUps]);

  const filtered = useMemo(() => {
    if (filter === "all") return items;
    return items.filter((item) => {
      if (item.kind === "event") return eventCategory(item.event) === filter;
      if (item.kind === "interaction")
        return interactionCategory(item.interaction) === filter;
      return filter === "follow_ups";
    });
  }, [items, filter]);

  const pinned = useMemo(
    () => interactions.filter(isActivelyPinned),
    [interactions]
  );

  const lastCustomerContact = useMemo(
    () =>
      interactions.find(
        (i) => !i.is_internal && !i.entered_in_error_at && i.source_domain === "manual"
      ),
    [interactions]
  );

  async function refresh() {
    const [fresh, freshContacts] = await Promise.all([
      fetchJourneyInteractions(journey.id),
      customerId ? fetchCustomerContacts(customerId) : Promise.resolve([]),
    ]);
    setInteractions(fresh);
    setContacts(freshContacts);
    onChanged();
  }

  async function pinInteraction(i: JourneyInteraction, until: string | null) {
    try {
      await setInteractionImportance(i.id, true, until);
      setPinTarget(null);
      setPinUntil(null);
      refresh();
    } catch (e: any) {
      window.alert(e.message ?? "Failed to pin");
    }
  }

  async function unpinInteraction(i: JourneyInteraction) {
    try {
      await setInteractionImportance(i.id, false, null);
      refresh();
    } catch (e: any) {
      window.alert(e.message ?? "Failed to unpin");
    }
  }

  function openSchedule(i: JourneyInteraction) {
    setScheduleTarget(i);
    setScheduleDays("7");
    setScheduleMethod("call");
    setScheduleNote("");
    // One key per open so a double-click or retry cannot create two
    // follow-ups.
    setScheduleKey(crypto.randomUUID());
  }

  async function saveSchedule() {
    if (!scheduleTarget) return;
    const days = parseInt(scheduleDays, 10);
    if (!(days > 0)) return;
    setScheduleSaving(true);
    try {
      await scheduleInteractionFollowUp({
        interaction_id: scheduleTarget.id,
        due_at: new Date(Date.now() + days * 86400000).toISOString(),
        method: scheduleMethod,
        notes: scheduleNote.trim() || null,
        idempotency_key: scheduleKey,
      });
      setScheduleTarget(null);
      refresh();
    } catch (e: any) {
      window.alert(e.message ?? "Failed to schedule follow-up");
    } finally {
      setScheduleSaving(false);
    }
  }

  async function submitEnteredInError() {
    if (!errorReason) return;
    setErrorSaving(true);
    try {
      await markInteractionEnteredInError(errorReason.interaction.id, errorReason.reason);
      setErrorReason(null);
      refresh();
    } catch (e: any) {
      window.alert(e.message ?? "Failed to mark entered in error");
    } finally {
      setErrorSaving(false);
    }
  }

  const quickTopics = quickTopicsForState(journey.current_state);

  return (
    <div className="mt-6">
      <div className="mb-2 flex items-center justify-between">
        <h3 className="text-sm font-semibold text-slate-900">Journey Activity</h3>
        <button
          onClick={() => setShowAddUpdate(true)}
          className="inline-flex items-center gap-1 rounded-md bg-brand-600 px-2.5 py-1.5 text-xs font-medium text-white hover:bg-brand-700"
        >
          <Plus className="h-3 w-3" /> Add Update
        </button>
      </div>

      {lastCustomerContact && (
        <p className="mb-2 text-xs text-slate-500">
          Last customer contact:{" "}
          {new Date(lastCustomerContact.occurred_at).toLocaleDateString()} —{" "}
          {INTERACTION_TYPE_LABELS[lastCustomerContact.interaction_type] ??
            lastCustomerContact.interaction_type}
          {lastCustomerContact.topic_label
            ? ` · ${lastCustomerContact.topic_label}`
            : lastCustomerContact.topic
            ? ` · ${TOPIC_LABELS[lastCustomerContact.topic] ?? lastCustomerContact.topic}`
            : ""}
        </p>
      )}

      {pinned.length > 0 && (
        <div className="mb-3 space-y-1">
          {pinned.map((i) => (
            <div
              key={i.id}
              className="rounded-md border border-amber-300 bg-amber-50 px-3 py-2 text-xs text-amber-900"
            >
              <span className="font-semibold uppercase">Important</span> — {i.summary}
              {i.pinned_until && (
                <span className="ml-1 font-normal">
                  (pinned until {new Date(`${i.pinned_until}T00:00:00`).toLocaleDateString()})
                </span>
              )}
            </div>
          ))}
        </div>
      )}

      <div className="mb-3 flex flex-wrap gap-1">
        {FILTERS.map((f) => (
          <button
            key={f.value}
            onClick={() => setFilter(f.value)}
            className={`rounded-full px-2.5 py-1 text-xs font-medium ${
              filter === f.value
                ? "bg-brand-600 text-white"
                : "bg-slate-100 text-slate-600 hover:bg-slate-200"
            }`}
          >
            {f.label}
          </button>
        ))}
      </div>

      <div className="space-y-2">
        {filtered.length === 0 && (
          <p className="text-sm text-slate-500">No activity yet.</p>
        )}

        {filtered.map((item) => {
          if (item.kind === "event") {
            const e = item.event;
            return (
              <div
                key={`e-${e.id}`}
                className="rounded-md border border-slate-200 bg-slate-50 p-2 text-sm"
              >
                <p className="font-medium text-slate-700">{formatEventTitle(e)}</p>
                {eventDetail(e) && (
                  <p className="text-xs text-slate-500">{eventDetail(e)}</p>
                )}
                <p className="text-xs text-slate-400">
                  {new Date(e.created_at).toLocaleString()} ·{" "}
                  {e.triggered_by === "system" ? "System" : "User"}
                </p>
              </div>
            );
          }

          if (item.kind === "follow_up") {
            const f = item.followUp;
            const overdue = !f.completed_at && new Date(f.due_at) < new Date();
            return (
              <div
                key={`f-${f.id}`}
                className={`rounded-md border p-2 text-sm ${
                  f.completed_at
                    ? "border-slate-200 bg-slate-50 text-slate-500"
                    : overdue
                    ? "border-red-200 bg-red-50"
                    : "border-amber-200 bg-amber-50"
                }`}
              >
                <p className="font-medium">
                  {f.type === "interaction"
                    ? "Follow-up"
                    : `${FOLLOW_UP_TYPE_LABELS[f.type] ?? f.type} follow-up`}
                  {f.completed_at
                    ? " — completed"
                    : overdue
                    ? " — overdue"
                    : " — due"}
                </p>
                {f.notes && <p className="text-xs">{f.notes}</p>}
                <p className="text-xs text-slate-500">
                  Due {new Date(f.due_at).toLocaleString()}
                  {f.method
                    ? ` · ${FOLLOW_UP_METHOD_LABELS[f.method] ?? f.method}`
                    : ""}
                  {f.completed_at
                    ? ` · Completed ${new Date(f.completed_at).toLocaleString()}`
                    : ""}
                </p>
              </div>
            );
          }

          const i = item.interaction;
          const isError = !!i.entered_in_error_at;
          const isConcern = i.source_domain === "sleep_concern";
          const isSystemSourced = i.source_domain !== "manual";
          return (
            <div
              key={`i-${i.id}`}
              className={`rounded-md border p-2 text-sm ${
                isError
                  ? "border-slate-200 bg-slate-50 opacity-60"
                  : isConcern
                  ? "border-teal-200 bg-teal-50"
                  : i.is_internal
                  ? "border-slate-200 bg-white"
                  : "border-blue-200 bg-blue-50"
              }`}
            >
              <div className="flex items-start justify-between gap-2">
                <p className="font-medium text-slate-800">
                  {isConcern
                    ? "Sleep Concern"
                    : INTERACTION_TYPE_LABELS[i.interaction_type] ?? i.interaction_type}
                  {i.topic_label ?? i.topic ? (
                    <span className="ml-1 font-normal text-slate-500">
                      · {i.topic_label ?? TOPIC_LABELS[i.topic!] ?? i.topic}
                    </span>
                  ) : null}
                </p>
                {isActivelyPinned(i) && (
                  <Pin className="h-3.5 w-3.5 shrink-0 text-amber-600" />
                )}
              </div>

              <p className={`mt-0.5 ${isError ? "line-through" : "text-slate-700"}`}>
                {i.summary}
              </p>

              {i.contact_name_snapshot && (
                <p className="text-xs text-slate-500">Spoke with: {i.contact_name_snapshot}</p>
              )}
              {i.request_category && (
                <p className="text-xs text-slate-500">Request: {i.request_category}</p>
              )}
              {i.commitment_made && (
                <p className="mt-0.5 text-xs font-medium text-amber-700">
                  Promised: {i.commitment_made}
                </p>
              )}
              <div className="mt-0.5 flex flex-wrap gap-x-3 text-xs text-slate-500">
                {i.outcome && <span>Outcome: {OUTCOME_LABELS[i.outcome] ?? i.outcome}</span>}
                {i.waiting_on && i.waiting_on !== "nothing" && (
                  <span>Waiting on: {WAITING_ON_LABELS[i.waiting_on] ?? i.waiting_on}</span>
                )}
                {i.correction_parent_id && <span>Correction of earlier entry</span>}
              </div>

              <p className="mt-1 text-xs text-slate-400">
                {new Date(i.occurred_at).toLocaleString()} ·{" "}
                {i.created_by?.name ?? (isSystemSourced ? "System" : "Unknown")}
                {isError &&
                  ` · Entered in error${
                    i.entered_in_error_reason ? `: ${i.entered_in_error_reason}` : ""
                  }`}
              </p>

              {!isError && i.source_domain === "manual" && (
                <div className="mt-1.5 flex flex-wrap gap-2">
                  {isActivelyPinned(i) ? (
                    <button
                      onClick={() => unpinInteraction(i)}
                      className="inline-flex items-center gap-1 whitespace-nowrap rounded border border-slate-200 bg-white px-1.5 py-0.5 text-[11px] text-slate-600 hover:bg-slate-50"
                    >
                      <PinOff className="h-3 w-3" /> Unpin
                    </button>
                  ) : (
                    <button
                      onClick={() => {
                        setPinTarget(i);
                        setPinUntil(null);
                      }}
                      className="inline-flex items-center gap-1 whitespace-nowrap rounded border border-slate-200 bg-white px-1.5 py-0.5 text-[11px] text-slate-600 hover:bg-slate-50"
                    >
                      <Pin className="h-3 w-3" /> Pin
                    </button>
                  )}
                  <button
                    onClick={() => setCorrecting(i)}
                    className="inline-flex items-center gap-1 whitespace-nowrap rounded border border-slate-200 bg-white px-1.5 py-0.5 text-[11px] text-slate-600 hover:bg-slate-50"
                  >
                    <MessageSquarePlus className="h-3 w-3" /> Correct
                  </button>
                  <button
                    onClick={() => openSchedule(i)}
                    className="inline-flex items-center gap-1 whitespace-nowrap rounded border border-slate-200 bg-white px-1.5 py-0.5 text-[11px] text-slate-600 hover:bg-slate-50"
                  >
                    <CalendarPlus className="h-3 w-3" /> Schedule follow-up
                  </button>
                  {(canModerate || i.created_by_employee_id === currentEmployee?.id) && (
                    <button
                      onClick={() => setErrorReason({ interaction: i, reason: "" })}
                      className="inline-flex items-center gap-1 whitespace-nowrap rounded border border-slate-200 bg-white px-1.5 py-0.5 text-[11px] text-slate-600 hover:bg-slate-50"
                    >
                      <Flag className="h-3 w-3" /> Entered in error
                    </button>
                  )}
                </div>
              )}

              {pinTarget?.id === i.id && (
                <div className="mt-1.5 flex flex-wrap items-center gap-2 rounded border border-amber-200 bg-amber-50 px-2 py-1.5">
                  <PinExpiryOptions until={pinUntil} onChange={setPinUntil} />
                  <button
                    onClick={() => pinInteraction(i, pinUntil)}
                    disabled={pinUntil !== null && pinUntil < localTodayISO()}
                    className="rounded bg-amber-600 px-2 py-0.5 text-[11px] font-medium text-white hover:bg-amber-700 disabled:opacity-50"
                  >
                    Pin
                  </button>
                  <button
                    onClick={() => setPinTarget(null)}
                    className="text-[11px] text-slate-500 hover:text-slate-700"
                  >
                    Cancel
                  </button>
                </div>
              )}

              {scheduleTarget?.id === i.id && (
                <div className="mt-1.5 rounded border border-amber-200 bg-amber-50 px-2 py-1.5">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="text-[11px] text-slate-600">In</span>
                    <input
                      type="number"
                      min={1}
                      value={scheduleDays}
                      onChange={(e) => setScheduleDays(e.target.value)}
                      className="w-14 rounded border border-slate-300 bg-white px-1.5 py-0.5 text-[11px]"
                    />
                    <span className="text-[11px] text-slate-600">days via</span>
                    <select
                      value={scheduleMethod}
                      onChange={(e) => setScheduleMethod(e.target.value)}
                      className="rounded border border-slate-300 bg-white px-1.5 py-0.5 text-[11px]"
                    >
                      <option value="call">Call</option>
                      <option value="text">Text</option>
                      <option value="email">Email</option>
                      <option value="in_person">In person</option>
                    </select>
                  </div>
                  <input
                    value={scheduleNote}
                    onChange={(e) => setScheduleNote(e.target.value)}
                    placeholder="Note (optional)"
                    className="mt-1.5 w-full rounded border border-slate-300 bg-white px-1.5 py-0.5 text-[11px]"
                  />
                  <div className="mt-1.5 flex gap-2">
                    <button
                      onClick={saveSchedule}
                      disabled={scheduleSaving || !(parseInt(scheduleDays, 10) > 0)}
                      className="rounded bg-amber-600 px-2 py-0.5 text-[11px] font-medium text-white hover:bg-amber-700 disabled:opacity-50"
                    >
                      {scheduleSaving ? "Saving…" : "Save"}
                    </button>
                    <button
                      onClick={() => setScheduleTarget(null)}
                      className="text-[11px] text-slate-500 hover:text-slate-700"
                    >
                      Cancel
                    </button>
                  </div>
                </div>
              )}
            </div>
          );
        })}
      </div>

      {showAddUpdate && (
        <AddUpdateModal
          journey={journey}
          contacts={contacts}
          quickTopics={quickTopics}
          onClose={() => setShowAddUpdate(false)}
          onSaved={() => {
            setShowAddUpdate(false);
            refresh();
          }}
        />
      )}

      {correcting && (
        <CorrectionModal
          journey={journey}
          original={correcting}
          onClose={() => setCorrecting(null)}
          onSaved={() => {
            setCorrecting(null);
            refresh();
          }}
        />
      )}

      {errorReason && (
        <Modal
          onClose={() => setErrorReason(null)}
          dirty={errorReason.reason.trim() !== ""}
          saving={errorSaving}
        >
          <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            <h2 className="mb-2 text-lg font-semibold text-slate-900">
              Mark entered in error
            </h2>
            <p className="mb-3 text-sm text-slate-600">
              The entry stays in history but is flagged and no longer treated as accurate.
            </p>
            <textarea
              value={errorReason.reason}
              onChange={(e) =>
                setErrorReason((prev) =>
                  prev ? { ...prev, reason: e.target.value } : null
                )
              }
              placeholder="Reason (optional)"
              rows={2}
              className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
            />
            <div className="mt-4 flex gap-2">
              <button
                onClick={submitEnteredInError}
                className="flex-1 rounded-md bg-red-600 px-3 py-2 text-sm font-medium text-white hover:bg-red-700"
              >
                Mark entered in error
              </button>
              <button
                onClick={() => setErrorReason(null)}
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

// ============================================================
// Add Update modal (source doc §12): seconds, not minutes.
// Communication → topic → what happened → what happens next.
// ============================================================

function AddUpdateModal({
  journey,
  contacts,
  quickTopics,
  onClose,
  onSaved,
}: {
  journey: JourneyWithDetails;
  contacts: CustomerContact[];
  quickTopics: { label: string; topic: InteractionTopic }[];
  onClose: () => void;
  onSaved: () => void;
}) {
  // Stable per-modal-open keys so a retry after a failure cannot
  // duplicate the interaction or its follow-up.
  const [keys] = useState(() => ({
    interaction: crypto.randomUUID(),
    followUp: crypto.randomUUID(),
  }));

  const [type, setType] = useState<InteractionType | null>(null);
  const [topic, setTopic] = useState<InteractionTopic | null>(null);
  const [topicLabel, setTopicLabel] = useState<string | null>(null);
  const [showAllTopics, setShowAllTopics] = useState(false);
  const [summary, setSummary] = useState("");
  const [outcome, setOutcome] = useState<InteractionOutcome | null>(null);
  const [callResult, setCallResult] = useState<
    (typeof CALL_ATTEMPT_OUTCOMES)[number] | null
  >(null);
  const [waitingOn, setWaitingOn] = useState<WaitingOn | null>(null);
  const [contactId, setContactId] = useState<string>("");
  const [requestCategory, setRequestCategory] = useState("");
  const [commitment, setCommitment] = useState("");
  const [nextAction, setNextAction] = useState<
    "nothing" | "follow_up" | "customer_will_contact" | "waiting_inventory" | "waiting_customer" | "manager_action"
  >("nothing");
  const [followUpDays, setFollowUpDays] = useState("7");
  const [followUpMethod, setFollowUpMethod] = useState("call");
  const [pin, setPin] = useState(false);
  const [pinUntilDate, setPinUntilDate] = useState<string | null>(null);
  const [addingContact, setAddingContact] = useState(false);
  const [newContact, setNewContact] = useState({ name: "", role: "", phone: "" });
  const [localContacts, setLocalContacts] = useState(contacts);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const customerId = journey.customer?.id;

  function applyCallAttempt(o: (typeof CALL_ATTEMPT_OUTCOMES)[number]) {
    if (callResult?.label === o.label) {
      setCallResult(null);
      if (outcome === o.outcome) setOutcome(null);
      if (o.summaryPrefix) {
        setSummary((s) =>
          s.startsWith(o.summaryPrefix)
            ? s.slice(o.summaryPrefix.length).trimStart()
            : s
        );
      }
      return;
    }
    setCallResult(o);
    setOutcome(o.outcome);
    setSummary((s) => {
      const prev = callResult?.summaryPrefix;
      const rest =
        prev && s.startsWith(prev) ? s.slice(prev.length).trimStart() : s;
      if (!o.summaryPrefix) return rest;
      return rest ? `${o.summaryPrefix} ${rest}` : o.summaryPrefix;
    });
  }

  function applyNextAction(v: typeof nextAction) {
    setNextAction(v);
    // "Follow-Up Needed" and the "Follow up" next action are linked:
    // moving away clears the outcome so the two can't disagree.
    if (v !== "follow_up" && outcome === "follow_up_needed") {
      setOutcome(null);
    }
    if (v === "customer_will_contact") {
      setOutcome("waiting_on_customer");
      setWaitingOn("customer");
    } else if (v === "waiting_inventory") {
      setOutcome("waiting_on_retailer");
      setWaitingOn("inventory");
    } else if (v === "waiting_customer") {
      setOutcome("waiting_on_customer");
      setWaitingOn("customer");
    } else if (v === "manager_action") {
      setOutcome("escalated");
      setWaitingOn("manager");
    } else if (v === "follow_up") {
      setOutcome("follow_up_needed");
    }
  }

  async function saveContact() {
    if (!customerId || !newContact.name.trim()) return;
    try {
      const created = await createCustomerContact({
        customer_id: customerId,
        name: newContact.name,
        role_label: newContact.role || null,
        phone: newContact.phone || null,
        is_delivery_contact: /delivery/i.test(newContact.role),
      });
      setLocalContacts((c) => [...c, created]);
      setContactId(created.id);
      setAddingContact(false);
      setNewContact({ name: "", role: "", phone: "" });
    } catch (e: any) {
      window.alert(e.message ?? "Failed to add contact");
    }
  }

  async function save() {
    if (!type || !summary.trim()) return;
    setSaving(true);
    setError(null);
    try {
      const days = parseInt(followUpDays, 10);
      const followUp =
        nextAction === "follow_up" && days > 0
          ? {
              due_at: new Date(Date.now() + days * 86400000).toISOString(),
              method: followUpMethod,
              notes: commitment.trim()
                ? `Promised: ${commitment.trim()}`
                : undefined,
              idempotency_key: keys.followUp,
            }
          : null;

      await recordJourneyInteraction({
        journey_id: journey.id,
        interaction_type: type,
        summary: summary.trim(),
        idempotency_key: keys.interaction,
        topic,
        topic_label: topic ? topicLabel : null,
        contact_id: contactId || null,
        outcome,
        waiting_on: waitingOn,
        commitment_made: commitment.trim() || null,
        request_category: type === "customer_request" ? requestCategory || null : null,
        is_internal: type === "internal_note",
        importance: pin ? "important" : "normal",
        pinned_until: pin ? pinUntilDate : null,
        follow_up: followUp,
      });
      onSaved();
    } catch (e: any) {
      setError(e.message ?? "Failed to save interaction");
    } finally {
      setSaving(false);
    }
  }

  const isInternal = type === "internal_note";

  const formDirty =
    type !== null ||
    topic !== null ||
    summary.trim() !== "" ||
    outcome !== null ||
    waitingOn !== null ||
    contactId !== "" ||
    requestCategory !== "" ||
    commitment.trim() !== "" ||
    nextAction !== "nothing" ||
    followUpDays !== "7" ||
    followUpMethod !== "call" ||
    pin ||
    addingContact;

  return (
    <Modal onClose={onClose} dirty={formDirty} saving={saving}>
      <div className="max-h-[90vh] w-full max-w-md overflow-y-auto rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
        <h2 className="mb-4 text-lg font-semibold text-slate-900">Log Interaction</h2>

        <p className="mb-1 text-xs font-medium uppercase text-slate-500">
          How did you communicate?
        </p>
        <div className="mb-4 flex flex-wrap gap-1.5">
          {INTERACTION_TYPE_OPTIONS.map((o) => (
            <button
              key={o.value}
              onClick={() => setType(o.value)}
              className={`rounded-full px-3 py-1.5 text-xs font-medium ${
                type === o.value
                  ? "bg-brand-600 text-white"
                  : "bg-slate-100 text-slate-700 hover:bg-slate-200"
              }`}
            >
              {o.label}
            </button>
          ))}
        </div>

        {type === "called_customer" && (
          <>
            <p className="mb-1 text-xs font-medium uppercase text-slate-500">
              Result
            </p>
            <div className="mb-4 flex flex-wrap gap-1.5">
              {CALL_ATTEMPT_OUTCOMES.map((o) => (
                <button
                  key={o.label}
                  onClick={() => applyCallAttempt(o)}
                  className={`rounded-full px-3 py-1.5 text-xs font-medium ${
                    callResult?.label === o.label
                      ? "bg-brand-600 text-white"
                      : "bg-slate-100 text-slate-700 hover:bg-slate-200"
                  }`}
                >
                  {o.label}
                </button>
              ))}
            </div>
          </>
        )}

        <p className="mb-1 text-xs font-medium uppercase text-slate-500">
          What was this about?
        </p>
        <div className="mb-2 flex flex-wrap gap-1.5">
          {quickTopics.map((o) => (
            <button
              key={o.label}
              onClick={() => {
                if (topic === o.topic && topicLabel === o.label) {
                  setTopic(null);
                  setTopicLabel(null);
                } else {
                  setTopic(o.topic);
                  setTopicLabel(o.label);
                }
              }}
              className={`rounded-full px-3 py-1.5 text-xs font-medium ${
                topic === o.topic && topicLabel === o.label
                  ? "bg-brand-600 text-white"
                  : "bg-slate-100 text-slate-700 hover:bg-slate-200"
              }`}
            >
              {o.label}
            </button>
          ))}
        </div>
        {!showAllTopics ? (
          <button
            onClick={() => setShowAllTopics(true)}
            className="mb-4 text-xs text-brand-600 hover:text-brand-700"
          >
            More topics…
          </button>
        ) : (
          <div className="mb-4 flex flex-wrap gap-1.5">
            {TOPIC_OPTIONS.map((o) => (
              <button
                key={o.value}
                onClick={() => {
                  if (topic === o.value && topicLabel === o.label) {
                    setTopic(null);
                    setTopicLabel(null);
                  } else {
                    setTopic(o.value);
                    setTopicLabel(o.label);
                  }
                }}
                className={`rounded-full px-3 py-1.5 text-xs font-medium ${
                  topic === o.value && topicLabel === o.label
                    ? "bg-brand-600 text-white"
                    : "bg-slate-100 text-slate-700 hover:bg-slate-200"
                }`}
              >
                {o.label}
              </button>
            ))}
          </div>
        )}

        {type === "customer_request" && (
          <div className="mb-4">
            <p className="mb-1 text-xs font-medium uppercase text-slate-500">
              Request category
            </p>
            <select
              value={requestCategory}
              onChange={(e) => setRequestCategory(e.target.value)}
              className="w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm"
            >
              <option value="">Select…</option>
              {CUSTOMER_REQUEST_CATEGORIES.map((c) => (
                <option key={c} value={c}>
                  {c}
                </option>
              ))}
            </select>
            <p className="mt-1 text-xs text-slate-500">
              Record what the customer asked for here — then make the actual
              change through the delivery, address, or order actions.
            </p>
          </div>
        )}

        {!isInternal && (
          <div className="mb-4">
            <p className="mb-1 text-xs font-medium uppercase text-slate-500">
              Spoke with
            </p>
            <div className="flex gap-2">
              <select
                value={contactId}
                onChange={(e) => setContactId(e.target.value)}
                className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm"
              >
                <option value="">
                  {journey.customer
                    ? `${journey.customer.first_name} ${journey.customer.last_name} (primary)`
                    : "Primary customer"}
                </option>
                {localContacts.map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.name}
                    {c.role_label ? ` — ${c.role_label}` : ""}
                  </option>
                ))}
              </select>
              <button
                onClick={() => setAddingContact((v) => !v)}
                className="rounded-md border border-slate-300 px-2 text-xs text-slate-600 hover:bg-slate-50"
              >
                + New
              </button>
            </div>
            {addingContact && (
              <div className="mt-2 space-y-2 rounded-md border border-slate-200 bg-slate-50 p-2">
                <input
                  value={newContact.name}
                  onChange={(e) => setNewContact((c) => ({ ...c, name: e.target.value }))}
                  placeholder="Contact name"
                  className="w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm"
                />
                <div className="flex gap-2">
                  <input
                    value={newContact.role}
                    onChange={(e) => setNewContact((c) => ({ ...c, role: e.target.value }))}
                    placeholder="Role (e.g. Delivery Contact)"
                    className="flex-1 rounded-md border border-slate-300 px-2 py-1.5 text-sm"
                  />
                  <input
                    value={newContact.phone}
                    onChange={(e) => setNewContact((c) => ({ ...c, phone: e.target.value }))}
                    placeholder="Phone"
                    className="w-28 rounded-md border border-slate-300 px-2 py-1.5 text-sm"
                  />
                </div>
                <button
                  onClick={saveContact}
                  disabled={!newContact.name.trim()}
                  className="rounded-md bg-brand-600 px-3 py-1.5 text-xs font-medium text-white disabled:opacity-50"
                >
                  Add contact
                </button>
              </div>
            )}
          </div>
        )}

        <p className="mb-1 text-xs font-medium uppercase text-slate-500">
          {isInternal ? "Note" : "What happened?"}
        </p>
        <textarea
          value={summary}
          onChange={(e) => setSummary(e.target.value)}
          rows={3}
          placeholder={
            isInternal
              ? "Record factual information relevant to serving the customer."
              : "What did the customer say? What were they told?"
          }
          className="mb-4 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
        />

        {!isInternal && (
          <div className="mb-4">
            <p className="mb-1 text-xs font-medium uppercase text-slate-500">
              Commitment made to customer? <span className="font-normal">(optional)</span>
            </p>
            <input
              value={commitment}
              onChange={(e) => setCommitment(e.target.value)}
              placeholder="e.g. Call when product arrives"
              className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
            />
          </div>
        )}

        <p className="mb-1 text-xs font-medium uppercase text-slate-500">
          What happens next?
        </p>
        <div className="mb-3 space-y-1">
          {(
            [
              ["nothing", "Nothing"],
              ["follow_up", "Follow up"],
              ["customer_will_contact", "Customer will contact us"],
              ["waiting_inventory", "Waiting on inventory"],
              ["waiting_customer", "Waiting on customer"],
              ["manager_action", "Manager action needed"],
            ] as const
          ).map(([v, label]) => (
            <label key={v} className="flex items-center gap-2 text-sm text-slate-700">
              <input
                type="radio"
                name="next_action"
                checked={nextAction === v}
                onChange={() => applyNextAction(v)}
              />
              {label}
            </label>
          ))}
        </div>

        {nextAction === "follow_up" && (
          <div className="mb-4 flex items-center gap-2 rounded-md border border-slate-200 bg-slate-50 p-2 text-sm">
            <span className="text-slate-600">In</span>
            <input
              type="number"
              min={1}
              value={followUpDays}
              onChange={(e) => setFollowUpDays(e.target.value)}
              className="w-16 rounded-md border border-slate-300 px-2 py-1 text-sm"
            />
            <span className="text-slate-600">days via</span>
            <select
              value={followUpMethod}
              onChange={(e) => setFollowUpMethod(e.target.value)}
              className="rounded-md border border-slate-300 bg-white px-2 py-1 text-sm"
            >
              <option value="call">Call</option>
              <option value="text">Text</option>
              <option value="email">Email</option>
              <option value="in_person">In person</option>
            </select>
          </div>
        )}

        <div className="mb-4 grid grid-cols-2 gap-2">
          <div>
            <p className="mb-1 text-xs font-medium uppercase text-slate-500">Outcome</p>
            <select
              value={outcome ?? ""}
              onChange={(e) => {
                const v = (e.target.value || null) as InteractionOutcome | null;
                setOutcome(v);
                if (v === "follow_up_needed") setNextAction("follow_up");
              }}
              className="w-full rounded-md border border-slate-300 bg-white px-2 py-1.5 text-sm"
            >
              <option value="">—</option>
              {OUTCOME_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </select>
          </div>
          <div>
            <p className="mb-1 text-xs font-medium uppercase text-slate-500">Waiting on</p>
            <select
              value={waitingOn ?? ""}
              onChange={(e) =>
                setWaitingOn((e.target.value || null) as WaitingOn | null)
              }
              className="w-full rounded-md border border-slate-300 bg-white px-2 py-1.5 text-sm"
            >
              <option value="">—</option>
              {WAITING_ON_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </select>
          </div>
        </div>

        <label className="mb-2 flex items-center gap-2 text-sm text-slate-700">
          <input type="checkbox" checked={pin} onChange={(e) => setPin(e.target.checked)} />
          Pin as important for this journey
        </label>
        {pin && (
          <div className="mb-4 ml-6">
            <PinExpiryOptions until={pinUntilDate} onChange={setPinUntilDate} />
          </div>
        )}

        {error && (
          <p className="mb-3 rounded-md border border-red-200 bg-red-50 p-2 text-sm text-red-700">
            {error}
          </p>
        )}

        <div className="flex gap-2">
          <button
            onClick={save}
            disabled={
              !type ||
              !summary.trim() ||
              saving ||
              (pin && pinUntilDate !== null && pinUntilDate < localTodayISO())
            }
            className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
          >
            {saving ? "Saving…" : "Save Interaction"}
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

// ============================================================
// Correction: a new entry linked to the original (source doc §40).
// The original stays; the correction clarifies it.
// ============================================================

function CorrectionModal({
  journey,
  original,
  onClose,
  onSaved,
}: {
  journey: JourneyWithDetails;
  original: JourneyInteraction;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [text, setText] = useState("");
  const [saving, setSaving] = useState(false);

  async function save() {
    if (!text.trim()) return;
    setSaving(true);
    try {
      await recordJourneyInteraction({
        journey_id: journey.id,
        interaction_type: "correction",
        summary: `Correction: ${text.trim()}`,
        idempotency_key: crypto.randomUUID(),
        topic: original.topic,
        topic_label: original.topic_label,
        correction_parent_id: original.id,
        is_internal: original.is_internal,
      });
      onSaved();
    } catch (e: any) {
      window.alert(e.message ?? "Failed to save correction");
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal onClose={onClose} dirty={text.trim() !== ""} saving={saving}>
      <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
        <h2 className="mb-2 text-lg font-semibold text-slate-900">Add correction</h2>
        <p className="mb-3 rounded-md bg-slate-50 p-2 text-xs text-slate-600">
          Original: {original.summary}
        </p>
        <textarea
          value={text}
          onChange={(e) => setText(e.target.value)}
          placeholder="e.g. Customer said Thursday, not Tuesday."
          rows={3}
          className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
        />
        <div className="mt-4 flex gap-2">
          <button
            onClick={save}
            disabled={!text.trim() || saving}
            className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white disabled:opacity-50"
          >
            {saving ? "Saving…" : "Save correction"}
          </button>
          <button
            onClick={onClose}
            className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700"
          >
            Cancel
          </button>
        </div>
      </div>
    </Modal>
  );
}
