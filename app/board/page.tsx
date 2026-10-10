"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
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
  Calculator,
} from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { isStoreConfirmedToday, storeSelectUrl } from "@/lib/journeys/storeConfirm";
import { BOARD_STATES, type SleepJourneyState } from "@/lib/constants";
import {
  fetchJourneys,
  fetchJourneyEvents,
  fetchJourneyById,
  fetchJourneyReassignments,
  fetchJourneyFollowUps,
  fetchEmployees,
  fetchCurrentEmployee,
  fetchStores,
  fetchLiveTrialItemStatuses,
  subscribeToJourneyChanges,
  recordJourneyEvent,
  recordPayment,
  fetchTotalPaid,
  reconcilePayment,
  cancelJourney,
  type PaymentOutcome,
  canReassignJourneys,
  type JourneyWithDetails,
  type JourneyEvent,
  type JourneyReassignmentEvent,
  type FollowUp,
  type Employee,
  type Store,
} from "@/lib/journeys/queries";
import { requestDepositException } from "@/lib/journeys/deposit";
import {
  evaluateSleepTrialItems,
  mostUrgentEvaluation,
  trialStatusLabel,
  trialStatusTone,
  TRIAL_STATUS_CHIP,
  TRIAL_STATUS_DOT,
  type SleepTrialEvaluation,
} from "@/lib/journeys/sleepTrial";
import { localDateISO, localTodayISO } from "@/lib/dates";
import Modal from "@/components/Modal";
import FinancingCalculator from "@/components/FinancingCalculator";
import JourneyWorkspace from "@/components/journeys/JourneyWorkspace";
import {
  getTransitionForTarget,
  getTransitionForEvent,
  type JourneyEventType,
  type StateTransition,
} from "@/lib/journeys/state";

// A journey whose every live trial item is mid-exchange/return is parked
// on its replacement — it leaves the board lists until the action closes
// or is cancelled. Display-only: the journey still opens by id.
const IN_PROGRESS_TRIAL_STATUSES = new Set([
  "EXCHANGE_IN_PROGRESS",
  "RETURN_IN_PROGRESS",
]);

function hiddenByInProgressAction(
  statusesByJourney: Map<string, string[]>
): Set<string> {
  const out = new Set<string>();
  statusesByJourney.forEach((statuses, journeyId) => {
    if (
      statuses.length > 0 &&
      statuses.every((s: string) => IN_PROGRESS_TRIAL_STATUSES.has(s))
    ) {
      out.add(journeyId);
    }
  });
  return out;
}

