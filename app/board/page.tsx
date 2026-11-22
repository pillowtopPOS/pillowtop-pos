"use client";

import { Suspense, useEffect, useMemo, useRef, useState } from "react";
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
import { formatPhone } from "@/lib/format/phone";
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
  selectableStores,
  fetchLiveTrialItemStatuses,
  subscribeToJourneyChanges,
  recordJourneyEvent,
  completeJourneyFulfillment,
  recordJourneyFulfillment,
  fetchJourneyLineItems,
  fetchJourneyFulfillmentSummary,
  fetchJourneysFulfillmentCounts,
  fetchJourneysLineItemQuantities,
  fetchReturnedTrialCounts,
  fetchJourneyRequirementStatuses,
  fetchJourneyLiveTrialStatuses,
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
import { localTodayISO } from "@/lib/dates";
import { computeNetPaid } from "@/lib/journeys/paid";
import {
  effectivePrice,
  returnedPillText,
} from "@/lib/journeys/returns";
import {
  fetchJourneyReturnActions,
  fetchOpenTrialActions,
  hiddenByInProgressAction,
  oldestOpenReturn,
  returnChipStep,
  recordOriginalHandover,
  receiveReturnedUnit,
  originalPickupActionForJourney,
  type ExchangeActionRead,
  type OpenTrialAction,
} from "@/lib/journeys/exchange";
import Modal from "@/components/Modal";
import FinancingCalculator from "@/components/FinancingCalculator";
import JourneyWorkspace from "@/components/journeys/JourneyWorkspace";
import {
  getTransitionForTarget,
  getTransitionForEvent,
  transitionAppliesToFulfillment,
  type JourneyEventType,
  type StateTransition,
} from "@/lib/journeys/state";
import {
  buildCompletionRequest,
  completionNeedsReason,
  completionReasonMet,
  completionShowsDateField,
  completionDestination as completionDestinationFor,
  completionStockTag,
  COMPLETION_COMPLETED_MESSAGE,
  COMPLETION_NO_TRIAL_LINE,
  type CompletionButtonDecision,
  COMPLETION_DRAG_MESSAGE,
  COMPLETION_NOT_IN_STOCK_LINE,
  effectiveLineFulfillment,
  fulfillmentCountLabel,
  fulfillmentMethodChip,
  linePickupLocationId,
  anyRequirementPending,
  completionClosesWithChoice,
  completionConfirmReady,
  completionHandoverLines,
  completionMethodLines,
  completionStepperLine,
  joinLocationNames,
  OTHER_ITEMS_STAY_OPEN_NOTE,
  otherMethodItemsRemain,
  pickupLocationIds,
  pickupLocationNote,
  remainingUnits,
  STOCK_TAG_LABEL,
  type CompletionStepperLine,
  originalPickupOutcomeForMethod,
  originalHandoverLocationDefault,
} from "@/lib/journeys/completion";
import { effectiveShipTo, formatShipToLine } from "@/lib/customers/shipTo";
import type { JourneyLineItem } from "@/lib/journeys/queries";
import { hasPermission } from "@/lib/inventory/queries";

// A journey whose every live trial item is parked mid-exchange leaves the
// board lists (the replacement order represents it); a journey parked by
// a return stays visible with a violet chip. Display-only either way:
// the journey still opens by id. The rule itself lives in
// lib/journeys/exchange (hiddenByInProgressAction).

