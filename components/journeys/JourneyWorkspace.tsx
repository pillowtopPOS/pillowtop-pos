"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { Check, Trash2, X } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { resolveLineItemLocation } from "@/lib/journeys/fulfillment";
import { fetchProductStock } from "@/lib/inventory/queries";
import {
  completeFollowUp,
  createJourneyLineItem,
  deleteJourneyLineItem,
  fetchJourneyLineItems,
  reconcilePayment,
  reassignJourneyEmployee,
  reassignJourneyStore,
  updateCustomerAddress,
  updateJourneyFulfillment,
  updateJourneyLineItem,
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
  STATE_TRANSITIONS,
  type JourneyEventType,
} from "@/lib/journeys/state";
import {
  mostUrgentEvaluation,
  type SleepTrialEvaluation,
} from "@/lib/journeys/sleepTrial";
import Modal from "@/components/Modal";
import ProductPicker, { type ProductSelection } from "@/components/ProductPicker";
import JourneyActivity from "@/components/JourneyActivity";
import SleepTrialSection from "@/components/SleepTrialSection";

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

// The summary bar is a glance, not a transcript — never raw notes.
// "Follow-up: Call" (method only); "Follow-up" when no method is set.
function followUpCompactLabel(f: FollowUp): string {
  const method = f.method ? FOLLOW_UP_METHOD_LABELS[f.method] ?? f.method : null;
  return method ? `Follow-up: ${method}` : "Follow-up";
}

function formatHistoryEntry(e: JourneyEvent) {
  const data = e.event_data ?? {};
  if (
    e.event_type === "deposit_received" ||
    e.event_type === "payment_completed"
  ) {
    const amount =
      typeof data.amount === "number" ? data.amount : parseFloat(String(data.amount ?? 0));
    const method = String(data.payment_method ?? "Unknown");
    return {
      title: `Payment recorded: $${amount.toFixed(2)} via ${method}`,
      detail: undefined,
    };
  }
  return {
    title: e.event_type,
    detail: undefined,
  };
}