export default function BoardPage() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const [user, setUser] = useState<any>(null);
  const [currentEmployee, setCurrentEmployee] = useState<Employee | null>(null);
  const [activeStoreId, setActiveStoreId] = useState<string | null | undefined>();
  const [stores, setStores] = useState<Store[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [journeys, setJourneys] = useState<JourneyWithDetails[]>([]);
  const [trialEvals, setTrialEvals] = useState<
    Map<string, SleepTrialEvaluation[]>
  >(new Map());
  const [unresolvedJourneyIds, setUnresolvedJourneyIds] = useState<Set<string>>(new Set());
  // Journeys whose every live trial item is parked in an exchange/return
  // stay off the board lists — they still open by id everywhere else.
  const [hiddenJourneyIds, setHiddenJourneyIds] = useState<Set<string>>(new Set());
  const [loading, setLoading] = useState(true);

  const [view, setView] = useState<"board" | "table">("board");
  const [search, setSearch] = useState("");
  const [employeeFilter, setEmployeeFilter] = useState<string>("all");
  const [storeFilter, setStoreFilter] = useState<string>("active");

  const [selectedJourney, setSelectedJourney] = useState<JourneyWithDetails | null>(null);
  const [events, setEvents] = useState<JourneyEvent[]>([]);
  const [followUps, setFollowUps] = useState<FollowUp[]>([]);
  const [reassignments, setReassignments] = useState<JourneyReassignmentEvent[]>([]);
  const [pendingTransition, setPendingTransition] = useState<{
    journey: JourneyWithDetails;
    transition: StateTransition;
  } | null>(null);
  const [pendingFieldValues, setPendingFieldValues] = useState<Record<string, string>>({});
  const [pendingReconcile, setPendingReconcile] = useState<{
    journey: JourneyWithDetails;
    paymentEventId: string;
    outcome: PaymentOutcome;
  } | null>(null);
  const [pendingDepositException, setPendingDepositException] = useState<{
    journey: JourneyWithDetails;
    amount: number;
    method: string;
    requestId?: string;
    reason?: string;
    error?: string;
  } | null>(null);
  const [pendingOverpayment, setPendingOverpayment] = useState<{
    journey: JourneyWithDetails;
    amount: number;
    method: string;
    remaining: number;
    credit: number;
  } | null>(null);
  const [cancelReason, setCancelReason] = useState("");
  const [cancelJourneyState, setCancelJourneyState] = useState<JourneyWithDetails | null>(null);
  const [boardBusy, setBoardBusy] = useState(false);
  const [showCalculator, setShowCalculator] = useState(false);

  const calculatorCompanyId = useMemo(() => {
    if (!currentEmployee?.home_store_id) return null;
    return stores.find((s) => s.id === currentEmployee.home_store_id)?.company_id ?? null;
  }, [currentEmployee, stores]);

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
      storeFilter === "active"
        ? active ?? undefined
        : storeFilter === "all"
        ? undefined
        : storeFilter;
    const data = await fetchJourneys(
      effectiveStore,
      search,
      employeeFilter !== "all" ? employeeFilter : undefined
    );
    setJourneys(data);

    // Trial status comes from the evaluator (ST-4) — one batch call for
    // every journey sitting in the Sleep Trial column.
    evaluateSleepTrialItems(
      data
        .filter((j) => j.current_state === "Sleep Trial")
        .map((j) => j.id)
    ).then(setTrialEvals);

    const supabase = createClient();
    const [{ data: unresolved }, trialItemStatuses] = await Promise.all([
      supabase
        .from("journey_events")
        .select("journey_id")
        .in("event_type", ["deposit_received", "payment_completed"])
        .eq("outcome", "UNKNOWN"),
      fetchLiveTrialItemStatuses(),
    ]);
    setUnresolvedJourneyIds(
      new Set((unresolved ?? []).map((e: { journey_id: string }) => e.journey_id))
    );
    setHiddenJourneyIds(hiddenByInProgressAction(trialItemStatuses));

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

    return () => {
      unsubscribe();
    };
  }, [router, search, employeeFilter, storeFilter]);

  useEffect(() => {
    if (selectedJourney) {
      fetchJourneyEvents(selectedJourney.id).then(setEvents);
      fetchJourneyFollowUps(selectedJourney.id).then(setFollowUps);
      fetchJourneyReassignments(selectedJourney.id).then(setReassignments);
    } else {
      setReassignments([]);
    }
  }, [selectedJourney]);

  async function handleReassigned(journeyId: string) {
    const [fresh, history, evalMap] = await Promise.all([
      fetchJourneyById(journeyId),
      fetchJourneyReassignments(journeyId),
      // Panel actions (protector override, trial-start correction, ...) can
      // change the item's evaluation — refresh just this journey's evals so
      // the board card behind the panel isn't stale until the next loadData.
      evaluateSleepTrialItems([journeyId]),
    ]);
    setReassignments(history);
    setTrialEvals((prev) => {
      const next = new Map(prev);
      const evals = evalMap.get(journeyId) ?? [];
      if (evals.length > 0) next.set(journeyId, evals);
      else next.delete(journeyId);
      return next;
    });
    if (fresh) {
      setSelectedJourney(fresh);
      setJourneys((prev) => prev.map((j) => (j.id === fresh.id ? fresh : j)));
    } else {
      setSelectedJourney(null);
    }
    // Panel actions (committing/cancelling an exchange) change trial-item
    // statuses, so the board-hide set is refreshed alongside the journey.
    fetchLiveTrialItemStatuses().then((m) =>
      setHiddenJourneyIds(hiddenByInProgressAction(m))
    );
  }

  useEffect(() => {
    const journeyId = searchParams.get("journey");
    if (journeyId) {
      handleReassigned(journeyId);
    }
  }, [searchParams]);

  const boardJourneys = useMemo(() => {
    return journeys.filter(
      (j) => !j.cancelled_at && !hiddenJourneyIds.has(j.id)
    );
  }, [journeys, hiddenJourneyIds]);

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
        Object.fromEntries(
          transition.requiredFields.map((f) => [
            f.name,
            f.defaultToday ? localTodayISO() : "",
          ])
        )
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
    const supabase = createClient();
    const { data: { session } } = await supabase.auth.getSession();
    if (!session?.user || !isStoreConfirmedToday(session.user)) {
      router.push(storeSelectUrl("/board"));
      return;
    }

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

    if (transition.event === "delivery_completed") {
      const d = String(eventData.delivered_at ?? "");
      if (d > localTodayISO()) {
        window.alert("Delivery date can't be in the future.");
        return;
      }
      if (d < localDateISO(journey.created_at)) {
        window.alert(
          "Delivery date can't be before this journey was created."
        );
        return;
      }
    }

    setBoardBusy(true);
    try {
      if (transition.event === "payment_completed") {
        const amount = parseFloat(fieldValues.amount ?? "0");
        const method = fieldValues.payment_method ?? "";

        if (journey.price == null) {
          window.alert("Journey has no price set");
          return;
        }
        if (journey.price <= 0) {
          window.alert("No payment is due on this journey.");
          return;
        }

        const totalPaid = await fetchTotalPaid(journey.id);
        const remaining = journey.price - totalPaid;

        if (amount > remaining) {
          setPendingOverpayment({
            journey,
            amount,
            method,
            remaining,
            credit: amount - remaining,
          });
          setPendingTransition(null);
          setPendingFieldValues({});
          return;
        }

        await submitBoardPayment(journey, amount, method);
      } else {
        await recordJourneyEvent(journey.id, transition.event, eventData);
        setPendingTransition(null);
        setPendingFieldValues({});
        fetchJourneyEvents(journey.id).then(setEvents);
      }
    } catch (e: any) {
      window.alert(e.message ?? "Failed to record event");
    } finally {
      setBoardBusy(false);
    }
  }

  async function handleReconcile(newOutcome: PaymentOutcome) {
    if (!pendingReconcile) return;
    setBoardBusy(true);
    try {
      await reconcilePayment(pendingReconcile.paymentEventId, newOutcome);
      const [freshEvents, freshFollowUps] = await Promise.all([
        fetchJourneyEvents(pendingReconcile.journey.id),
        fetchJourneyFollowUps(pendingReconcile.journey.id),
      ]);
      setEvents(freshEvents);
      setFollowUps(freshFollowUps);
      setPendingReconcile(null);
    } catch (e: any) {
      window.alert(e.message ?? "Reconciliation failed");
    } finally {
      setBoardBusy(false);
    }
  }

  async function submitDepositException() {
    if (!pendingDepositException || !pendingDepositException.reason?.trim()) return;
    setBoardBusy(true);
    try {
      const requestId = await requestDepositException(
        pendingDepositException.journey.id,
        pendingDepositException.amount,
        pendingDepositException.reason.trim()
      );
      setPendingDepositException((prev) =>
        prev ? { ...prev, requestId } : null
      );
    } catch (e: any) {
      setPendingDepositException((prev) =>
        prev ? { ...prev, error: e.message ?? "Request failed" } : null
      );
    } finally {
      setBoardBusy(false);
    }
  }

  async function recordPaymentWithException() {
    if (!pendingDepositException?.requestId) return;
    setBoardBusy(true);
    try {
      const { paymentEventId, outcome } = await recordPayment(
        pendingDepositException.journey.id,
        pendingDepositException.amount,
        pendingDepositException.method,
        pendingDepositException.requestId
      );
      if (outcome !== "SUCCEEDED") {
        setPendingReconcile({
          journey: pendingDepositException.journey,
          paymentEventId,
          outcome,
        });
        setPendingDepositException(null);
        return;
      }
      setPendingDepositException(null);
      fetchJourneyEvents(pendingDepositException.journey.id).then(setEvents);
    } catch (e: any) {
      setPendingDepositException((prev) =>
        prev ? { ...prev, error: e.message ?? "Payment failed" } : null
      );
    } finally {
      setBoardBusy(false);
    }
  }

  async function submitBoardPayment(
    journey: JourneyWithDetails,
    amount: number,
    method: string,
    depositApprovalId?: string
  ) {
    try {
      const { paymentEventId, outcome } = await recordPayment(
        journey.id,
        amount,
        method,
        depositApprovalId
      );
      if (outcome !== "SUCCEEDED") {
        setPendingReconcile({
          journey,
          paymentEventId,
          outcome,
        });
        setPendingOverpayment(null);
        return;
      }
      setPendingOverpayment(null);
      setPendingTransition(null);
      setPendingFieldValues({});
      fetchJourneyEvents(journey.id).then(setEvents);
    } catch (e: any) {
      const msg = e.message ?? "";
      if (
        msg.includes("below the required deposit") ||
        msg.includes("below the approved minimum")
      ) {
        setPendingDepositException({ journey, amount, method });
        setPendingOverpayment(null);
        setPendingTransition(null);
        setPendingFieldValues({});
        return;
      }
      window.alert(msg ?? "Failed to record payment");
    }
  }

  async function confirmOverpayment() {
    if (!pendingOverpayment) return;
    setBoardBusy(true);
    try {
      await submitBoardPayment(
        pendingOverpayment.journey,
        pendingOverpayment.amount,
        pendingOverpayment.method
      );
    } finally {
      setBoardBusy(false);
    }
  }

  function cancelOverpayment() {
    setPendingOverpayment(null);
  }

  async function executeAction(journey: JourneyWithDetails, eventType: JourneyEventType) {
    const transition = getTransitionForEvent(journey.current_state, eventType);
    if (!transition) return;

    if (transition.requiredFields && transition.requiredFields.length > 0) {
      setPendingTransition({ journey, transition });
      setPendingFieldValues(
        Object.fromEntries(
          transition.requiredFields.map((f) => [
            f.name,
            f.defaultToday ? localTodayISO() : "",
          ])
        )
      );
      return;
    }

    await executeTransition(journey, transition, {});
  }

  async function submitCancel() {
    if (!cancelJourneyState || !cancelReason.trim()) return;
    setBoardBusy(true);
    try {
      await cancelJourney(cancelJourneyState.id, cancelReason);
      setCancelJourneyState(null);
      setCancelReason("");
    } catch (e: any) {
      window.alert(e.message ?? "Failed to cancel journey");
    } finally {
      setBoardBusy(false);
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
            onClick={() => setShowCalculator(true)}
            className="inline-flex items-center gap-2 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            <Calculator className="h-4 w-4" /> Financing
          </button>
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

        <select
          value={storeFilter}
          onChange={(e) => setStoreFilter(e.target.value)}
          className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
        >
          <option value="active">Active store</option>
          <option value="all">All stores</option>
          {stores.map((s) => (
            <option key={s.id} value={s.id}>
              {s.name}
            </option>
          ))}
        </select>
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
                unresolvedJourneyIds={unresolvedJourneyIds}
                trialEvals={trialEvals}
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
              {journeys
                .filter((j) => !hiddenJourneyIds.has(j.id))
                .map((j) => (
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
                  <td className="px-4 py-2">
                    {j.current_state}
                    {j.sale_kind === "EXCHANGE" && (
                      <span className="ml-1 rounded-full bg-indigo-100 px-1.5 py-px text-[10px] font-medium text-indigo-700">
                        Exchange
                      </span>
                    )}
                  </td>
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
        <JourneyWorkspace
          journey={selectedJourney}
          events={events}
          followUps={followUps}
          employees={employees}
          stores={stores}
          reassignments={reassignments}
          canReassign={canReassignJourneys(currentEmployee?.role)}
          canReconcile={
            currentEmployee?.role === "owner" ||
            currentEmployee?.role === "admin" ||
            currentEmployee?.role === "manager"
          }
          currentEmployee={currentEmployee}
          trialEvals={trialEvals.get(selectedJourney.id) ?? []}
          onReassigned={handleReassigned}
          onClose={() => setSelectedJourney(null)}
          onAction={executeAction}
          onCancel={setCancelJourneyState}
          onRefresh={async () => {
            await handleReassigned(selectedJourney.id);
          }}
        />
      )}

      {pendingTransition && (
        <Modal
          onClose={() => {
            setPendingTransition(null);
            setPendingFieldValues({});
          }}
          dirty={Object.values(pendingFieldValues).some(
            (v) => String(v ?? "").trim() !== ""
          )}
          saving={boardBusy}
        >
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
                        (e.event_type === "deposit_received" ||
                          e.event_type === "payment_completed") &&
                        e.outcome === "SUCCEEDED"
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
                  ) : field.type === "select" ? (
                    <select
                      value={pendingFieldValues[field.name] ?? ""}
                      onChange={(e) =>
                        setPendingFieldValues({
                          ...pendingFieldValues,
                          [field.name]: e.target.value,
                        })
                      }
                      className="mt-1 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                    >
                      <option value="">Select…</option>
                      {field.options?.map((opt) => (
                        <option key={opt} value={opt}>
                          {opt}
                        </option>
                      ))}
                    </select>
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
        </Modal>
      )}

      {pendingReconcile && (
        <Modal onClose={() => setPendingReconcile(null)} saving={boardBusy}>
          <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            <h2 className="mb-2 text-lg font-semibold text-slate-900">
              Payment outcome
            </h2>
            <p className="mb-4 text-sm text-slate-600">
              {pendingReconcile.outcome === "UNKNOWN"
                ? "Confirming payment — please wait. This payment is unresolved and no new payment can be submitted for this order until it is reconciled."
                : "The payment was recorded as failed. No money was collected."}
            </p>
            <div className="flex gap-2">
              <button
                onClick={() => handleReconcile("SUCCEEDED")}
                className="flex-1 rounded-md bg-green-600 px-3 py-2 text-sm font-medium text-white hover:bg-green-700"
              >
                Mark payment succeeded
              </button>
              <button
                onClick={() => handleReconcile("FAILED")}
                className="flex-1 rounded-md bg-red-600 px-3 py-2 text-sm font-medium text-white hover:bg-red-700"
              >
                Mark payment failed
              </button>
            </div>
            <button
              onClick={() => setPendingReconcile(null)}
              className="mt-4 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
            >
              Close
            </button>
          </div>
        </Modal>
      )}

      {pendingDepositException && (
        <Modal
          onClose={() => setPendingDepositException(null)}
          dirty={!!pendingDepositException.reason?.trim()}
          saving={boardBusy}
        >
          <div className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            <h2 className="mb-2 text-lg font-semibold text-slate-900">
              Deposit exception
            </h2>
            <p className="mb-4 text-sm text-slate-600">
              The proposed payment of{" "}
              <strong>${pendingDepositException.amount.toFixed(2)}</strong> is below the
              required deposit for this order.
            </p>

            {pendingDepositException.error && (
              <p className="mb-4 rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-700">
                {pendingDepositException.error}
              </p>
            )}

            {!pendingDepositException.requestId ? (
              <div className="space-y-3">
                <div>
                  <label className="mb-1 block text-sm font-medium text-slate-700">
                    Reason for exception
                  </label>
                  <textarea
                    value={pendingDepositException.reason ?? ""}
                    onChange={(e) =>
                      setPendingDepositException((prev) =>
                        prev ? { ...prev, reason: e.target.value } : null
                      )
                    }
                    className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                    rows={3}
                    placeholder="Explain why this below-floor payment should be accepted"
                  />
                </div>
                <div className="flex gap-2">
                  <button
                    onClick={submitDepositException}
                    disabled={!pendingDepositException.reason?.trim()}
                    className="flex-1 rounded-md bg-amber-600 px-3 py-2 text-sm font-medium text-white hover:bg-amber-700 disabled:opacity-50"
                  >
                    Request approval
                  </button>
                  <button
                    onClick={() => setPendingDepositException(null)}
                    className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                  >
                    Cancel
                  </button>
                </div>
              </div>
            ) : (
              <div className="space-y-3">
                <p className="rounded-md bg-slate-50 p-3 text-sm text-slate-700">
                  Exception request submitted. An owner, admin, or manager must approve it in
                  Settings &gt; Deposit Approvals before the payment can be recorded.
                </p>
                <button
                  onClick={recordPaymentWithException}
                  className="w-full rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700"
                >
                  Try recording payment now
                </button>
                <button
                  onClick={() => setPendingDepositException(null)}
                  className="w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                >
                  Close
                </button>
              </div>
            )}
          </div>
        </Modal>
      )}

      {pendingOverpayment && (
        <Modal onClose={cancelOverpayment} saving={boardBusy}>
          <div className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
            <h2 className="mb-2 text-lg font-semibold text-slate-900">
              Overpayment confirmation
            </h2>
            <p className="mb-4 text-sm text-slate-600">
              This payment is <strong>${pendingOverpayment.credit.toFixed(2)}</strong> more
              than the{" "}
              <strong>${pendingOverpayment.remaining.toFixed(2)}</strong> owed. The customer
              will have a{" "}
              <strong>${pendingOverpayment.credit.toFixed(2)}</strong> credit on their
              account. Continue?
            </p>
            <div className="flex gap-2">
              <button
                onClick={confirmOverpayment}
                className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700"
              >
                Record payment
              </button>
              <button
                onClick={cancelOverpayment}
                className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Cancel
              </button>
            </div>
          </div>
        </Modal>
      )}

      {showCalculator && calculatorCompanyId && (
        <FinancingCalculator
          companyId={calculatorCompanyId}
          onClose={() => setShowCalculator(false)}
        />
      )}

      {cancelJourneyState && (
        <Modal
          onClose={() => setCancelJourneyState(null)}
          dirty={!!cancelReason.trim()}
          saving={boardBusy}
        >
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
        </Modal>
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
  unresolvedJourneyIds,
  trialEvals,
  onSelect,
}: {
  state: SleepJourneyState;
  journeys: JourneyWithDetails[];
  unresolvedJourneyIds: Set<string>;
  trialEvals: Map<string, SleepTrialEvaluation[]>;
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
          <JourneyCard
            key={j.id}
            journey={j}
            hasUnresolvedPayment={unresolvedJourneyIds.has(j.id)}
            trialEvals={trialEvals.get(j.id) ?? []}
            onSelect={onSelect}
          />
        ))}
      </div>
    </div>
  );
}

