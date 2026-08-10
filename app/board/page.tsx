"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import Link from "next/link";
import {
  DndContext,
  type DragEndEvent,
  PointerSensor,
  useDraggable,
  useDroppable,
  useSensor,
  useSensors,
} from "@dnd-kit/core";
import {
  Search,
  Plus,
  Table2,
  LayoutGrid,
  X,
  Check,
  Trash2,
} from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { BOARD_STATES, type SleepJourneyState } from "@/lib/constants";
import {
  fetchJourneys,
  fetchJourneyEvents,
  fetchJourneyFollowUps,
  fetchJourneyLineItems,
  fetchEmployees,
  fetchCurrentEmployee,
  fetchStores,
  subscribeToJourneyChanges,
  recordJourneyEvent,
  cancelJourney,
  completeFollowUp,
  createJourneyLineItem,
  updateJourneyLineItem,
  deleteJourneyLineItem,
  type JourneyWithDetails,
  type JourneyEvent,
  type FollowUp,
  type Employee,
  type Store,
  type JourneyLineItem,
} from "@/lib/journeys/queries";
import ProductPicker, { type ProductSelection } from "@/components/ProductPicker";
import {
  getTransitionForTarget,
  getTransitionForEvent,
  STATE_TRANSITIONS,
  type JourneyEventType,
  type StateTransition,
} from "@/lib/journeys/state";

