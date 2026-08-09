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
  Calendar,
  Trash2,
  Check,
} from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { SLEEP_JOURNEY_STATES, type SleepJourneyState } from "@/lib/constants";
import {
  fetchJourneys,
  fetchJourneyEvents,
  fetchEmployees,
  fetchCurrentEmployee,
  fetchStores,
  subscribeToJourneyChanges,
  recordJourneyEvent,
  cancelJourney,
  type JourneyWithDetails,
  type JourneyEvent,
  type Employee,
  type Store,
} from "@/lib/journeys/queries";
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
    }
  }, [selectedJourney]);

  const visibleJourneys = useMemo(() => {
    return journeys.filter((j) => !j.cancelled_at);
  }, [journeys]);

  const columns = useMemo(() => {
    return SLEEP_JOURNEY_STATES.map((state) => ({
      state,
      journeys: visibleJourneys.filter((j) => j.current_state === state),
    }));
  }, [visibleJourneys]);

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
      if (!fieldValues[field.name]) {
        window.alert(`${field.label} is required`);
        return;
      }
      eventData[field.name] =
        field.type === "number" ? Number(fieldValues[field.name]) : fieldValues[field.name];
    }

    try {
      await recordJourneyEvent(journey.id, transition.event, eventData);
      setPendingTransition(null);
      setPendingFieldValues({});
    } catch (e: any) {
      window.alert(e.message ?? "Failed to record event");
    }
  }

  async function executeAction(
    journey: JourneyWithDetails,
    eventType: JourneyEventType
  ) {
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
          <div className="flex gap-3 overflow-x-auto pb-2">
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
              </tr>
            </thead>
            <tbody>
              {visibleJourneys.map((j) => (
                <tr
                  key={j.id}
                  onClick={() => setSelectedJourney(j)}
                  className="cursor-pointer border-b border-slate-100 hover:bg-slate-50"
                >
                  <td className="px-4 py-2">
                    {j.customer
                      ? `${j.customer.first_name} ${j.customer.last_name}`
                      : "—"}
                  </td>
                  <td className="px-4 py-2">{j.customer?.phone ?? "—"}</td>
                  <td className="px-4 py-2">{j.product_summary ?? "—"}</td>
                  <td className="px-4 py-2">{j.current_state}</td>
                  <td className="px-4 py-2">{j.store?.name ?? "—"}</td>
                  <td className="px-4 py-2">{j.employee?.name ?? "—"}</td>
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
          employees={employees}
          onClose={() => setSelectedJourney(null)}
          onAction={executeAction}
          onCancel={setCancelJourneyState}
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
            <p className="mb-4 text-sm text-slate-600">
              This will remove the journey from the board. A reason is required.
            </p>
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
      className={`flex w-64 shrink-0 flex-col rounded-lg border border-slate-200 bg-slate-100 p-2 ${
        isOver ? "ring-2 ring-brand-400" : ""
      }`}
    >
      <div className="mb-2 flex items-center justify-between px-1">
        <h3 className="text-sm font-semibold text-slate-700">{state}</h3>
        <span className="rounded-full bg-slate-200 px-2 py-0.5 text-xs text-slate-600">
          {journeys.length}
        </span>
      </div>
      <div className="min-h-[120px] space-y-2">
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
      className="cursor-grab rounded-md border border-slate-200 bg-white p-3 shadow-sm active:cursor-grabbing"
    >
      <p className="font-medium text-slate-900">
        {journey.customer
          ? `${journey.customer.first_name} ${journey.customer.last_name}`
          : "Unknown"}
      </p>
      <p className="text-xs text-slate-500">
        {journey.customer?.phone ?? "—"}
      </p>
      {journey.product_summary && (
        <p className="mt-1 truncate text-xs text-slate-600">
          {journey.product_summary}
        </p>
      )}
      {journey.employee && (
        <p className="mt-1 text-xs text-slate-500">{journey.employee.name}</p>
      )}
    </div>
  );
}

function JourneyDetailPanel({
  journey,
  events,
  employees,
  onClose,
  onAction,
  onCancel,
}: {
  journey: JourneyWithDetails;
  events: JourneyEvent[];
  employees: Employee[];
  onClose: () => void;
  onAction: (j: JourneyWithDetails, e: JourneyEventType) => void;
  onCancel: (j: JourneyWithDetails) => void;
}) {
  const transitions = STATE_TRANSITIONS[journey.current_state];

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

        <div className="mb-6 space-y-2 text-sm">
          <p>
            <span className="font-medium text-slate-700">State:</span>{" "}
            {journey.current_state}
          </p>
          <p>
            <span className="font-medium text-slate-700">Customer:</span>{" "}
            {journey.customer
              ? `${journey.customer.first_name} ${journey.customer.last_name}`
              : "—"}
          </p>
          <p>
            <span className="font-medium text-slate-700">Phone:</span>{" "}
            {journey.customer?.phone ?? "—"}
          </p>
          <p>
            <span className="font-medium text-slate-700">Email:</span>{" "}
            {journey.customer?.email ?? "—"}
          </p>
          <p>
            <span className="font-medium text-slate-700">Product:</span>{" "}
            {journey.product_summary ?? "—"}
          </p>
          <p>
            <span className="font-medium text-slate-700">Store:</span>{" "}
            {journey.store?.name ?? "—"}
          </p>
          <p>
            <span className="font-medium text-slate-700">Assigned:</span>{" "}
            {journey.employee?.name ?? employees.find((e) => e.id === journey.assigned_employee_id)?.name ?? "—"}
          </p>
        </div>

        <div className="mb-6 space-y-2">
          <h3 className="text-sm font-semibold text-slate-900">Actions</h3>
          {transitions.length > 0 ? (
            transitions
              .filter(Boolean)
              .map((t) => (
                <button
                  key={t!.event}
                  onClick={() => onAction(journey, t!.event)}
                  className="w-full rounded-md border border-slate-200 bg-white px-3 py-2 text-left text-sm text-slate-700 hover:bg-slate-50"
                >
                  {t!.label}
                </button>
              ))
          ) : (
            <p className="text-sm text-slate-500">No forward actions for this state.</p>
          )}
          {journey.current_state !== "Completed" && !journey.cancelled_at && (
            <button
              onClick={() => onCancel(journey)}
              className="mt-2 inline-flex w-full items-center gap-2 rounded-md bg-red-50 px-3 py-2 text-left text-sm font-medium text-red-700 hover:bg-red-100"
            >
              <Trash2 className="h-4 w-4" /> Cancel Journey
            </button>
          )}
        </div>

        <div>
          <h3 className="mb-2 text-sm font-semibold text-slate-900">History</h3>
          <div className="space-y-2">
            {events.length === 0 && (
              <p className="text-sm text-slate-500">No events yet.</p>
            )}
            {events.map((ev) => (
              <div
                key={ev.id}
                className="rounded-md border border-slate-200 bg-slate-50 p-2 text-sm"
              >
                <p className="font-medium text-slate-800">
                  {ev.event_type.replace(/_/g, " ")}
                </p>
                {ev.event_data && Object.keys(ev.event_data).length > 0 && (
                  <p className="mt-0.5 text-xs text-slate-500">
                    {JSON.stringify(ev.event_data)}
                  </p>
                )}
                <p className="text-xs text-slate-400">
                  {new Date(ev.created_at).toLocaleString()} · {ev.triggered_by === "system" ? "system" : "employee"}
                </p>
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