// One status chip for the board card (spec 19.5) — same color rule as the
// hero's status dot: gray pending, green eligible, amber approval/ending
// soon, red blocked/expired.
function TrialStatusChip({ trial }: { trial: SleepTrialEvaluation }) {
  const status = trial.headline?.status ?? "UNKNOWN";
  const tone = trialStatusTone(status, trial.display?.ending_soon);
  const label =
    status === "ELIGIBLE" && trial.display?.ending_soon
      ? `Ends in ${trial.display.nights_remaining} day${
          trial.display.nights_remaining === 1 ? "" : "s"
        }`
      : status === "ELIGIBLE"
      ? "Eligible"
      : status === "APPROVAL_REQUIRED"
      ? "Needs approval"
      : status === "BLOCKED"
      ? "Blocked"
      : status === "EXPIRED"
      ? "Ended"
      : status === "PENDING"
      ? "Pending"
      : status === "NOT_YET_ELIGIBLE"
      ? "Not yet eligible"
      : trialStatusLabel(trial);
  return (
    <span
      className={`inline-flex items-center gap-1 rounded-full border px-1.5 py-px ${TRIAL_STATUS_CHIP[tone]}`}
    >
      <span className={`h-1.5 w-1.5 rounded-full ${TRIAL_STATUS_DOT[tone]}`} />
      {label}
    </span>
  );
}