export default function BoardPage() {
  const router = useRouter();
  const [user, setUser] = useState<any>(null);
  const [currentEmployee, setCurrentEmployee] = useState<Employee | null>(null);
  const [activeStoreId, setActiveStoreId] = useState<string | null | undefined>();
  const [stores, setStores] = useState<Store[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [journeys, setJourneys] = useState<JourneyWithDetails[]>([]);
  const [loading, setLoading] = useState(true);

  const [view, setView] = useState<"board" | "table">("board");
  const [search, setSearch] = useState("");
  const [employeeFilter, setEmployeeFilter] = useState<string>("all");
  const [storeFilter, setStoreFilter] = useState<string>("active");

  const [selectedJourney, setSelectedJourney] = useState<JourneyWithDetails | null>(null);
  const [events, setEvents] = useState<JourneyEvent[]>([]);
  const [followUps, setFollowUps] = useState<FollowUp[]>([]);
  const [pendingTransition, setPendingTransition] = useState<{
    journey: JourneyWithDetails;
    transition: StateTransition;
  } | null>(null);
  const [pendingFieldValues, setPendingFieldValues] = useState<Record<string, string>>({});
  const [cancelReason, setCancelReason] = useState("");
  const [cancelJourneyState, setCancelJourneyState] = useState<JourneyWithDetails | null>(null);

  const canViewAll = currentEmployee?.role === "owner" || currentEmployee?.role === "manager";

  const fetchStoreValue = async (u: any) => {
    const active = u.user_metadata?.active_store_id;
    setActiveStoreId(active);
    setUser(u);
    return active;
  };

  const loadData = async (u: any, active: string | null | undefined) => {
    setLoading(true);
    const emp = await fetchCurrentEmployee();
    setCurrentEmployee(emp);

    const [allStores, allEmployees] = await Promise.all([
      fetchStores(),
      fetchEmployees(),
    ]);
    setStores(allStores);
    setEmployees(allEmployees);

    const effectiveStore =
      storeFilter === "all" && canViewAll ? undefined : active ?? undefined;
    const data = await fetchJourneys(
      effectiveStore,
      search,
      employeeFilter !== "all" ? employeeFilter : undefined
    );
    setJourneys(data);
    setLoading(false);
  };

  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getSession().then(async ({ data: { session } }) => {
      if (!session?.user) {
        router.push("/login");
        return;
      }
      const active = await fetchStoreValue(session.user);
      if (active === undefined && session.user.user_metadata?.active_store_id === undefined) {
        router.push("/store-select");
        return;
      }
      await loadData(session.user, active);
    });

    const unsubscribe = subscribeToJourneyChanges(() => {
      supabase.auth.getSession().then(({ data: { session } }) => {
        if (session?.user) {
          loadData(session.user, session.user.user_metadata?.active_store_id);
        }
      });
    });

    fetch("/api/cron").catch(console.error);
    const interval = setInterval(() => {
      fetch("/api/cron").catch(console.error);
    }, 60000);

    return () => {
      unsubscribe();
      clearInterval(interval);
    };
  }, [router, search, employeeFilter, storeFilter]);

  useEffect(() => {
    if (selectedJourney) {
      fetchJourneyEvents(selectedJourney.id).then(setEvents);
      fetchJourneyFollowUps(selectedJourney.id).then(setFollowUps);
    }
  }, [selectedJourney]);

  const boardJourneys = useMemo(() => {
    return journeys.filter((j) => !j.cancelled_at);
  }, [journeys]);

  const columns = useMemo(() => {
    return BOARD_STATES.map((state) => ({
      state,
      journeys: boardJourneys.filter((j) => j.current_state === state),
    }));
  }, [boardJourneys]);

  const sensors = useSensors(
    useSensor(PointerSensor, { activationConstraint: { distance: 8 } })
  );

  async function handleDragEnd(event: DragEndEvent) {
    const { active, over } = event;
    if (!over) return;

    const journeyId = active.id as string;
    const targetState = over.id as SleepJourneyState;
    const journey = journeys.find((j) => j.id === journeyId);
    if (!journey) return;

    if (journey.current_state === targetState) return;

    const transition = getTransitionForTarget(journey.current_state, targetState);
    if (!transition) {
      window.alert(`Cannot move directly from ${journey.current_state} to ${targetState}`);
      return;
    }

    if (transition.requiredFields && transition.requiredFields.length > 0) {
      setPendingTransition({ journey, transition });
      setPendingFieldValues(
        Object.fromEntries(transition.requiredFields.map((f) => [f.name, ""]))
      );
      return;
    }

    await executeTransition(journey, transition, {});
  }

  async function executeTransition(
    journey: JourneyWithDetails,
    transition: StateTransition,
    fieldValues: Record<string, string>
  ) {
    const eventData: Record<string, unknown> = {};

    for (const field of transition.requiredFields ?? []) {
      if (!field.optional && !fieldValues[field.name]) {
        window.alert(`${field.label} is required`);
        return;
      }
      if (fieldValues[field.name]) {
        eventData[field.name] =
          field.type === "number" ? Number(fieldValues[field.name]) : fieldValues[field.name];
      }
    }

    try {
      await recordJourneyEvent(journey.id, transition.event, eventData);
      setPendingTransition(null);
      setPendingFieldValues({});
    } catch (e: any) {
      window.alert(e.message ?? "Failed to record event");
    }
  }

  async function executeAction(journey: JourneyWithDetails, eventType: JourneyEventType) {
    const transition = getTransitionForEvent(journey.current_state, eventType);
    if (!transition) return;

    if (transition.requiredFields && transition.requiredFields.length > 0) {
      setPendingTransition({ journey, transition });
      setPendingFieldValues(
        Object.fromEntries(transition.requiredFields.map((f) => [f.name, ""]))
      );
      return;
    }

    await executeTransition(journey, transition, {});
  }

  async function submitCancel() {
    if (!cancelJourneyState || !cancelReason.trim()) return;
    try {
      await cancelJourney(cancelJourneyState.id, cancelReason);
      setCancelJourneyState(null);
      setCancelReason("");
    } catch (e: any) {
      window.alert(e.message ?? "Failed to cancel journey");
    }
  }

  return (
    <main className="min-h-screen bg-slate-50 p-6">
      <header className="mb-4 flex flex-wrap items-center justify-between gap-4">
        <h1 className="text-2xl font-semibold text-slate-900">Sleep Journey Board</h1>
        <div className="flex items-center gap-2">
          <Link
            href="/journeys/new"
            className="inline-flex items-center gap-2 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700"
          >
            <Plus className="h-4 w-4" /> New Journey
          </Link>
          <button
            onClick={() => setView(view === "board" ? "table" : "board")}
            className="inline-flex items-center gap-2 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            {view === "board" ? <Table2 className="h-4 w-4" /> : <LayoutGrid className="h-4 w-4" />}
            {view === "board" ? "Table" : "Board"}
          </button>
        </div>
      </header>

      <div className="mb-4 flex flex-wrap items-center gap-3">
        <div className="relative">
          <Search className="absolute left-2.5 top-2.5 h-4 w-4 text-slate-400" />
          <input
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search customer or phone"
            className="w-64 rounded-md border border-slate-300 py-2 pl-9 pr-3 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          />
        </div>

        <select
          value={employeeFilter}
          onChange={(e) => setEmployeeFilter(e.target.value)}
          className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
        >
          <option value="all">All employees</option>
          {employees.map((e) => (
            <option key={e.id} value={e.id}>
              {e.name}
            </option>
          ))}
        </select>

        {canViewAll && (
          <select
            value={storeFilter}
            onChange={(e) => setStoreFilter(e.target.value)}
            className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
          >
            <option value="active">Active store</option>
            <option value="all">All stores</option>
          </select>
        )}
      </div>

      {loading && <p className="text-sm text-slate-500">Loading…</p>}

      {!loading && view === "board" && (
        <DndContext sensors={sensors} onDragEnd={handleDragEnd}>
          <div className="grid min-w-[960px] grid-cols-6 gap-2 overflow-x-auto pb-2">
            {columns.map((column) => (
              <Column
                key={column.state}
                state={column.state}
                journeys={column.journeys}
                onSelect={setSelectedJourney}
              />
            ))}
          </div>
        </DndContext>
      )}

      {!loading && view === "table" && (
        <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
          <table className="w-full text-sm">
            <thead className="border-b border-slate-200 bg-slate-50 text-left">
              <tr>
                <th className="px-4 py-2 font-medium text-slate-700">Customer</th>
                <th className="px-4 py-2 font-medium text-slate-700">Phone</th>
                <th className="px-4 py-2 font-medium text-slate-700">Product</th>
                <th className="px-4 py-2 font-medium text-slate-700">State</th>
                <th className="px-4 py-2 font-medium text-slate-700">Store</th>
                <th className="px-4 py-2 font-medium text-slate-700">Assigned</th>
                <th className="px-4 py-2 font-medium text-slate-700">Cancelled</th>
              </tr>
            </thead>
            <tbody>
              {journeys.map((j) => (
                <tr
                  key={j.id}
                  className="border-b border-slate-100 hover:bg-slate-50"
                  onClick={() => setSelectedJourney(j)}
                >
                  <td className="px-4 py-2">
                    {j.customer
                      ? `${j.customer.first_name} ${j.customer.last_name}`
                      : "Unknown"}
                  </td>
                  <td className="px-4 py-2">{j.customer?.phone ?? "—"}</td>
                  <td className="px-4 py-2">{j.product_summary ?? "—"}</td>
                  <td className="px-4 py-2">{j.current_state}</td>
                  <td className="px-4 py-2">{j.store?.name ?? "—"}</td>
                  <td className="px-4 py-2">{j.employee?.name ?? "—"}</td>
                  <td className="px-4 py-2">{j.cancelled_at ? "Yes" : "No"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {selectedJourney && (
        <JourneyDetailPanel
          journey={selectedJourney}
          events={events}
          followUps={followUps}
          employees={employees}
          onClose={() => setSelectedJourney(null)}
          onAction={executeAction}
          onCancel={setCancelJourneyState}
          onRefresh={() => {
            fetchJourneyFollowUps(selectedJourney.id).then(setFollowUps);
          }}
        />
      )}

      {pendingTransition && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/50 p-4">
          <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            <h2 className="mb-2 text-lg font-semibold text-slate-900">
              {pendingTransition.transition.label}
            </h2>
            <p className="mb-4 text-sm text-slate-600">
              {pendingTransition.journey.customer
                ? `${pendingTransition.journey.customer.first_name} ${pendingTransition.journey.customer.last_name}`
                : "Journey"}{" "}
              → {pendingTransition.transition.to}
            </p>
            {pendingTransition.journey.price !== null && pendingTransition.journey.price !== undefined && (
              <div className="mb-4 rounded-md bg-slate-50 p-3 text-sm">
                {(() => {
                  const paid = events
                    .filter(
                      (e) =>
                        e.event_type === "deposit_received" ||
                        e.event_type === "payment_completed"
                    )
                    .reduce(
                      (sum, e) =>
                        sum +
                        (typeof e.event_data?.amount === "number" ? e.event_data.amount : 0),
                      0
                    );
                  const balance = pendingTransition.journey.price - paid;
                  return (
                    <p className="font-medium text-slate-700">
                      Current balance due: ${balance.toFixed(2)}
                    </p>
                  );
                })()}
              </div>
            )}
            <div className="space-y-3">
              {pendingTransition.transition.requiredFields?.map((field) => (
                <div key={field.name}>
                  <label className="block text-sm font-medium text-slate-700">
                    {field.label}
                  </label>
                  {field.type === "date" ? (
                    <input
                      type="date"
                      value={pendingFieldValues[field.name] ?? ""}
                      onChange={(e) =>
                        setPendingFieldValues({
                          ...pendingFieldValues,
                          [field.name]: e.target.value,
                        })
                      }
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                    />
                  ) : field.type === "datetime-local" ? (
                    <input
                      type="datetime-local"
                      value={pendingFieldValues[field.name] ?? ""}
                      onChange={(e) =>
                        setPendingFieldValues({
                          ...pendingFieldValues,
                          [field.name]: e.target.value,
                        })
                      }
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                    />
                  ) : (
                    <input
                      type={field.type === "number" ? "number" : "text"}
                      value={pendingFieldValues[field.name] ?? ""}
                      onChange={(e) =>
                        setPendingFieldValues({
                          ...pendingFieldValues,
                          [field.name]: e.target.value,
                        })
                      }
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                    />
                  )}
                </div>
              ))}
            </div>
            <div className="mt-4 flex gap-2">
              <button
                onClick={() =>
                  executeTransition(
                    pendingTransition.journey,
                    pendingTransition.transition,
                    pendingFieldValues
                  )
                }
                className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700"
              >
                Confirm
              </button>
              <button
                onClick={() => {
                  setPendingTransition(null);
                  setPendingFieldValues({});
                }}
                className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Cancel
              </button>
            </div>
          </div>
        </div>
      )}

      {cancelJourneyState && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/50 p-4">
          <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            <h2 className="mb-2 text-lg font-semibold text-slate-900">Cancel Journey</h2>
            <textarea
              value={cancelReason}
              onChange={(e) => setCancelReason(e.target.value)}
              placeholder="Reason for cancellation"
              className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              rows={3}
            />
            <div className="mt-4 flex gap-2">
              <button
                onClick={submitCancel}
                className="flex-1 rounded-md bg-red-600 px-3 py-2 text-sm font-medium text-white hover:bg-red-700"
              >
                Cancel Journey
              </button>
              <button
                onClick={() => setCancelJourneyState(null)}
                className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Close
              </button>
            </div>
          </div>
        </div>
      )}
    </main>
  );
}

const STATE_ACCENT: Record<SleepJourneyState, string> = {
  "Active Opportunity": "border-l-slate-300",
  Quoted: "border-l-amber-300",
  "Deposit Made": "border-l-amber-300",
  Sold: "border-l-green-300",
  "Waiting for Inventory": "border-l-blue-300",
  "Ready to Schedule": "border-l-indigo-300",
  Scheduled: "border-l-purple-300",
  "Sleep Trial": "border-l-teal-300",
  Completed: "border-l-slate-300",
};

function Column({
  state,
  journeys,
  onSelect,
}: {
  state: SleepJourneyState;
  journeys: JourneyWithDetails[];
  onSelect: (j: JourneyWithDetails) => void;
}) {
  const { setNodeRef, isOver } = useDroppable({ id: state });

  return (
    <div
      ref={setNodeRef}
      className={`flex w-full min-w-0 flex-col rounded-lg border border-slate-200 bg-slate-100 p-1.5 ${
        isOver ? "ring-2 ring-brand-400" : ""
      }`}
    >
      <div className="mb-1.5 flex items-center justify-between gap-1 px-1">
        <h3 className="truncate text-xs font-semibold leading-tight text-slate-700">
          {state}
        </h3>
        <span className="rounded-full bg-slate-200 px-1.5 py-0.5 text-[10px] text-slate-600">
          {journeys.length}
        </span>
      </div>
      <div className="min-h-[80px] space-y-1.5">
        {journeys.map((j) => (
          <JourneyCard key={j.id} journey={j} onSelect={onSelect} />
        ))}
      </div>
    </div>
  );
}

function JourneyCard({
  journey,
  onSelect,
}: {
  journey: JourneyWithDetails;
  onSelect: (j: JourneyWithDetails) => void;
}) {
  const { attributes, listeners, setNodeRef, transform, isDragging } = useDraggable({
    id: journey.id,
  });

  const style = {
    transform: transform
      ? `translate3d(${transform.x}px, ${transform.y}px, 0)`
      : undefined,
    opacity: isDragging ? 0.5 : 1,
  };

  return (
    <div
      ref={setNodeRef}
      style={style}
      {...listeners}
      {...attributes}
      onClick={() => onSelect(journey)}
      className={`cursor-grab space-y-0.5 rounded-md border border-slate-200 bg-white p-2 shadow-sm active:cursor-grabbing border-l-2 ${STATE_ACCENT[journey.current_state]}`}
    >
      <p className="truncate text-xs font-medium leading-tight text-slate-900">
        {journey.customer
          ? `${journey.customer.first_name} ${journey.customer.last_name}`
          : "Unknown"}
      </p>
      <p className="truncate text-[10px] leading-tight text-slate-500">
        {journey.customer?.phone ?? "—"}
      </p>
      {journey.product_summary && (
        <p className="truncate text-[10px] leading-tight text-slate-600">
          {journey.product_summary}
        </p>
      )}
      {journey.employee && (
        <p className="truncate text-[10px] leading-tight text-slate-500">
          {journey.employee.name}
        </p>
      )}
    </div>
  );
}

function JourneyDetailPanel({
  journey,
  events,
  followUps,
  employees,
  onClose,
  onAction,
  onCancel,
  onRefresh,
}: {
  journey: JourneyWithDetails;
  events: JourneyEvent[];
  followUps: FollowUp[];
  employees: Employee[];
  onClose: () => void;
  onAction: (j: JourneyWithDetails, e: JourneyEventType) => void;
  onCancel: (j: JourneyWithDetails) => void;
  onRefresh: () => void;
}) {
  const transitions = STATE_TRANSITIONS[journey.current_state];

  const paid = events
    .filter((e) => e.event_type === "deposit_received" || e.event_type === "payment_completed")
    .reduce((sum, e) => sum + (typeof e.event_data?.amount === "number" ? e.event_data.amount : 0), 0);

  const balance = journey.price !== null && journey.price !== undefined ? journey.price - paid : null;

  const nextFollowUp = followUps
    .filter((f) => !f.completed_at)
    .sort((a, b) => new Date(a.due_at).getTime() - new Date(b.due_at).getTime())[0];

  const [lineItems, setLineItems] = useState<JourneyLineItem[]>([]);
  const [lineItemsLoading, setLineItemsLoading] = useState(false);

  useEffect(() => {
    setLineItemsLoading(true);
    fetchJourneyLineItems(journey.id).then((items) => {
      setLineItems(items);
      setLineItemsLoading(false);
    });
  }, [journey.id, events]);

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
      onRefresh();
    } catch (e: any) {
      window.alert(e.message ?? "Failed to add item");
    }
  }

  async function updateLineItem(id: string, updates: { quantity?: number; unit_price?: number }) {
    try {
      await updateJourneyLineItem(id, updates);
      onRefresh();
    } catch (e: any) {
      window.alert(e.message ?? "Failed to update item");
    }
  }

  async function removeLineItem(id: string) {
    try {
      await deleteJourneyLineItem(id);
      onRefresh();
    } catch (e: any) {
      window.alert(e.message ?? "Failed to remove item");
    }
  }

  const lineTotal = lineItems.reduce((sum, item) => sum + item.quantity * item.unit_price, 0);

  async function markFollowUpComplete(id: string) {
    try {
      await completeFollowUp(id);
      onRefresh();
    } catch (e: any) {
      window.alert(e.message ?? "Failed to complete follow-up");
    }
  }

  return (
    <div className="fixed inset-0 z-40 flex justify-end bg-slate-900/50 p-0">
      <div className="w-full max-w-md overflow-y-auto border-l border-slate-200 bg-white p-6 shadow-lg">
        <div className="mb-4 flex items-center justify-between">
          <h2 className="text-lg font-semibold text-slate-900">Journey Details</h2>
          <button
            onClick={onClose}
            className="rounded-md p-1 text-slate-500 hover:bg-slate-100"
          >
            <X className="h-5 w-5" />
          </button>
        </div>

        <div className="space-y-3 text-sm">
          <div className="flex items-center justify-between">
            <span className="text-slate-500">State</span>
            <span className="rounded-full bg-slate-100 px-2 py-0.5 font-medium text-slate-700">
              {journey.current_state}
            </span>
          </div>

          {journey.price !== null && (
            <div className="flex items-center justify-between">
              <span className="text-slate-500">Agreed price</span>
              <span className="font-medium text-slate-900">${journey.price.toFixed(2)}</span>
            </div>
          )}

          {journey.price !== null && paid > journey.price && (
            <div className="flex items-center justify-between">
              <span className="text-slate-500">Credit due</span>
              <span className="font-medium text-blue-600">
                ${(paid - journey.price).toFixed(2)}
              </span>
            </div>
          )}

          {balance !== null && paid <= (journey.price ?? 0) && (
            <div className="flex items-center justify-between">
              <span className="text-slate-500">Balance due</span>
              <span className={`font-medium ${balance > 0 ? "text-amber-600" : "text-green-600"}`}>
                ${balance.toFixed(2)}
              </span>
            </div>
          )}

          <div className="flex items-center justify-between">
            <span className="text-slate-500">Customer</span>
            <span className="text-right font-medium text-slate-900">
              {journey.customer
                ? `${journey.customer.first_name} ${journey.customer.last_name}`
                : "Unknown"}
            </span>
          </div>

          <div className="flex items-center justify-between">
            <span className="text-slate-500">Phone</span>
            <span className="text-slate-700">{journey.customer?.phone ?? "—"}</span>
          </div>

          <div className="flex items-center justify-between">
            <span className="text-slate-500">Email</span>
            <span className="text-slate-700">{journey.customer?.email ?? "—"}</span>
          </div>

          <div className="border-t border-slate-200 pt-3">
            <div className="mb-2 flex items-center justify-between">
              <span className="text-slate-500">Line Items</span>
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
                    <div className="col-span-5 truncate text-slate-900">{item.item_name}</div>
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
                    <div className="col-span-1 text-right text-slate-600">
                      ${(item.quantity * item.unit_price).toFixed(2)}
                    </div>
                    <div className="col-span-1 flex justify-end">
                      <button
                        onClick={() => removeLineItem(item.id)}
                        className="rounded p-1 text-slate-400 hover:bg-red-100 hover:text-red-600"
                        aria-label="Remove"
                      >
                        <Trash2 className="h-3 w-3" />
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            )}

            <div className="mt-3">
              <ProductPicker storeId={journey.store_id} onSelect={addLineItem} />
            </div>
          </div>

          <div className="flex items-center justify-between">
            <span className="text-slate-500">Store</span>
            <span className="text-slate-700">{journey.store?.name ?? "—"}</span>
          </div>

          <div className="flex items-center justify-between">
            <span className="text-slate-500">Assigned</span>
            <span className="text-slate-700">{journey.employee?.name ?? "—"}</span>
          </div>
        </div>

        {nextFollowUp && (
          <div className="mt-4 rounded-md border border-amber-200 bg-amber-50 p-3">
            <h3 className="text-xs font-semibold uppercase text-amber-700">Next recommended action</h3>
            <p className="mt-1 text-sm text-slate-800">{nextFollowUp.notes}</p>
            <p className="text-xs text-slate-500">
              Due {new Date(nextFollowUp.due_at).toLocaleString()}
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

        <div className="mt-6">
          <h3 className="mb-2 text-sm font-semibold text-slate-900">Follow-up history</h3>
          <div className="space-y-2">
            {followUps.length === 0 && (
              <p className="text-sm text-slate-500">No follow-ups.</p>
            )}
            {followUps.map((f) => (
              <div
                key={f.id}
                className={`rounded-md border p-2 text-sm ${
                  f.completed_at
                    ? "border-slate-200 bg-slate-50 text-slate-500"
                    : "border-amber-200 bg-amber-50 text-slate-800"
                }`}
              >
                <p className="font-medium capitalize">{f.type}</p>
                <p className="text-xs">{f.notes}</p>
                <p className="text-xs">Due {new Date(f.due_at).toLocaleString()}</p>
                {f.completed_at && (
                  <p className="text-xs">Completed {new Date(f.completed_at).toLocaleString()}</p>
                )}
              </div>
            ))}
          </div>
        </div>

        <div className="mt-6">
          <h3 className="mb-2 text-sm font-semibold text-slate-900">History</h3>
          <div className="space-y-2">
            {events.map((e) => (
              <div
                key={e.id}
                className="rounded-md border border-slate-200 bg-slate-50 p-2 text-sm"
              >
                <p className="font-medium text-slate-700">{e.event_type}</p>
                {Object.keys(e.event_data ?? {}).length > 0 && (
                  <p className="text-xs text-slate-500">
                    {JSON.stringify(e.event_data)}
                  </p>
                )}
                <p className="text-xs text-slate-400">
                  {new Date(e.created_at).toLocaleString()} by {e.triggered_by === "system" ? "System" : "User"}
                </p>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