function JourneyWorkspaceHeader({
  journey,
  onClose,
}: {
  journey: JourneyWithDetails;
  onClose: () => void;
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
          {journey.cancelled_at && (
            <span className="rounded-full bg-red-100 px-2.5 py-0.5 text-xs font-medium text-red-700">
              Cancelled
            </span>
          )}
        </div>
        <p className="mt-0.5 truncate text-xs text-slate-500">
          {journey.store?.name ?? "—"}
          {journey.employee ? ` · ${journey.employee.name}` : ""}
          {journey.product_summary ? ` · ${journey.product_summary}` : ""}
        </p>
      </div>
      <button
        onClick={onClose}
        className="shrink-0 rounded-md p-1 text-slate-500 hover:bg-slate-100"
      >
        <X className="h-5 w-5" />
      </button>
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

function JourneyStateSummaryBar({
  journey,
  nextFollowUp,
  attention,
  transitions,
}: {
  journey: JourneyWithDetails;
  nextFollowUp: FollowUp | undefined;
  attention: string | null;
  transitions: { label: string; event: JourneyEventType }[];
}) {
  // trial_completed is excluded from the transition-label fallback on
  // purpose: the Sleep Trial → Completed transition is ungated, so
  // surfacing "Complete Trial" here would recommend ending a trial early
  // as the default next step on any night with no follow-up scheduled.
  const nextAction = nextFollowUp
    ? followUpCompactLabel(nextFollowUp)
    : transitions.find((t) => t.event !== "trial_completed")?.label || null;
  return (
    <div className="mt-3 grid grid-cols-3 divide-x divide-slate-200 rounded-md border border-slate-200 bg-slate-50">
      <SummaryCell label="Current State">
        <span className="inline-flex items-center gap-1.5">
          {journey.current_state}
          {journey.cancelled_at && (
            <span className="text-xs font-normal text-red-600">(cancelled)</span>
          )}
        </span>
      </SummaryCell>
      <SummaryCell label="Next Action">
        {nextAction ? (
          <span className="line-clamp-2">
            {nextAction}
            {nextFollowUp && (
              <span className="text-xs font-normal text-slate-500">
                {" "}
                · due {new Date(nextFollowUp.due_at).toLocaleDateString()}
              </span>
            )}
          </span>
        ) : null}
      </SummaryCell>
      <SummaryCell label="Attention">
        {attention ? <span className="text-amber-700">{attention}</span> : null}
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
    <section className="rounded-md border border-slate-200 bg-white">
      <h3 className="border-b border-slate-100 px-3 py-2 text-xs font-semibold uppercase tracking-wide text-slate-500">
        {title}
      </h3>
      <div className="px-3 py-2 text-sm">{children}</div>
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
  onAction: (j: JourneyWithDetails, e: JourneyEventType) => void;
  onCancel: (j: JourneyWithDetails) => void;
  onRefresh: () => void;
}) {
  const transitions = STATE_TRANSITIONS[journey.current_state];

  const paid = events
    .filter(
      (e) =>
        (e.event_type === "deposit_received" ||
          e.event_type === "payment_completed") &&
        e.outcome === "SUCCEEDED"
    )
    .reduce((sum, e) => sum + (typeof e.event_data?.amount === "number" ? e.event_data.amount : 0), 0);

  const balance = journey.price !== null && journey.price !== undefined ? journey.price - paid : null;

  const nextFollowUp = followUps
    .filter((f) => !f.completed_at)
    .sort((a, b) => new Date(a.due_at).getTime() - new Date(b.due_at).getTime())[0];

  const [lineItems, setLineItems] = useState<JourneyLineItem[]>([]);
  const [lineItemsLoading, setLineItemsLoading] = useState(false);
  const [reassignMode, setReassignMode] = useState<"choose" | "store" | "employee" | null>(null);
  const [reassignTarget, setReassignTarget] = useState("");
  const [reassignReason, setReassignReason] = useState("");
  const [reassignSaving, setReassignSaving] = useState(false);
  const [fulfillmentSaving, setFulfillmentSaving] = useState(false);
  const [editingAddress, setEditingAddress] = useState(false);
  const [addressSaving, setAddressSaving] = useState(false);
  const [address, setAddress] = useState({ street: "", line2: "", city: "", state: "", zip: "" });
  const [lineAvailability, setLineAvailability] = useState<Record<string, number>>({});
  const [customerContacts, setCustomerContacts] = useState<CustomerContact[]>([]);
  const mismatchedRequested = useRef<Set<string>>(new Set());
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
    setActivityRefreshKey((k) => k + 1);
  }

  const inventoryStoreId = useMemo(
    () => resolveLineItemLocation({}, journey, stores),
    [stores, journey.store_id, journey.fulfillment_type]
  );
  const hasDeliveryAddress =
    (journey.customer?.street_address ?? "").trim() !== "";

  const storeOptions = stores.filter((s) => s.is_active && s.id !== journey.store_id);
  const employeeOptions = employees.filter(
    (e) => e.home_store_id === journey.store_id && e.id !== journey.assigned_employee_id
  );

  function openReassign(mode: "store" | "employee") {
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
      window.alert("Add a customer street address before selecting Delivery.");
      return;
    }
    if (value === journey.fulfillment_type) return;
    const hasReservation = [
      "Sold",
      "Waiting for Inventory",
      "Ready to Schedule",
    ].includes(journey.current_state);
    if (hasReservation && !window.confirm("Changing fulfillment will release and re-source inventory. Continue?")) {
      return;
    }
    setFulfillmentSaving(true);
    try {
      await updateJourneyFulfillment(journey.id, value);
      await handlePanelRefresh();
    } catch (e: any) {
      window.alert(e.message ?? "Failed to update fulfillment type");
    } finally {
      setFulfillmentSaving(false);
    }
  }

  function openAddressEditor() {
    setAddress({
      street: journey.customer?.street_address ?? "",
      line2: journey.customer?.street_address_line_2 ?? "",
      city: journey.customer?.city ?? "",
      state: journey.customer?.state ?? "",
      zip: journey.customer?.zip_code ?? "",
    });
    setEditingAddress(true);
  }

  async function saveAddress() {
    if (!journey.customer) return;
    setAddressSaving(true);
    try {
      await updateCustomerAddress(journey.customer.id, {
        street_address: address.street.trim() || null,
        street_address_line_2: address.line2.trim() || null,
        city: address.city.trim() || null,
        state: address.state.trim() || null,
        zip_code: address.zip.trim() || null,
      });
      setEditingAddress(false);
      await handlePanelRefresh();
    } catch (e: any) {
      window.alert(e.message ?? "Failed to update customer address");
    } finally {
      setAddressSaving(false);
    }
  }

  async function submitReassign() {
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
      window.alert(e.message ?? "Failed to reassign journey");
    } finally {
      setReassignSaving(false);
    }
  }

  useEffect(() => {
    setLineItemsLoading(true);
    fetchJourneyLineItems(journey.id).then((items) => {
      setLineItems(items);
      setLineItemsLoading(false);
    });
    if (journey.customer) {
      fetchCustomerContacts(journey.customer.id).then(setCustomerContacts);
    } else {
      setCustomerContacts([]);
    }
  }, [journey.id, events]);

  useEffect(() => {
    let ignore = false;

    // Clear all current availability values synchronously so a location change
    // never leaves the previous location's number visible during the fetch.
    setLineAvailability((previous) => {
      const next = { ...previous };
      for (const item of lineItems) delete next[item.id];
      return next;
    });

    Promise.all(
      lineItems.map(async (item) => {
        if (!item.product_id) return null;
        const locationId = resolveLineItemLocation(item, journey, stores);
        const map = await fetchProductStock([item.product_id], locationId);
        return [item.id, map[item.product_id]?.ats ?? 0] as const;
      })
    ).then((values) => {
      if (!ignore) setLineAvailability(Object.fromEntries(values.filter(Boolean) as [string, number][]));
    });
    return () => { ignore = true; };
  }, [lineItems, journey.store_id, journey.fulfillment_type, inventoryStoreId]);

  // Phase 7d-ii: auto-create transfer requests when a journey line item's
  // fulfillment location doesn't have enough stock to satisfy the quantity.
  useEffect(() => {
    const supabase = createClient();
    (async () => {
      for (const item of lineItems) {
        if (!item.product_id || !journey.id) continue;
        const ats = lineAvailability[item.id] ?? 0;
        const shortfall = item.quantity - ats;
        if (shortfall <= 0) continue;
        if (mismatchedRequested.current.has(item.id)) continue;

        const locationId = resolveLineItemLocation(item, journey, stores);
        mismatchedRequested.current.add(item.id);

        try {
          const { error } = await (supabase as any).rpc(
            "create_journey_mismatch_transfer",
            {
              p_journey_id: journey.id,
              p_variant_id: item.product_id,
              p_quantity: shortfall,
              p_fulfillment_location_id: locationId,
            }
          );
          if (error) throw new Error(error.message);
        } catch (err: any) {
          console.error("create_journey_mismatch_transfer", err);
          mismatchedRequested.current.delete(item.id);
        }
      }
    })();
  }, [lineAvailability, lineItems, journey.id, journey.store_id, journey.fulfillment_type, inventoryStoreId, stores]);

  async function addLineItem(selection: ProductSelection) {
    try {
      const unitPrice = selection.salePrice ?? selection.price ?? 0;
      await createJourneyLineItem({
        journey_id: journey.id,
        product_id: selection.productId,
        item_name: selection.productSummary,
        quantity: 1,
        unit_price: unitPrice,
      });
      handlePanelRefresh();
    } catch (e: any) {
      window.alert(e.message ?? "Failed to add item");
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
    try {
      await updateJourneyLineItem(id, updates);
      handlePanelRefresh();
    } catch (e: any) {
      window.alert(e.message ?? "Failed to update item");
    }
  }

  async function removeLineItem(id: string) {
    try {
      await deleteJourneyLineItem(id);
      handlePanelRefresh();
    } catch (e: any) {
      window.alert(e.message ?? "Failed to remove item");
    }
  }

  const lineTotal = lineItems.reduce((sum, item) => sum + item.quantity * item.unit_price, 0);

  // Once delivered, the order is historical fact — line items can't be
  // edited in place; the correct path is the Start Exchange flow.
  const orderLocked =
    Boolean(journey.delivered_at) ||
    ["Sleep Trial", "Completed"].includes(journey.current_state);

  async function markFollowUpComplete(id: string) {
    try {
      await completeFollowUp(id);
      handlePanelRefresh();
    } catch (e: any) {
      window.alert(e.message ?? "Failed to complete follow-up");
    }
  }

  async function handleReconcileEvent(paymentEventId: string, newOutcome: PaymentOutcome) {
    try {
      await reconcilePayment(paymentEventId, newOutcome);
      handlePanelRefresh();
    } catch (e: any) {
      window.alert(e.message ?? "Reconciliation failed");
    }
  }

  const addressDirty =
    address.street !== (journey.customer?.street_address ?? "") ||
    address.line2 !== (journey.customer?.street_address_line_2 ?? "") ||
    address.city !== (journey.customer?.city ?? "") ||
    address.state !== (journey.customer?.state ?? "") ||
    address.zip !== (journey.customer?.zip_code ?? "");

  const panelDirty =
    (reassignMode !== null &&
      reassignMode !== "choose" &&
      (reassignTarget !== "" || reassignReason.trim() !== "")) ||
    (editingAddress && addressDirty) ||
    activityState.dirty;
  const panelSaving =
    reassignSaving ||
    fulfillmentSaving ||
    addressSaving ||
    activityState.saving;

  // Attention column: unresolved payment first, then the worst trial
  // status the evaluator reports. Both are reads of existing data — no
  // new logic about what's "wrong" with a journey.
  const urgentTrial = mostUrgentEvaluation(trialEvals);
  const trialStatus = urgentTrial?.headline?.status;
  const attention =
    events.some((e) => e.outcome === "UNKNOWN")
      ? "Unresolved payment"
      : trialStatus === "BLOCKED"
      ? "Trial blocked"
      : trialStatus === "APPROVAL_REQUIRED"
      ? "Approval needed"
      : trialStatus === "EXPIRED"
      ? "Trial ended"
      : null;

  return (
    <Modal
      onClose={onClose}
      overlayClassName="fixed inset-0 z-40 flex justify-end bg-slate-900/50 p-0"
      dirty={panelDirty}
      saving={panelSaving}
    >
      <div className="w-full overflow-y-auto border-l border-slate-200 bg-white shadow-lg min-[900px]:w-[90vw] min-[1280px]:w-[min(72vw,1200px)]">
        <div className="sticky top-0 z-10 border-b border-slate-200 bg-white px-6 pt-4 pb-3">
          <JourneyWorkspaceHeader journey={journey} onClose={onClose} />
          <JourneyStateSummaryBar
            journey={journey}
            nextFollowUp={nextFollowUp}
            attention={attention}
            transitions={transitions}
          />
        </div>

        <div className="grid grid-cols-1 gap-6 p-6 min-[900px]:grid-cols-[2fr_1fr]">
          <div className="min-w-0">
            <div className="space-y-3 text-sm">
              {journey.inventory_ready_notified_at &&
                INVENTORY_READY_STATES.has(journey.current_state) && (
                <div className="rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm font-medium text-emerald-800">
                  Inventory ready
                </div>
              )}

              {(journey.delivered_at || journey.current_state === "Sleep Trial") && (
                <SleepTrialSection
                  journey={journey}
                  currentEmployee={currentEmployee}
                  canModerate={canReconcile}
                  onChanged={handlePanelRefresh}
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
              <h3 className="mb-2 text-sm font-semibold text-slate-900">Actions</h3>
              <div className="flex flex-wrap gap-2">
                {transitions.map((t) => (
                  <button
                    key={t.event}
                    onClick={() => onAction(journey, t.event)}
                    className="rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700"
                  >
                    {t.label}
                  </button>
                ))}
                {journey.current_state !== "Completed" && !journey.cancelled_at && (
                  <button
                    onClick={() => onCancel(journey)}
                    className="rounded-md bg-red-600 px-3 py-2 text-sm font-medium text-white hover:bg-red-700"
                  >
                    Cancel Journey
                  </button>
                )}
              </div>
            </div>

            <JourneyActivity
              journey={journey}
              events={events}
              followUps={followUps}
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

          <aside className="min-w-0 space-y-4">
            <RailCard title="Customer">
              <RailRow label="Name">
                {journey.customer
                  ? `${journey.customer.first_name} ${journey.customer.last_name}`
                  : "Unknown"}
              </RailRow>
              <RailRow label="Phone">{journey.customer?.phone ?? "—"}</RailRow>
              <RailRow label="Email">{journey.customer?.email ?? "—"}</RailRow>
              {customerContacts.length > 0 && (
                <RailRow label="Contacts">
                  {customerContacts.map((c) => (
                    <div key={c.id}>
                      {c.name}
                      {c.role_label ? ` — ${c.role_label}` : ""}
                      {c.phone ? ` · ${c.phone}` : ""}
                    </div>
                  ))}
                </RailRow>
              )}
              <RailRow label="Address">
                <div>
                  <div>
                    {[journey.customer?.street_address, journey.customer?.street_address_line_2, journey.customer?.city, journey.customer?.state, journey.customer?.zip_code]
                      .filter(Boolean)
                      .join(", ") || "No address on file"}
                  </div>
                  {journey.customer && (
                    <button onClick={openAddressEditor} className="mt-1 text-xs text-brand-600 hover:text-brand-700">
                      Edit address
                    </button>
                  )}
                </div>
              </RailRow>
            </RailCard>

            <RailCard title="Financial">
              {journey.price !== null && (
                <RailRow label="Agreed price" align="right">
                  <span className="font-medium">${journey.price.toFixed(2)}</span>
                </RailRow>
              )}
              {journey.price !== null && (
                <RailRow label="Paid" align="right">
                  <span className="font-medium">${paid.toFixed(2)}</span>
                </RailRow>
              )}
              {journey.price !== null && paid > journey.price && (
                <RailRow label="Credit due" align="right">
                  <span className="font-medium text-blue-600">
                    ${(paid - journey.price).toFixed(2)}
                  </span>
                </RailRow>
              )}
              {balance !== null && paid <= (journey.price ?? 0) && (
                <RailRow label="Balance due" align="right">
                  <span className={`font-medium ${balance > 0 ? "text-amber-600" : "text-green-600"}`}>
                    ${balance.toFixed(2)}
                  </span>
                </RailRow>
              )}
              {journey.price === null && (
                <p className="text-slate-500">No price set.</p>
              )}
            </RailCard>

            <RailCard title="Fulfillment">
              <RailRow label="Type">
                {canReassign ? (
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
                ) : (
                  journey.fulfillment_type === "pickup" ? "Pickup" : "Delivery"
                )}
              </RailRow>
              {journey.delivered_at && (
                <RailRow label="Delivered">
                  {new Date(journey.delivered_at).toLocaleDateString()}
                </RailRow>
              )}
            </RailCard>

            <RailCard title="Order">
              <div className="mb-2 flex items-center justify-between">
                <span className="text-slate-500">{lineItems.length} item{lineItems.length === 1 ? "" : "s"}</span>
                <span className="font-medium text-slate-900">
                  Total: ${(journey.price ?? 0).toFixed(2)}
                </span>
              </div>

              {lineItemsLoading && (
                <p className="text-sm text-slate-500">Loading items…</p>
              )}

              {!lineItemsLoading && lineItems.length === 0 && (
                <p className="text-sm text-slate-500">No items on this journey.</p>
              )}

              {!lineItemsLoading && lineItems.length > 0 && (
                <div className="space-y-2">
                  {lineItems.map((item) => (
                    <div
                      key={item.id}
                      className="grid grid-cols-12 items-center gap-2 rounded-md border border-slate-200 bg-slate-50 p-2 text-xs"
                    >
                      <div className="col-span-5 min-w-0 text-slate-900">
                        <div className="truncate">{item.item_name}</div>
                        {canReassign && !orderLocked && (
                          <>
                            <select
                              value={item.fulfillment_type_override ?? "inherit"}
                              onChange={(e) => updateLineItem(item.id, {
                                fulfillment_type_override: e.target.value === "inherit" ? null : e.target.value as "delivery" | "pickup",
                                pickup_location_id: e.target.value === "pickup" ? item.pickup_location_id ?? journey.store_id : null,
                              })}
                              className="mt-1 w-full rounded border border-slate-300 bg-white px-1 py-1 text-xs"
                            >
                              <option value="inherit">Inherit Journey ({journey.fulfillment_type})</option>
                              <option value="delivery" disabled={!hasDeliveryAddress}>Delivery</option>
                              <option value="pickup">Pickup</option>
                            </select>
                            {(item.fulfillment_type_override ?? journey.fulfillment_type) === "pickup" && (
                              <select
                                value={item.pickup_location_id ?? journey.store_id}
                                onChange={(e) => updateLineItem(item.id, { pickup_location_id: e.target.value })}
                                className="mt-1 w-full rounded border border-slate-300 bg-white px-1 py-1 text-xs"
                              >
                                {stores.filter((s) => s.location_type !== "WAREHOUSE_QUARANTINE").map((s) => (
                                  <option key={s.id} value={s.id}>{s.name}</option>
                                ))}
                              </select>
                            )}
                          </>
                        )}
                        {item.product_id && <div className="mt-1 text-xs text-slate-500">Availability: {lineAvailability[item.id] ?? "Loading…"}</div>}
                      </div>
                      {orderLocked ? (
                        <div className="col-span-5 text-slate-600">
                          {item.quantity} × ${item.unit_price.toFixed(2)}
                        </div>
                      ) : (
                        <>
                          <div className="col-span-2">
                            <input
                              type="number"
                              min={1}
                              defaultValue={item.quantity}
                              onBlur={(e) =>
                                updateLineItem(item.id, { quantity: Math.max(1, parseInt(e.target.value) || 1) })
                              }
                              className="w-full rounded-md border border-slate-300 px-1 py-1 text-center text-xs focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                            />
                          </div>
                          <div className="col-span-3">
                            <input
                              type="number"
                              min={0}
                              step="0.01"
                              defaultValue={item.unit_price.toFixed(2)}
                              onBlur={(e) =>
                                updateLineItem(item.id, { unit_price: parseFloat(e.target.value) || 0 })
                              }
                              className="w-full rounded-md border border-slate-300 px-1 py-1 text-xs focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                            />
                          </div>
                        </>
                      )}
                      <div className="col-span-1 text-right text-slate-600">
                        ${(item.quantity * item.unit_price).toFixed(2)}
                      </div>
                      <div className="col-span-1 flex justify-end">
                        {!orderLocked && (
                          <button
                            onClick={() => removeLineItem(item.id)}
                            className="rounded p-1 text-slate-400 hover:bg-red-100 hover:text-red-600"
                            aria-label="Remove"
                          >
                            <Trash2 className="h-3 w-3" />
                          </button>
                        )}
                      </div>
                    </div>
                  ))}
                </div>
              )}

              {orderLocked && lineItems.length > 0 && (
                <p className="mt-2 text-xs text-slate-500">
                  Delivered — use Start Exchange to change items.
                </p>
              )}

              {!orderLocked && (
                <div className="mt-3">
                  <ProductPicker storeId={inventoryStoreId} onSelect={addLineItem} />
                </div>
              )}
            </RailCard>

            <RailCard title="Ownership">
              <RailRow label="Store">{journey.store?.name ?? "—"}</RailRow>
              <RailRow label="Assigned">{journey.employee?.name ?? "—"}</RailRow>

              {canReassign && reassignMode === null && (
                <button
                  onClick={() => setReassignMode("choose")}
                  className="mt-2 w-full rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
                >
                  Reassign
                </button>
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

        {editingAddress && journey.customer && (
          <Modal
            onClose={() => setEditingAddress(false)}
            dirty={addressDirty}
            saving={addressSaving}
          >
            <div className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
              <h2 className="mb-4 text-lg font-semibold text-slate-900">Edit customer address</h2>
              <div className="space-y-3">
                <input value={address.street} onChange={(e) => setAddress((a) => ({ ...a, street: e.target.value }))} placeholder="Street address" className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm" />
                <input value={address.line2} onChange={(e) => setAddress((a) => ({ ...a, line2: e.target.value }))} placeholder="Address Line 2 (optional)" className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm" />
                <div className="grid grid-cols-3 gap-2">
                  <input value={address.city} onChange={(e) => setAddress((a) => ({ ...a, city: e.target.value }))} placeholder="City" className="rounded-md border border-slate-300 px-3 py-2 text-sm" />
                  <input value={address.state} onChange={(e) => setAddress((a) => ({ ...a, state: e.target.value }))} placeholder="State" className="rounded-md border border-slate-300 px-3 py-2 text-sm" />
                  <input value={address.zip} onChange={(e) => setAddress((a) => ({ ...a, zip: e.target.value }))} placeholder="ZIP" className="rounded-md border border-slate-300 px-3 py-2 text-sm" />
                </div>
                <div className="flex gap-2 pt-2">
                  <button onClick={saveAddress} disabled={addressSaving} className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white disabled:opacity-50">{addressSaving ? "Saving…" : "Save"}</button>
                  <button onClick={() => setEditingAddress(false)} className="flex-1 rounded-md border border-slate-300 px-3 py-2 text-sm font-medium text-slate-700">Cancel</button>
                </div>
              </div>
            </div>
          </Modal>
        )}
      </div>
    </Modal>
  );
}