function BoardContent() {
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
  // Units already handed over and total units per board journey, from
  // the two batched reads in loadData. Empty maps mean the read failed:
  // the badge renders nothing rather than wrong numbers.
  const [fulfillmentCounts, setFulfillmentCounts] = useState<Record<string, number>>({});
  const [journeyUnitTotals, setJourneyUnitTotals] = useState<Record<string, { units: number; hasPickupLine: boolean; hasDeliveryLine: boolean }>>({});
  // Slice 2b: closed-RETURNED vs total trial items per journey, for the
  // card's "returned" pill.
  const [returnedTrialCounts, setReturnedTrialCounts] = useState<
    Record<string, { returned: number; total: number }>
  >({});
  // Journeys whose every live trial item is parked in an exchange/return
  // stay off the board lists — they still open by id everywhere else.
  // 163: live item statuses plus the committed-action worklist decide it
  // (a committed RETURN keeps its journey on the board).
  const [liveItemStatuses, setLiveItemStatuses] = useState<
    Map<string, string[]>
  >(new Map());
  const [openActions, setOpenActions] = useState<OpenTrialAction[]>([]);
  const hiddenJourneyIds = useMemo(
    () => hiddenByInProgressAction(liveItemStatuses, openActions),
    [liveItemStatuses, openActions]
  );
  // Journey ids with any committed action - the table view's
  // "Exchanges and returns" filter, including exchange-parked originals.
  const openActionJourneyIds = useMemo(
    () => new Set(openActions.map((a) => a.journey_id)),
    [openActions]
  );
  // Oldest committed return per journey -> the violet board chip.
  const returnChipByJourney = useMemo(() => {
    const m = new Map<string, { step: string | null }>();
    const byJourney = new Map<string, OpenTrialAction[]>();
    for (const a of openActions) {
      const list = byJourney.get(a.journey_id) ?? [];
      list.push(a);
      byJourney.set(a.journey_id, list);
    }
    byJourney.forEach((list, journeyId) => {
      const ret = oldestOpenReturn(list);
      if (ret) m.set(journeyId, { step: returnChipStep(ret) });
    });
    return m;
  }, [openActions]);
  const [loading, setLoading] = useState(true);
  // One-shot notice left by /journeys/new when the order saved but the
  // optional company contact person could not be inserted.
  const [contactNotice, setContactNotice] = useState<string | null>(null);

  const [view, setView] = useState<"board" | "table">("board");
  const [tableActionsOnly, setTableActionsOnly] = useState(false);
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
    // The fulfillment method the completion dialog acts on. Defaults to
    // the order's own type; the panel's pickup control passes "pickup"
    // for delivery orders with pickup lines.
    method?: "pickup" | "delivery";
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
  const [cancelError, setCancelError] = useState<string | null>(null);
  const [cancelNetPaid, setCancelNetPaid] = useState<number | null>(null);
  const [cancelJourneyState, setCancelJourneyState] = useState<JourneyWithDetails | null>(null);
  const cancelInFlight = useRef(false);
  const [boardError, setBoardError] = useState<string | null>(null);
  const [modalError, setModalError] = useState<string | null>(null);
  const [boardBusy, setBoardBusy] = useState(false);
  const [showCalculator, setShowCalculator] = useState(false);
  // orders.backdate_fulfillment gates the earlier-date field in the
  // completion dialog; fetched once per board mount.
  const [canBackdateFulfillment, setCanBackdateFulfillment] = useState(false);
  // orders.pickup_any_location unlocks every location's pickup steppers
  // in the completion dialog; without it only the active location is
  // editable. Fetched once per board mount.
  const [canPickupAnyLocation, setCanPickupAnyLocation] = useState(false);
  const [canRecordRefund, setCanRecordRefund] = useState(false);
  const [canAdjustRefund, setCanAdjustRefund] = useState(false);
  // Per-line stepper values in the completion dialog. Lines absent here
  // default to their full remaining quantity; locked or out-of-stock
  // lines always count as zero.
  const [completionQty, setCompletionQty] = useState<Record<string, number>>({});
  const completionInFlight = useRef(false);
  // Paid total fetched fresh each time the completion dialog opens; the
  // panel's events feed can be empty or belong to another journey, so
  // it cannot be trusted for the balance line.
  const [completionPaid, setCompletionPaid] = useState<{
    journeyId: string;
    status: "loading" | "loaded" | "failed";
    paid: number;
  } | null>(null);
  // Everything the completion dialog lists under "What you are handing
  // over": line items, per-variant requirement status, and the booked
  // delivery date. Fetched fresh each time the dialog opens; status is
  // loading until the reads land and failed when they cannot.
  const [completionHandover, setCompletionHandover] = useState<{
    journeyId: string;
    status: "loading" | "loaded" | "failed";
    items: JourneyLineItem[];
    byLine: Record<string, number>;
    reqStatus: Record<string, string>;
    bookedDate: string | null;
  } | null>(null);
  // Set when the RPC reports the order went straight to Completed (no
  // live sleep trial item). The panel shows a short green note.
  const [completionDoneFor, setCompletionDoneFor] = useState<string | null>(null);
  // 165: the exchange action behind the order being completed, plus the
  // caller's answer to the old-mattress question. An unanswered question
  // never blocks completion.
  const [completionExchangeAction, setCompletionExchangeAction] =
    useState<OpenTrialAction | null>(null);
  const [oldMattressAnswer, setOldMattressAnswer] = useState<
    "" | "brought" | "kept"
  >("");
  const [oldMattressReason, setOldMattressReason] = useState("");
  const [oldMattressLocationId, setOldMattressLocationId] = useState("");
  const [completionCanReceive, setCompletionCanReceive] = useState(false);
  const completionFulfillmentSaved = useRef<string | null>(null);
  // What the open panel reports about completion: the gated decision
  // (button/note/hidden) and the state the order will land in. The
  // dialog reads this so its note and destination match the panel.
  const [panelCompletionInfo, setPanelCompletionInfo] = useState<{
    journeyId: string;
    decision: CompletionButtonDecision | null;
    goesTo: "Sleep Trial" | "Completed";
    closing: boolean;
  } | null>(null);
  // Live trial item statuses for the dialog's journey, read fresh every
  // time the completion dialog opens. null while loading or on error:
  // the destination then stays "unknown" (Sleep Trial, no no-trial line).
  const [dialogTrialStatuses, setDialogTrialStatuses] = useState<{
    journeyId: string;
    statuses: string[] | null;
  } | null>(null);
  // RETURN actions for the dialog's journey (2b): the balance line uses
  // the effective price once they are known.
  const [completionReturns, setCompletionReturns] = useState<{
    journeyId: string;
    actions: ExchangeActionRead[];
  } | null>(null);
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

  const loadData = async (
    u: any,
    active: string | null | undefined,
    opts?: { background?: boolean }
  ) => {
    if (!opts?.background) setLoading(true);
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

    // Slice 2a: one batched read each for handed-over units and total
    // units on every journey on the board. Both feed the "N of M items
    // out" badge and the trial-chip filter below. A failed read returns
    // an empty map, which shows no badges rather than wrong numbers.
    const ids = data.map((j) => j.id);
    const [fulfillCounts, unitTotals, returnedCounts] = await Promise.all([
      fetchJourneysFulfillmentCounts(ids),
      fetchJourneysLineItemQuantities(data),
      fetchReturnedTrialCounts(ids),
    ]);
    setFulfillmentCounts(fulfillCounts);
    setJourneyUnitTotals(unitTotals);
    setReturnedTrialCounts(returnedCounts);

    // Trial status comes from the evaluator (ST-4) — one batch call for
    // every journey sitting in the Sleep Trial column, plus any journey
    // with handed-over units whose trial may already be running.
    evaluateSleepTrialItems(
      data
        .filter(
          (j) =>
            j.current_state === "Sleep Trial" || (fulfillCounts[j.id] ?? 0) > 0
        )
        .map((j) => j.id)
    ).then(setTrialEvals);

    const supabase = createClient();
    const [{ data: unresolved }, trialItemStatuses, trialActions] =
      await Promise.all([
        supabase
          .from("journey_events")
          .select("journey_id")
          .in("event_type", ["deposit_received", "payment_completed"])
          .eq("outcome", "UNKNOWN"),
        fetchLiveTrialItemStatuses(),
        // 163: the committed-action worklist drives the hide rule (a
        // committed RETURN keeps its journey on the board) and the
        // violet Return-in-progress chip. One batched read, same
        // Promise.all as the other badge fetches.
        fetchOpenTrialActions(),
      ]);
    setUnresolvedJourneyIds(
      new Set((unresolved ?? []).map((e: { journey_id: string }) => e.journey_id))
    );
    setLiveItemStatuses(trialItemStatuses);
    setOpenActions(trialActions);

    if (!opts?.background) setLoading(false);
  };

  useEffect(() => {
    try {
      const msg = window.sessionStorage.getItem(
        "pt_new_order_contact_warning"
      );
      if (msg) {
        window.sessionStorage.removeItem("pt_new_order_contact_warning");
        setContactNotice(msg);
      }
    } catch {
      // sessionStorage unavailable; the notice is best-effort.
    }
  }, []);

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

    // A single user action writes several rows in quick succession (a
    // payment inserts journey_events, derive_journey_state updates
    // sleep_journeys, the inventory evaluator may write more of both).
    // Each write is a separate postgres_changes event, so without
    // coalescing one payment fires loadData half a dozen times and the
    // board visibly strobes. Debounce to one silent background reload.
    let changesTimer: ReturnType<typeof setTimeout> | null = null;
    const unsubscribe = subscribeToJourneyChanges(() => {
      if (changesTimer) clearTimeout(changesTimer);
      changesTimer = setTimeout(() => {
        changesTimer = null;
        supabase.auth.getSession().then(({ data: { session } }) => {
          if (session?.user) {
            loadData(session.user, session.user.user_metadata?.active_store_id, {
              background: true,
            });
          }
        });
      }, 400);
    });

    return () => {
      unsubscribe();
      if (changesTimer) clearTimeout(changesTimer);
    };
  }, [router, search, employeeFilter, storeFilter]);

  // Set by handleReassigned after it writes fresh panel data itself —
  // the effect below must not immediately refetch the same rows.
  const panelDataFreshFor = useRef<string | null>(null);
  useEffect(() => {
    if (selectedJourney) {
      if (panelDataFreshFor.current === selectedJourney.id) {
        panelDataFreshFor.current = null;
        return;
      }
      fetchJourneyEvents(selectedJourney.id).then(setEvents);
      fetchJourneyFollowUps(selectedJourney.id).then(setFollowUps);
      fetchJourneyReassignments(selectedJourney.id).then(setReassignments);
    } else {
      setReassignments([]);
    }
  }, [selectedJourney]);

  // The cancel modal's paid warning reads this journey's events fetched
  // at open time — not the open panel's feed, which can be mid-flight or
  // for a different journey. A failed fetch hides the warning rather
  // than showing a wrong number; a payment recorded moments earlier is
  // included because the fetch is fresh.
  useEffect(() => {
    if (!cancelJourneyState) {
      setCancelNetPaid(null);
      return;
    }
    setCancelError(null);
    const journeyId = cancelJourneyState.id;
    let alive = true;
    fetchJourneyEvents(journeyId)
      .then((evs) => {
        if (alive) setCancelNetPaid(computeNetPaid(evs));
      })
      .catch(() => {
        if (alive) setCancelNetPaid(null);
      });
    return () => {
      alive = false;
    };
  }, [cancelJourneyState]);

  const [journeyRefreshPending, setJourneyRefreshPending] = useState(false);

  // One fetch for everything the open panel renders, applied in a single
  // batch — journey row, events, follow-ups and reassignments can never
  // show mismatched generations (e.g. fresh "Paid in full" events under
  // a stale "Quoted" header).
  // Returned-count badges and trial evaluations live outside the journey
  // row, and trial-item closes do not always write an event the board
  // subscribes to, so the panel refresh and drawer close refetch them for
  // just this journey.
  async function refreshTrialBadgeData(journeyId: string) {
    const [countMap, evalMap, trialActions] = await Promise.all([
      fetchReturnedTrialCounts([journeyId]),
      // Panel actions (protector override, trial-start correction, an
      // auto-completed return, ...) can change the item's evaluation -
      // refresh just this journey's evals so the board card behind the
      // panel isn't stale until the next loadData.
      evaluateSleepTrialItems([journeyId]),
      // The worklist feeds the Return-in-progress chip and the hide
      // rule; a panel action can flip either one.
      fetchOpenTrialActions(),
    ]);
    setReturnedTrialCounts((prev) => ({ ...prev, ...countMap }));
    setOpenActions(trialActions);
    setTrialEvals((prev) => {
      const next = new Map(prev);
      const evals = evalMap.get(journeyId) ?? [];
      if (evals.length > 0) next.set(journeyId, evals);
      else next.delete(journeyId);
      return next;
    });
  }

  async function handleReassigned(journeyId: string) {
    setJourneyRefreshPending(true);
    try {
      const [fresh, history, evs, fus] = await Promise.all([
        fetchJourneyById(journeyId),
        fetchJourneyReassignments(journeyId),
        fetchJourneyEvents(journeyId),
        fetchJourneyFollowUps(journeyId),
      ]);
      setReassignments(history);
      setEvents(evs);
      setFollowUps(fus);
      if (fresh) {
        setSelectedJourney(fresh);
        setJourneys((prev) => prev.map((j) => (j.id === fresh.id ? fresh : j)));
        panelDataFreshFor.current = journeyId;
      }
      // fresh === null means fetchJourneyById errored (it returns null on
      // any failure, not only not-found). Journeys are never hard-deleted,
      // so keep the panel on the last good data instead of closing it and
      // any open dialog with it.
      // Panel actions (committing/cancelling an exchange) change trial-item
      // statuses, so the board-hide inputs are refreshed alongside the
      // journey (the worklist itself refreshes in refreshTrialBadgeData).
      fetchLiveTrialItemStatuses().then(setLiveItemStatuses);
      await refreshTrialBadgeData(journeyId);
    } finally {
      setJourneyRefreshPending(false);
    }
  }

  useEffect(() => {
    hasPermission("orders.backdate_fulfillment").then(setCanBackdateFulfillment);
    hasPermission("orders.pickup_any_location").then(setCanPickupAnyLocation);
    hasPermission("payments.record_refund").then(setCanRecordRefund);
    hasPermission("payments.adjust_refund_amount").then(setCanAdjustRefund);
  }, []);

  useEffect(() => {
    const journeyId = searchParams.get("journey");
    if (journeyId) {
      handleReassigned(journeyId);
    }
  }, [searchParams]);

  // The completion dialog's balance must be fresh: it can open from a
  // card drag or card button while the panel's events feed is empty or
  // still showing a different journey. Return actions are read for every
  // transition so a committed return lowers the shown balance.
  useEffect(() => {
    if (!pendingTransition) {
      setCompletionPaid(null);
      setCompletionHandover(null);
      setDialogTrialStatuses(null);
      setCompletionReturns(null);
      setCompletionExchangeAction(null);
      setOldMattressAnswer("");
      setOldMattressReason("");
      setOldMattressLocationId("");
      // The dialog is closed (or is not a completion): an in-flight
      // flag from an unmounted attempt can never be relevant again.
      completionInFlight.current = false;
      completionFulfillmentSaved.current = null;
      return;
    }
    const journeyId = pendingTransition.journey.id;
    let alive = true;
    setCompletionReturns(null);
    // 165: when this order is an exchange replacement, the completion
    // dialog asks what happened to the old mattress.
    fetchOpenTrialActions()
      .then((rows) => {
        if (!alive) return;
        const a = originalPickupActionForJourney(rows, journeyId);
        setCompletionExchangeAction(a);
        if (a?.original_pickup_outcome === "PICKED_UP" ||
            a?.original_pickup_outcome === "HANDED_OVER") {
          setOldMattressAnswer("brought");
          if (a.original_pickup_outcome === "HANDED_OVER") {
            setOldMattressLocationId(
              a.original_pickup_location_id ?? ""
            );
          }
        } else if (a?.original_pickup_outcome) {
          setOldMattressAnswer("kept");
          setOldMattressReason(a.original_pickup_reason ?? "");
        }
      })
      .catch(() => {});
    const supa = createClient();
    supa
      .rpc("has_permission", { p_key: "inventory.inspect_returns" })
      .then(({ data }) => {
        if (data) {
          if (alive) setCompletionCanReceive(true);
          return;
        }
        supa.auth.getUser().then(({ data: u }) => {
          if (!u.user) return;
          supa
            .from("employees")
            .select("home_store_id")
            .eq("auth_user_id", u.user.id)
            .eq("is_active", true)
            .maybeSingle()
            .then(({ data: emp }) => {
              const t = stores.find(
                (st) => st.id === (emp as any)?.home_store_id
              )?.location_type;
              if (alive && t === "WAREHOUSE") setCompletionCanReceive(true);
            });
        });
      });
    fetchJourneyEvents(journeyId)
      .then((evs) => fetchJourneyReturnActions(journeyId, evs))
      .then((actions) => {
        if (alive) setCompletionReturns({ journeyId, actions });
      })
      .catch(() => {
        // An empty list shows the unadjusted balance - same as before
        // 2b - instead of hiding the number on a read failure.
        if (alive) setCompletionReturns({ journeyId, actions: [] });
      });
    if (pendingTransition.transition.event !== "delivery_completed") {
      setCompletionPaid(null);
      setCompletionHandover(null);
      setDialogTrialStatuses(null);
      completionInFlight.current = false;
      return () => {
        alive = false;
      };
    }
    setCompletionQty({});
    // Trial items bind when the order reaches Sold and when lines change,
    // so the panel's earlier read can be stale. Read again at the moment
    // the dialog opens; until it lands the destination is unknown.
    setDialogTrialStatuses({ journeyId, statuses: null });
    fetchJourneyLiveTrialStatuses(journeyId)
      .then((statuses) => {
        if (alive) setDialogTrialStatuses({ journeyId, statuses });
      })
      .catch(() => {
        if (alive) setDialogTrialStatuses({ journeyId, statuses: null });
      });
    fetchTotalPaid(journeyId)
      .then((paid) => {
        if (alive) {
          setCompletionPaid({ journeyId, status: "loaded", paid });
        }
      })
      .catch((e) => {
        console.error("completion dialog balance read failed", e);
        if (alive) {
          setCompletionPaid({ journeyId, status: "failed", paid: 0 });
        }
      });
    setCompletionHandover({
      journeyId,
      status: "loading",
      items: [],
      byLine: {},
      reqStatus: {},
      bookedDate: null,
    });
    Promise.all([
      fetchJourneyLineItems(journeyId),
      fetchJourneyRequirementStatuses(journeyId),
      fetchJourneyEvents(journeyId),
      fetchJourneyFulfillmentSummary(journeyId),
    ])
      .then(([items, reqStatus, evs, summary]) => {
        if (!alive) return;
        const bookedDate =
          [...evs]
            .filter(
              (e) =>
                e.event_type === "delivery_scheduled" &&
                e.event_data?.delivery_date
            )
            .map((e) => String(e.event_data?.delivery_date))
            .pop() ?? null;
        setCompletionHandover({
          journeyId,
          status: "loaded",
          items,
          byLine: summary.byLine,
          reqStatus,
          bookedDate,
        });
      })
      .catch((e) => {
        console.error("completion dialog handover read failed", e);
        if (alive) {
          setCompletionHandover({
            journeyId,
            status: "failed",
            items: [],
            byLine: {},
            reqStatus: {},
            bookedDate: null,
          });
        }
      });
    return () => {
      alive = false;
    };
  }, [pendingTransition]);

  const boardJourneys = useMemo(() => {
    return journeys.filter(
      // The open panel's journey stays mounted until the panel closes —
      // unmounting its card mid-commit (a dnd-kit ref-detach inside the
      // same render as the panel's cancelled-state flip) crashed React's
      // reconciler with removeChild-not-a-child. A hidden journey (for
      // example an exchange-parked original) also stays while a search is
      // active: it only reaches this list by matching the search.
      (j) =>
        j.id === selectedJourney?.id ||
        (!j.cancelled_at &&
          (!hiddenJourneyIds.has(j.id) || search.trim() !== ""))
    );
  }, [journeys, hiddenJourneyIds, selectedJourney?.id, search]);

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
    setBoardError(null);
    const { active, over } = event;
    if (!over) return;

    const journeyId = active.id as string;
    const targetState = over.id as SleepJourneyState;
    const journey = journeys.find((j) => j.id === journeyId);
    if (!journey) return;

    if (journey.current_state === targetState) return;

    const transition = getTransitionForTarget(journey.current_state, targetState);
    if (
      !transition ||
      !transitionAppliesToFulfillment(transition, journey.fulfillment_type)
    ) {
      setBoardError(`Cannot move directly from ${journey.current_state} to ${targetState}`);
      return;
    }

    // Completion is panel-only now: a drop onto Sleep Trial (or any
    // delivery_completed transition) never opens a dialog or writes
    // anything. The order must be opened and its own button used.
    if (transition.event === "delivery_completed") {
      setBoardError(COMPLETION_DRAG_MESSAGE);
      return;
    }

    // Completion always opens the dialog (date + reason rules live
    // there), even though the transition carries no requiredFields.
    if (
      transition.requiredFields &&
      transition.requiredFields.length > 0
    ) {
      setPendingTransition({ journey, transition });
      setPendingFieldValues(
        Object.fromEntries(
          (transition.requiredFields ?? []).map((f) => [
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
    fieldValues: Record<string, string>,
    // The exact lines the completion dialog will hand over, when the
    // caller is the unified completion dialog. null/undefined means the
    // legacy whole-order path (zero-line orders and non-dialog callers).
    fulfillmentLines?: { lineItemId: string; quantity: number }[] | null
  ) {
    const supabase = createClient();
    let session;
    try {
      const res = await Promise.race([
        supabase.auth.getSession(),
        new Promise<never>((_, reject) =>
          setTimeout(() => reject(new Error("sign-in check timed out")), 12000)
        ),
      ]);
      session = res.data.session;
    } catch {
      setModalError(
        "Could not confirm your sign-in in time (12 seconds). Please reload the page and try again."
      );
      return;
    }
    if (!session?.user || !isStoreConfirmedToday(session.user)) {
      // This gate used to push to store-select with no message: the
      // dialog unmounted mid-navigation and the click looked like it
      // did nothing. Say why, then navigate a beat later so the text
      // is actually read.
      setModalError(
        "Your store is not confirmed for today, so this could not be recorded. Taking you to the store picker now."
      );
      setTimeout(() => router.push(storeSelectUrl("/board")), 1500);
      return;
    }

    const eventData: Record<string, unknown> = {};

    for (const field of transition.requiredFields ?? []) {
      if (!field.optional && !fieldValues[field.name]) {
        setModalError(`${field.label} is required`);
        return;
      }
      if (fieldValues[field.name]) {
        eventData[field.name] =
          field.type === "number" ? Number(fieldValues[field.name]) : fieldValues[field.name];
      }
    }

    // Completion goes through record_journey_fulfillment with the
    // dialog's chosen lines, or complete_journey_fulfillment for the
    // legacy whole-order path (zero-line orders). Both RPCs enforce
    // permissions, state rules, and backdate reasons, and their
    // plain-English errors are shown as returned. The date field only
    // exists for users with orders.backdate_fulfillment; a date is sent
    // only when it differs from today.
    if (transition.event === "delivery_completed") {
      if (completionInFlight.current) {
        setModalError("This order is already being recorded. Give it a moment.");
        return;
      }
      if (
        completionExchangeAction &&
        oldMattressAnswer === "kept" &&
        !oldMattressReason.trim()
      ) {
        setModalError(
          `Say why the old mattress was ${
            completionMethod === "pickup" ? "not handed over" : "not picked up"
          }.`
        );
        return;
      }
      const request = buildCompletionRequest({
        canBackdate: canBackdateFulfillment,
        completedOn: fieldValues.completed_on,
        reason: fieldValues.backdate_reason,
      });
      if (request.error) {
        setModalError(request.error);
        return;
      }
      completionInFlight.current = true;
      setModalError(null);
      setBoardBusy(true);
      try {
        // A retry after a failed handover save must not record the
        // fulfillment twice - it stays recorded no matter what.
        if (completionFulfillmentSaved.current !== journey.id) {
          const result = await Promise.race([
            fulfillmentLines
              ? recordJourneyFulfillment(journey.id, fulfillmentLines, {
                  completedOn: request.completedOn,
                  reason: request.reason,
                })
              : completeJourneyFulfillment(journey.id, {
                  completedOn: request.completedOn,
                  reason: request.reason,
                }),
            new Promise<never>((_, reject) =>
              setTimeout(() => reject(new Error("rpc timed out")), 30000)
            ),
          ]);
          completionFulfillmentSaved.current = journey.id;
          // m149: an order with no live sleep trial item lands on
          // Completed, off the board. The panel shows a short green note.
          setCompletionDoneFor(
            result?.state === "Completed" ? journey.id : null
          );
        }
        // 165: the old-mattress answer saves after the fulfillment and
        // can never roll it back. A handed-over unit at a location with
        // a quarantine area is received in the same step when the caller
        // may receive.
        if (completionExchangeAction && oldMattressAnswer !== "") {
          const outcome = originalPickupOutcomeForMethod(
            completionMethod ?? "delivery",
            oldMattressAnswer === "brought"
          );
          const handoverLoc =
            outcome === "HANDED_OVER"
              ? oldMattressLocationId ||
                originalHandoverLocationDefault({
                  pickupLocationIds: completionDialogLines.map(
                    (li) =>
                      (li as { pickup_location_id?: string | null })
                        .pickup_location_id ?? null
                  ),
                  assignedWarehouseId: stores.find(
                    (st) => st.id === journey.store_id
                  )?.assigned_warehouse_id,
                  warehouses: stores.filter(
                    (st) => st.location_type === "WAREHOUSE"
                  ),
                  orderStoreId: journey.store_id,
                })
              : null;
          try {
            await recordOriginalHandover(
              completionExchangeAction.action_id,
              outcome,
              handoverLoc,
              oldMattressAnswer === "kept"
                ? oldMattressReason.trim()
                : null
            );
          } catch {
            setModalError(
              `${
                completionMethod === "delivery" ? "Delivered" : "Picked up"
              }, but the old mattress answer was not saved. Record it from the exchange card.`
            );
            return;
          }
          if (
            outcome === "HANDED_OVER" &&
            handoverLoc &&
            completionCanReceive &&
            stores.some(
              (st) =>
                st.location_type === "WAREHOUSE_QUARANTINE" &&
                st.parent_location_id === handoverLoc
            )
          ) {
            try {
              await receiveReturnedUnit(
                completionExchangeAction.action_id,
                handoverLoc,
                localTodayISO()
              );
            } catch {
              setModalError(
                "Handed over, but not marked received. Mark it received from the exchange card."
              );
              return;
            }
          }
        }
        setPendingTransition(null);
        setPendingFieldValues({});
        await handleReassigned(journey.id);
      } catch (e: any) {
        setModalError(
          e?.message === "rpc timed out"
            ? "The server did not answer in 30 seconds. Nothing was recorded. Please try again."
            : e.message ?? "Failed to mark the order fulfilled"
        );
      } finally {
        completionInFlight.current = false;
        setBoardBusy(false);
      }
      return;
    }

    setModalError(null);
    setBoardBusy(true);
    try {
      if (transition.event === "payment_completed") {
        const amount = parseFloat(fieldValues.amount ?? "0");
        const method = fieldValues.payment_method ?? "";

        if (journey.price == null) {
          setModalError("Journey has no price set");
          return;
        }
        if (journey.price <= 0) {
          setModalError("No payment is due on this journey.");
          return;
        }

        const totalPaid = await fetchTotalPaid(journey.id);
        // 2b: a committed/completed return lowers what is still owed;
        // collecting the unadjusted remainder would overcharge.
        const returnActions = await fetchJourneyReturnActions(
          journey.id,
          events
        ).catch(() => []);
        const remaining =
          effectivePrice(journey.price, returnActions) - totalPaid;

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
        await handleReassigned(journey.id);
      }
    } catch (e: any) {
      setModalError(e.message ?? "Failed to record event");
    } finally {
      setBoardBusy(false);
    }
  }

  async function handleReconcile(newOutcome: PaymentOutcome) {
    if (!pendingReconcile) return;
    setModalError(null);
    setBoardBusy(true);
    try {
      await reconcilePayment(pendingReconcile.paymentEventId, newOutcome);
      await handleReassigned(pendingReconcile.journey.id);
      setPendingReconcile(null);
    } catch (e: any) {
      setModalError(e.message ?? "Reconciliation failed");
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
      await handleReassigned(pendingDepositException.journey.id);
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
    setModalError(null);
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
      await handleReassigned(journey.id);
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
      setModalError(msg ?? "Failed to record payment");
    }
  }

  async function confirmOverpayment() {
    if (!pendingOverpayment) return;
    setModalError(null);
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

  // Selecting a different journey clears the Completed notice so it can
  // never bleed onto another order's panel.
  function selectJourney(j: JourneyWithDetails | null) {
    if (j?.id !== selectedJourney?.id) {
      setCompletionDoneFor(null);
      setPanelCompletionInfo(null);
    }
    setSelectedJourney(j);
  }

  async function executeAction(
    journey: JourneyWithDetails,
    eventType: JourneyEventType,
    opts?: { fulfillmentMethod?: "pickup" | "delivery" }
  ) {
    // The completion dialog is scoped to one fulfillment method. The
    // order's own method follows the transition table; the panel can
    // also open it for the other method (pickup lines on a delivery
    // order) from states the transition list does not cover, so the
    // dialog opens for delivery_completed regardless.
    if (eventType === "delivery_completed") {
      const transition = getTransitionForEvent(
        journey.current_state,
        eventType
      ) ?? {
        to: "Sleep Trial" as SleepJourneyState,
        event: "delivery_completed" as const,
        label: "Mark picked up",
      };
      setPendingTransition({
        journey,
        transition,
        method: opts?.fulfillmentMethod,
      });
      setPendingFieldValues({});
      return;
    }

    const transition = getTransitionForEvent(journey.current_state, eventType);
    if (
      !transition ||
      !transitionAppliesToFulfillment(transition, journey.fulfillment_type)
    ) {
      return;
    }

    if (
      transition.requiredFields &&
      transition.requiredFields.length > 0
    ) {
      setPendingTransition({ journey, transition });
      setPendingFieldValues(
        Object.fromEntries(
          (transition.requiredFields ?? []).map((f) => [
            f.name,
            f.defaultToday ? localTodayISO() : "",
          ])
        )
      );
      return;
    }

    await executeTransition(journey, transition, {});
  }

  // A modal must never open with a stale error from the last one.
  useEffect(() => {
    setModalError(null);
  }, [pendingTransition, pendingReconcile, pendingOverpayment]);

  async function submitCancel() {
    if (!cancelJourneyState) return;
    if (!cancelReason.trim()) {
      setCancelError("Enter a reason to cancel.");
      return;
    }
    // Already cancelled (stale panel prop): closing is a no-op, never a
    // second journey_cancelled insert.
    if (cancelJourneyState.cancelled_at) {
      setCancelJourneyState(null);
      setCancelReason("");
      return;
    }
    // Ref guard: boardBusy lags a render behind the click, so a fast
    // double-click can still reach here twice.
    if (cancelInFlight.current) return;
    cancelInFlight.current = true;
    setBoardBusy(true);
    setCancelError(null);
    const journeyId = cancelJourneyState.id;
    try {
      await cancelJourney(journeyId, cancelReason);
    } catch (e: any) {
      setCancelError(e.message ?? "Failed to cancel journey");
      setBoardBusy(false);
      cancelInFlight.current = false;
      return;
    }
    // The insert succeeded. Refresh the journey/feed BEFORE closing the
    // modal — the panel's cancelled-state flip and this modal's unmount
    // then commit as separate renders. A refresh hiccup is logged, never
    // surfaced as a failed cancel.
    try {
      await handleReassigned(journeyId);
    } catch (e) {
      console.error("post-cancel refresh failed", e);
    }
    setCancelJourneyState(null);
    setCancelReason("");
    setBoardBusy(false);
    cancelInFlight.current = false;
  }

  const completionIsOpen =
    pendingTransition?.transition.event === "delivery_completed";
  const completionHandoverState =
    completionIsOpen &&
    completionHandover?.journeyId === pendingTransition.journey.id
      ? completionHandover.status
      : "loading";
  const completionPaidLoaded =
    completionIsOpen &&
    completionPaid?.journeyId === pendingTransition.journey.id &&
    completionPaid.status === "loaded";
  const completionReadsReady = completionConfirmReady({
    handoverState: completionHandoverState,
    paidLoaded: completionPaidLoaded,
  });

  // The method this dialog is acting on: the order's own type unless the
  // panel opened it for the other method (pickup lines on a delivery
  // order). Everything below is scoped to this one method.
  const completionMethod =
    completionIsOpen && pendingTransition
      ? pendingTransition.method ?? pendingTransition.journey.fulfillment_type
      : null;

  // Lines of the dialog's method with units still left to hand over.
  const completionDialogLines =
    completionIsOpen &&
    completionMethod &&
    completionHandover?.journeyId === pendingTransition.journey.id &&
    completionHandover.status === "loaded"
      ? completionMethodLines({
          orderFulfillment: pendingTransition.journey.fulfillment_type,
          method: completionMethod,
          items: completionHandover.items,
          handed: completionHandover.byLine,
        })
      : [];
  const completionHandoverLoaded =
    completionIsOpen &&
    completionHandover?.journeyId === pendingTransition.journey.id &&
    completionHandover.status === "loaded";
  // Confirm stays disabled while a delivery line's requirement is still
  // pending. The RPC refuses the write too, but the dialog should never
  // offer a button that cannot succeed. Pickup lines with a pending
  // requirement get a locked stepper instead.
  const completionBlocksConfirm =
    completionMethod === "delivery" &&
    completionHandoverLoaded &&
    anyRequirementPending(
      completionDialogLines.map((item) =>
        item.product_id
          ? completionHandover!.reqStatus[item.product_id]
          : null
      )
    );

  // Where the signed-in employee works today, for the pickup steppers'
  // location lock. Same fallback as the RPC's location checks.
  const completionActiveStoreId =
    activeStoreId ?? currentEmployee?.home_store_id ?? null;

  // Units each dialog line will hand over: the stepper value for pickup
  // (locked and out-of-stock lines always 0), the full remaining count
  // for delivery.
  const completionPickupInfo = new Map<string, CompletionStepperLine>();
  const completionChosen: Record<string, number> = {};
  if (completionHandoverLoaded && completionMethod) {
    for (const li of completionDialogLines) {
      if (completionMethod === "pickup") {
        const info = completionStepperLine(li, pendingTransition.journey.store_id, {
          handed: completionHandover!.byLine,
          reqStatus: completionHandover!.reqStatus,
          canPickupAnyLocation,
          activeStoreId: completionActiveStoreId,
        });
        completionPickupInfo.set(li.id, info);
        completionChosen[li.id] = info.editable
          ? Math.min(completionQty[li.id] ?? info.remaining, info.remaining)
          : 0;
      } else {
        completionChosen[li.id] = remainingUnits(
          li,
          completionHandover!.byLine
        );
      }
    }
  }
  const completionTotalChosen = completionDialogLines.reduce(
    (sum, li) => sum + (completionChosen[li.id] ?? 0),
    0
  );
  const completionOthersStayOpen =
    completionHandoverLoaded && completionMethod
      ? otherMethodItemsRemain({
          orderFulfillment: pendingTransition.journey.fulfillment_type,
          method: completionMethod,
          items: completionHandover!.items,
          handed: completionHandover!.byLine,
        })
      : false;
  // Whether this Confirm closes the order, judged on the chosen
  // quantities. null while the reads are still landing.
  const completionClosesNow =
    completionHandoverLoaded && completionMethod
      ? completionClosesWithChoice({
          orderFulfillment: pendingTransition.journey.fulfillment_type,
          method: completionMethod,
          items: completionHandover!.items,
          handed: completionHandover!.byLine,
          chosen: completionChosen,
        })
      : null;

  // The lines the Confirm button sends. null means the legacy
  // whole-order path, used only by orders with no line items.
  function completionConfirmLines():
    | { lineItemId: string; quantity: number }[]
    | null {
    if (!completionHandoverLoaded || !completionMethod) return null;
    if (completionHandover!.items.length === 0) return null;
    return completionDialogLines
      .map((li) => ({
        lineItemId: li.id,
        quantity: completionChosen[li.id] ?? 0,
      }))
      .filter((l) => l.quantity > 0);
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

      {boardError && (
        <p key="board-error" role="alert" className="mb-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
          {boardError}
        </p>
      )}

      {contactNotice && (
        <p className="mb-3 flex items-center justify-between gap-3 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-800">
          <span>
            Order saved, but the contact person could not be added:{" "}
            {contactNotice}
          </span>
          <button
            type="button"
            onClick={() => setContactNotice(null)}
            className="shrink-0 text-amber-700 hover:text-amber-900"
          >
            Dismiss
          </button>
        </p>
      )}

      <div className="mb-4 flex flex-wrap items-center gap-3">
        <div className="relative">
          <Search className="absolute left-2.5 top-2.5 h-4 w-4 text-slate-400" />
          <input
            type="text"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Customer, phone or SJ number"
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
          {selectableStores(stores, currentEmployee).map((s) => (
            <option key={s.id} value={s.id}>
              {s.name}
            </option>
          ))}
        </select>

        {view === "table" && (
          <label className="flex items-center gap-2 text-sm text-slate-600">
            <input
              type="checkbox"
              checked={tableActionsOnly}
              onChange={(e) => setTableActionsOnly(e.target.checked)}
              className="h-4 w-4 rounded border-slate-300 text-brand-600 focus:ring-brand-500"
            />
            Exchanges and returns
          </label>
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
                unresolvedJourneyIds={unresolvedJourneyIds}
                trialEvals={trialEvals}
                fulfillmentCounts={fulfillmentCounts}
                journeyUnitTotals={journeyUnitTotals}
                returnedTrialCounts={returnedTrialCounts}
                returnChips={returnChipByJourney}
                onSelect={selectJourney}
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
                .filter((j) =>
                  // The filter intentionally ignores the hide rule:
                  // exchange-parked originals must be findable here too.
                  tableActionsOnly
                    ? openActionJourneyIds.has(j.id)
                    : !hiddenJourneyIds.has(j.id) ||
                      j.id === selectedJourney?.id
                )
                .map((j) => (
                <tr
                  key={j.id}
                  className="border-b border-slate-100 hover:bg-slate-50"
                  onClick={() => selectJourney(j)}
                >
                  <td className="px-4 py-2">
                    {j.customer
                      ? `${j.customer.first_name} ${j.customer.last_name}`
                      : "Unknown"}
                  </td>
                  <td className="px-4 py-2">{j.customer?.phone ? formatPhone(j.customer.phone) : "-"}</td>
                  <td className="px-4 py-2">{j.product_summary ?? "-"}</td>
                  <td className="px-4 py-2">
                    {j.cancelled_at ? "Cancelled" : j.current_state}
                    {j.sale_kind === "EXCHANGE" && (
                      <span className="ml-1 rounded-full bg-indigo-100 px-1.5 py-px text-[10px] font-medium text-indigo-700">
                        Exchange
                      </span>
                    )}
                  </td>
                  <td className="px-4 py-2">{j.store?.name ?? "-"}</td>
                  <td className="px-4 py-2">{j.employee?.name ?? "-"}</td>
                  <td className="px-4 py-2">{j.cancelled_at ? "Yes" : "No"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {selectedJourney && (
        <JourneyWorkspace
          key={selectedJourney.id}
          journey={selectedJourney}
          // events/followUps/reassignments are written by several call
          // sites whose fetches can resolve AFTER the selection changes —
          // a late .then(setEvents) from the previous journey otherwise
          // overwrites this journey's feed and never corrects. Filtering
          // by journey_id at render makes a stale write a no-op.
          events={events.filter((e) => e.journey_id === selectedJourney.id)}
          followUps={followUps.filter((f) => f.journey_id === selectedJourney.id)}
          employees={employees}
          stores={stores}
          reassignments={reassignments.filter(
            (r) => r.journey_id === selectedJourney.id
          )}
          canReassign={canReassignJourneys(currentEmployee?.role)}
          canReconcile={
            currentEmployee?.role === "owner" ||
            currentEmployee?.role === "admin" ||
            currentEmployee?.role === "manager"
          }
          canRecordRefund={canRecordRefund}
          canAdjustRefund={canAdjustRefund}
          currentEmployee={currentEmployee}
          trialEvals={trialEvals.get(selectedJourney.id) ?? []}
          onReassigned={handleReassigned}
          onClose={() => {
            refreshTrialBadgeData(selectedJourney.id);
            setCompletionDoneFor(null);
            setPanelCompletionInfo(null);
            setSelectedJourney(null);
          }}
          onCompletionInfo={setPanelCompletionInfo}
          completionDone={
            completionDoneFor !== null &&
            completionDoneFor === selectedJourney.id
              ? COMPLETION_COMPLETED_MESSAGE
              : null
          }
          onAction={executeAction}
          onCancel={setCancelJourneyState}
          refreshPending={journeyRefreshPending}
          onRefresh={async () => {
            await handleReassigned(selectedJourney.id);
          }}
          openBookingSignal={searchParams.get("book") === "1"}
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
              {pendingTransition.transition.event === "delivery_completed"
                ? completionMethod === "pickup"
                  ? "Mark picked up"
                  : "Mark delivered"
                : pendingTransition.transition.label}
            </h2>
            {pendingTransition.transition.event === "delivery_completed" &&
              completionMethod === "pickup" && (
                <p className="-mt-1 mb-2 text-sm text-slate-500">
                  {(() => {
                    const locIds =
                      completionHandover?.journeyId ===
                        pendingTransition.journey.id &&
                      completionHandover.status === "loaded"
                      ? pickupLocationIds(
                          completionDialogLines,
                          pendingTransition.journey
                        )
                      : [pendingTransition.journey.store_id];
                    const names = locIds
                      .map(
                        (id) =>
                          stores.find((s) => s.id === id)?.name ??
                          (id === pendingTransition.journey.store_id
                            ? pendingTransition.journey.store?.name
                            : null)
                      )
                      .filter((n): n is string => !!n);
                    return `from ${joinLocationNames(names)}`;
                  })()}
                </p>
              )}
            {(() => {
              const isCompletion =
                pendingTransition.transition.event === "delivery_completed";
              const info =
                panelCompletionInfo?.journeyId === pendingTransition.journey.id
                  ? panelCompletionInfo
                  : null;
              // Destination comes from the dialog's own fresh read of
              // trial items, never the panel's earlier value. While that
              // read is in flight (statuses null) it stays unknown.
              const dialogRead =
                dialogTrialStatuses?.journeyId === pendingTransition.journey.id
                  ? dialogTrialStatuses.statuses
                  : undefined;
              const goesTo = isCompletion
                ? completionDestinationFor({
                    saleKind: pendingTransition.journey.sale_kind,
                    liveTrialStatuses: dialogRead,
                  })
                : pendingTransition.transition.to;
              const trialReadKnown = dialogRead != null;
              // Non-closing handovers leave units behind, so the order
              // keeps its current state; the destination labels only
              // apply when every remaining unit leaves now.
              const handoverLoaded =
                completionHandover?.journeyId ===
                  pendingTransition.journey.id &&
                completionHandover.status === "loaded";
              const closes =
                isCompletion && handoverLoaded
                  ? completionClosesNow ?? true
                  : completionMethod ===
                      pendingTransition.journey.fulfillment_type
                    ? info?.closing ?? true
                    : false;
              return (
                <>
                  <p className="mb-4 text-sm text-slate-600">
                    {pendingTransition.journey.customer
                      ? `${pendingTransition.journey.customer.first_name} ${pendingTransition.journey.customer.last_name}`
                      : "Journey"}{" "}
                    → {closes ? goesTo : "stays open"}
                  </p>
                  {isCompletion && closes && goesTo === "Completed" && trialReadKnown && (
                    <p className="-mt-2 mb-4 text-sm text-slate-600">
                      {COMPLETION_NO_TRIAL_LINE}
                    </p>
                  )}
                  {isCompletion &&
                    info?.decision?.kind === "note" &&
                    completionMethod === "delivery" && (
                      <p className="-mt-2 mb-4 text-sm text-slate-600">
                        {info.decision.text}
                      </p>
                    )}
                </>
              );
            })()}
            {pendingTransition.journey.price !== null && pendingTransition.journey.price !== undefined && (
              pendingTransition.transition.event === "delivery_completed" ? (
                completionPaid?.journeyId === pendingTransition.journey.id &&
                completionPaid.status === "loaded" ? (
                  <div className="mb-4 rounded-md bg-slate-50 p-3 text-sm">
                    <p className="font-medium text-slate-700">
                      Current balance due: $
                      {(
                        (completionReturns?.journeyId ===
                        pendingTransition.journey.id
                          ? effectivePrice(
                              pendingTransition.journey.price,
                              completionReturns.actions
                            )
                          : pendingTransition.journey.price) -
                        completionPaid.paid
                      ).toFixed(2)}
                    </p>
                  </div>
                ) : completionPaid?.journeyId === pendingTransition.journey.id &&
                  completionPaid.status === "failed" ? (
                  <p className="mb-4 text-sm text-slate-600">
                    Could not load the balance for this order. Close this
                    window and open it again.
                  </p>
                ) : null
              ) : (
                <div className="mb-4 rounded-md bg-slate-50 p-3 text-sm">
                  {(() => {
                    const paid = computeNetPaid(events);
                    const price =
                      completionReturns?.journeyId ===
                      pendingTransition.journey.id
                        ? effectivePrice(
                            pendingTransition.journey.price,
                            completionReturns.actions
                          )
                        : pendingTransition.journey.price;
                    const balance = price - paid;
                    return (
                      <p className="font-medium text-slate-700">
                        Current balance due: ${balance.toFixed(2)}
                      </p>
                    );
                  })()}
                </div>
              )
            )}
            {(() => {
              if (pendingTransition.transition.event !== "delivery_completed") {
                return null;
              }
              const handover =
                completionHandover?.journeyId === pendingTransition.journey.id
                  ? completionHandover
                  : null;
              if (!handover || handover.status === "loading") {
                return (
                  <p className="mb-4 text-sm text-slate-600">
                    Loading the items on this order...
                  </p>
                );
              }
              if (handover.status === "failed") {
                return (
                  <p className="mb-4 text-sm text-slate-600">
                    Could not load the items for this order. Close this
                    window and open it again.
                  </p>
                );
              }
              const journey = pendingTransition.journey;
              const shipTo = effectiveShipTo(journey, journey.customer);
              const shipToLine = formatShipToLine(shipTo);
              const stockByVariant = handover.reqStatus;
              const lineStock = completionDialogLines.map((item) =>
                item.product_id
                  ? completionStockTag(stockByVariant[item.product_id])
                  : null
              );
              const anyNotInStock =
                completionMethod === "delivery" &&
                anyRequirementPending(
                  completionDialogLines.map((item) =>
                    item.product_id ? stockByVariant[item.product_id] : null
                  )
                );
              const storeName = (id: string | null) =>
                (id &&
                  (stores.find((s) => s.id === id)?.name ??
                    (id === journey.store_id
                      ? journey.store?.name ?? null
                      : null))) ??
                "the order store";
              return (
                <div className="mb-4 rounded-md border border-slate-200 bg-slate-50 p-3 text-sm">
                  <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-500">
                    {completionMethod === "pickup"
                      ? "Items being picked up"
                      : "Items being delivered"}
                  </p>
                  {completionMethod === "delivery" && (
                    <p className="mb-2 text-xs text-slate-500">
                      Delivery items all go out together.
                    </p>
                  )}
                  <ul className="space-y-2">
                    {completionDialogLines.map((item, idx) => {
                      const tag = lineStock[idx];
                      if (completionMethod === "pickup") {
                        const info = completionPickupInfo.get(item.id);
                        const qty = completionChosen[item.id] ?? 0;
                        const locName = storeName(info?.locId ?? null);
                        const handedCount = handover.byLine[item.id] ?? 0;
                        return (
                          <li
                            key={item.id}
                            className="rounded-md border border-slate-200 bg-white px-3 py-2 text-slate-700"
                          >
                            <div className="flex items-center justify-between gap-3">
                              <div className="min-w-0">
                                <div className="truncate text-sm font-medium text-slate-900">
                                  {item.item_name}
                                </div>
                                <div className="text-xs text-slate-500">
                                  At {locName}
                                  {handedCount > 0 &&
                                    ` · ${handedCount} of ${item.quantity} picked up`}
                                </div>
                              </div>
                              <div className="flex items-center gap-2">
                                <button
                                  type="button"
                                  disabled={!info?.editable || qty <= 0}
                                  onClick={() =>
                                    setCompletionQty((q) => ({
                                      ...q,
                                      [item.id]: Math.max(
                                        0,
                                        (completionChosen[item.id] ?? 0) - 1
                                      ),
                                    }))
                                  }
                                  className="h-7 w-7 rounded-md border border-slate-300 text-sm text-slate-700 disabled:opacity-40"
                                >
                                  -
                                </button>
                                <span className="w-8 text-center text-sm font-medium text-slate-900">
                                  {qty}
                                </span>
                                <button
                                  type="button"
                                  disabled={
                                    !info?.editable ||
                                    qty >= (info?.remaining ?? 0)
                                  }
                                  onClick={() =>
                                    setCompletionQty((q) => ({
                                      ...q,
                                      [item.id]: Math.min(
                                        info?.remaining ?? 0,
                                        (completionChosen[item.id] ?? 0) + 1
                                      ),
                                    }))
                                  }
                                  className="h-7 w-7 rounded-md border border-slate-300 text-sm text-slate-700 disabled:opacity-40"
                                >
                                  +
                                </button>
                                <span className="text-xs text-slate-500">
                                  of {info?.remaining ?? 0}
                                </span>
                              </div>
                            </div>
                            {info?.locationLocked && (
                              <p className="mt-1 text-xs text-slate-500">
                                {pickupLocationNote([locName])}
                              </p>
                            )}
                            {info?.outOfStock && (
                              <p className="mt-1 text-xs text-amber-700">
                                {STOCK_TAG_LABEL.not_in_stock} at {locName}
                              </p>
                            )}
                          </li>
                        );
                      }
                      return (
                        <li key={item.id} className="text-slate-700">
                          <div className="flex items-start justify-between gap-2">
                            <span>
                              {item.item_name}{" "}
                              <span className="text-slate-500">
                                · Qty {remainingUnits(item, handover.byLine)}
                              </span>
                            </span>
                            {tag && (
                              <span
                                className={`shrink-0 rounded-full px-1.5 py-px text-[10px] font-medium ${
                                  tag === "in_stock"
                                    ? "bg-emerald-100 text-emerald-700"
                                    : "bg-amber-100 text-amber-700"
                                }`}
                              >
                                {STOCK_TAG_LABEL[tag]}
                              </span>
                            )}
                          </div>
                          <p className="text-xs text-slate-500">
                            {[
                              shipToLine || "No delivery address on file",
                              handover.bookedDate
                                ? `Booked ${new Date(
                                    `${handover.bookedDate}T00:00:00`
                                  ).toLocaleDateString(undefined, {
                                    month: "short",
                                    day: "numeric",
                                  })}`
                                : null,
                            ]
                              .filter(Boolean)
                              .join(" · ")}
                          </p>
                        </li>
                      );
                    })}
                  </ul>
                  {completionOthersStayOpen && (
                    <p className="mt-2 text-sm text-slate-600">
                      {OTHER_ITEMS_STAY_OPEN_NOTE}
                    </p>
                  )}
                  {anyNotInStock && (
                    <p className="mt-2 text-sm font-medium text-red-700">
                      {COMPLETION_NOT_IN_STOCK_LINE}
                    </p>
                  )}
                </div>
              );
            })()}
            {completionExchangeAction &&
              pendingTransition.transition.event === "delivery_completed" && (
              <div className="mb-4 rounded-md border border-amber-200 bg-amber-50 p-3 text-sm">
                <p className="mb-1 text-xs font-semibold uppercase tracking-wide text-amber-700">
                  Old mattress
                </p>
                <p className="mb-2 text-xs text-slate-600">
                  {completionMethod === "delivery"
                    ? `Pick up ${
                        completionExchangeAction.product_name ??
                        "the old mattress"
                      } for the exchange?`
                    : `Did the customer hand over ${
                        completionExchangeAction.product_name ??
                        "the old mattress"
                      }?`}
                </p>
                <div className="flex flex-wrap gap-2">
                  <button
                    type="button"
                    onClick={() => setOldMattressAnswer("brought")}
                    className={`rounded-md border px-3 py-1.5 text-xs font-medium ${
                      oldMattressAnswer === "brought"
                        ? "border-amber-500 bg-amber-100 text-amber-900"
                        : "border-slate-300 bg-white text-slate-700"
                    }`}
                  >
                    {completionMethod === "delivery"
                      ? "Picked up"
                      : "Handed over"}
                  </button>
                  <button
                    type="button"
                    onClick={() => setOldMattressAnswer("kept")}
                    className={`rounded-md border px-3 py-1.5 text-xs font-medium ${
                      oldMattressAnswer === "kept"
                        ? "border-amber-500 bg-amber-100 text-amber-900"
                        : "border-slate-300 bg-white text-slate-700"
                    }`}
                  >
                    {completionMethod === "delivery"
                      ? "Not picked up"
                      : "Not handed over"}
                  </button>
                </div>
                {oldMattressAnswer === "brought" &&
                  completionMethod === "pickup" && (
                  <select
                    value={
                      oldMattressLocationId ||
                      (originalHandoverLocationDefault({
                        pickupLocationIds: completionDialogLines.map(
                          (li) =>
                            (li as { pickup_location_id?: string | null })
                              .pickup_location_id ?? null
                        ),
                        assignedWarehouseId: stores.find(
                          (st) =>
                            st.id === pendingTransition.journey.store_id
                        )?.assigned_warehouse_id,
                        warehouses: stores.filter(
                          (st) => st.location_type === "WAREHOUSE"
                        ),
                        orderStoreId: pendingTransition.journey.store_id,
                      }) ?? "")
                    }
                    onChange={(e) =>
                      setOldMattressLocationId(e.target.value)
                    }
                    className="mt-2 w-full rounded-md border border-slate-300 bg-white px-2 py-1.5 text-xs text-slate-700"
                  >
                    {stores
                      .filter((st) => st.is_active)
                      .map((st) => (
                        <option key={st.id} value={st.id}>
                          {st.name}
                        </option>
                      ))}
                  </select>
                )}
                {oldMattressAnswer === "kept" && (
                  <input
                    type="text"
                    value={oldMattressReason}
                    onChange={(e) => setOldMattressReason(e.target.value)}
                    placeholder={
                      completionMethod === "delivery"
                        ? "Why was it not picked up?"
                        : "Why was it not handed over?"
                    }
                    className="mt-2 w-full rounded-md border border-slate-300 bg-white px-2 py-1.5 text-xs text-slate-700"
                  />
                )}
                {oldMattressAnswer === "" && (
                  <p className="mt-2 text-xs text-slate-500">
                    The old mattress is still outstanding.
                  </p>
                )}
              </div>
            )}
            {modalError && (
              <p key="modal-error" role="alert" className="mb-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
                {modalError}
              </p>
            )}
            <div className="space-y-3">
              {pendingTransition.transition.event === "delivery_completed" ? (
                <>
                  {completionShowsDateField(canBackdateFulfillment) && (
                    <div>
                      <label className="block text-sm font-medium text-slate-700">
                        Completed on
                      </label>
                      <input
                        type="date"
                        max={localTodayISO()}
                        value={
                          pendingFieldValues.completed_on ?? localTodayISO()
                        }
                        onChange={(e) =>
                          setPendingFieldValues({
                            ...pendingFieldValues,
                            completed_on: e.target.value,
                          })
                        }
                        className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                      />
                      <p className="mt-1 text-xs text-slate-500">
                        Leave as today unless this was completed earlier.
                      </p>
                    </div>
                  )}
                  {completionNeedsReason(
                    pendingFieldValues.completed_on ?? "",
                    localTodayISO()
                  ) && (
                    <div>
                      <label className="block text-sm font-medium text-slate-700">
                        Reason for the earlier date
                      </label>
                      <input
                        type="text"
                        value={pendingFieldValues.backdate_reason ?? ""}
                        onChange={(e) =>
                          setPendingFieldValues({
                            ...pendingFieldValues,
                            backdate_reason: e.target.value,
                          })
                        }
                        className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                      />
                    </div>
                  )}
                </>
              ) : (
                pendingTransition.transition.requiredFields?.map((field) => (
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
              ))
              )}
            </div>
            <div className="mt-4 flex gap-2">
              <button
                onClick={() =>
                  executeTransition(
                    pendingTransition.journey,
                    pendingTransition.transition,
                    pendingFieldValues,
                    completionIsOpen ? completionConfirmLines() : undefined
                  )
                }
                disabled={
                  boardBusy ||
                  completionBlocksConfirm ||
                  (completionIsOpen && !completionReadsReady) ||
                  // An order with line items must send at least one unit;
                  // zero-line orders keep the legacy whole-order path.
                  (completionIsOpen &&
                    completionHandoverLoaded &&
                    completionHandover!.items.length > 0 &&
                    completionTotalChosen === 0) ||
                  (pendingTransition.transition.event ===
                    "delivery_completed" &&
                    completionNeedsReason(
                      pendingFieldValues.completed_on ?? "",
                      localTodayISO()
                    ) &&
                    !completionReasonMet(pendingFieldValues.backdate_reason))
                }
                className="flex-1 rounded-md bg-brand-600 px-3 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
              >
                {boardBusy ? "Working…" : "Confirm"}
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
                ? "Confirming payment - please wait. This payment is unresolved and no new payment can be submitted for this order until it is reconciled."
                : "The payment was recorded as failed. No money was collected."}
            </p>
            {modalError && (
              <p key="reconcile-error" role="alert" className="mb-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
                {modalError}
              </p>
            )}
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
            {modalError && (
              <p key="overpay-error" role="alert" className="mb-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
                {modalError}
              </p>
            )}
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
              onChange={(e) => {
                setCancelReason(e.target.value);
                setCancelError(null);
              }}
              placeholder="Reason for cancellation"
              className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              rows={3}
            />
            {cancelNetPaid !== null && cancelNetPaid > 0 && (
              <p className="mt-3 text-xs font-medium text-amber-700">
                The customer has paid ${cancelNetPaid.toFixed(2)}.
                Cancelling does not refund them: record the refund in
                Journey Activity after you cancel.
              </p>
            )}
            {cancelError && (
              <p className="mt-3 text-sm text-red-600">{cancelError}</p>
            )}
            <div className="mt-4 flex gap-2">
              <button
                onClick={submitCancel}
                disabled={boardBusy}
                className="flex-1 rounded-md bg-red-600 px-3 py-2 text-sm font-medium text-white hover:bg-red-700 disabled:opacity-50"
              >
                {boardBusy ? "Cancelling…" : "Cancel Journey"}
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

export default function BoardPage() {
  return (
    <Suspense
      fallback={
        <main className="flex min-h-screen items-center justify-center p-8">
          <p className="text-sm text-slate-500">Loading…</p>
        </main>
      }
    >
      <BoardContent />
    </Suspense>
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
  fulfillmentCounts,
  journeyUnitTotals,
  returnedTrialCounts,
  returnChips,
  onSelect,
}: {
  state: SleepJourneyState;
  journeys: JourneyWithDetails[];
  unresolvedJourneyIds: Set<string>;
  trialEvals: Map<string, SleepTrialEvaluation[]>;
  fulfillmentCounts: Record<string, number>;
  journeyUnitTotals: Record<
    string,
    { units: number; hasPickupLine: boolean; hasDeliveryLine: boolean }
  >;
  returnedTrialCounts: Record<string, { returned: number; total: number }>;
  returnChips: Map<string, { step: string | null }>;
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
            unitsOut={fulfillmentCounts[j.id] ?? 0}
            unitMeta={journeyUnitTotals[j.id]}
            returnedCounts={returnedTrialCounts[j.id]}
            returnChip={returnChips.get(j.id)}
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
  unitsOut,
  unitMeta,
  returnedCounts,
  returnChip,
  onSelect,
}: {
  journey: JourneyWithDetails;
  hasUnresolvedPayment: boolean;
  trialEvals: SleepTrialEvaluation[];
  unitsOut: number;
  unitMeta?: { units: number; hasPickupLine: boolean; hasDeliveryLine: boolean };
  returnedCounts?: { returned: number; total: number };
  returnChip?: { step: string | null };
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
      {journey.journey_number && (
        <p className="truncate font-mono text-[10px] leading-tight text-slate-400">
          {journey.journey_number}
        </p>
      )}
      <p className="truncate text-[10px] leading-tight text-slate-500">
        {journey.customer?.phone ? formatPhone(journey.customer.phone) : "-"}
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
      {returnChip && (
        <p className="flex items-center gap-1">
          <span className="inline-block rounded-full bg-violet-100 px-1.5 py-px text-[10px] font-medium text-violet-700">
            Return in progress
          </span>
          {returnChip.step && (
            <span className="truncate text-[10px] text-slate-500">
              {returnChip.step}
            </span>
          )}
        </p>
      )}
      <p>
        {(() => {
          const hasPickup = unitMeta?.hasPickupLine ?? false;
          const hasDelivery = unitMeta?.hasDeliveryLine ?? false;
          if (hasPickup && hasDelivery) {
            // Two-tone chip for mixed orders: blue half, orange half.
            return (
              <span className="inline-flex overflow-hidden rounded-full text-[10px] font-medium">
                <span className="bg-sky-100 px-1.5 py-px text-sky-700">
                  Pickup
                </span>
                <span className="bg-orange-100 px-1.5 py-px text-orange-600">
                  + Delivery
                </span>
              </span>
            );
          }
          const label = fulfillmentMethodChip({
            fulfillment: journey.fulfillment_type,
            hasPickupLine: hasPickup,
            hasDeliveryLine: hasDelivery,
          });
          return (
            <span
              className={`inline-block rounded-full px-1.5 py-px text-[10px] font-medium ${
                label === "Pickup"
                  ? "bg-sky-100 text-sky-700"
                  : "bg-orange-100 text-orange-600"
              }`}
            >
              {label}
            </span>
          );
        })()}
      </p>
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
      {unitsOut > 0 && (unitMeta?.units ?? 0) > 0 && unitsOut < (unitMeta?.units ?? 0) && (
        <p>
          <span className="inline-block rounded-full bg-sky-100 px-1.5 py-px text-[10px] font-medium text-sky-700">
            {fulfillmentCountLabel({
              out: unitsOut,
              total: unitMeta?.units ?? 0,
              method: journey.fulfillment_type,
              hasPickupLine: unitMeta?.hasPickupLine ?? false,
              hasDeliveryLine: unitMeta?.hasDeliveryLine ?? false,
            })}
          </span>
        </p>
      )}
      {(returnedCounts?.returned ?? 0) > 0 &&
        returnedPillText(returnedCounts?.returned ?? 0, unitsOut) && (
        <p>
          <span className="inline-block rounded-full bg-violet-100 px-1.5 py-px text-[10px] font-medium text-violet-700">
            {returnedPillText(
              returnedCounts?.returned ?? 0,
              unitsOut
            )}
          </span>
        </p>
      )}
    </div>
  );
}