function JourneyCard({
  journey,
  hasUnresolvedPayment,
  trialEvals,
  onSelect,
}: {
  journey: JourneyWithDetails;
  hasUnresolvedPayment: boolean;
  trialEvals: SleepTrialEvaluation[];
  onSelect: (j: JourneyWithDetails) => void;
}) {
  const { attributes, listeners, setNodeRef, transform, isDragging } = useDraggable({
    id: journey.id,
  });
  // Most urgent item + "+N more" for multi-mattress orders (spec 19.5).
  const trial = useMemo(() => mostUrgentEvaluation(trialEvals), [trialEvals]);
  const extraTrials = trialEvals.length - 1;

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
      {journey.sale_kind === "EXCHANGE" && (
        <p>
          <span className="inline-block rounded-full bg-indigo-100 px-1.5 py-px text-[10px] font-medium text-indigo-700">
            Exchange
          </span>
        </p>
      )}
      {journey.employee && (
        <p className="truncate text-[10px] leading-tight text-slate-500">
          {journey.employee.name}
        </p>
      )}
      {trial && (
        <p className="flex items-center gap-1 text-[10px] font-medium text-teal-700">
          {trial.display?.night != null
            ? `Night ${trial.display.night} of ${trial.display.length_nights}${
                (trial.display.extension_nights ?? 0) > 0
                  ? ` +${trial.display.extension_nights} ext`
                  : ""
              }`
            : "Sleep trial"}
          <TrialStatusChip trial={trial} />
          {extraTrials > 0 && (
            <span className="text-slate-500">+{extraTrials}</span>
          )}
        </p>
      )}
      {hasUnresolvedPayment && (
        <p className="text-[10px] font-medium text-amber-600">Unresolved payment</p>
      )}
    </div>
  );
}

