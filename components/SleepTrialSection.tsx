"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import {
  evaluateSleepTrialItems,
  fetchTrialStartCorrections,
  correctTrialStart,
  sortEvaluationsByUrgency,
  headlineAction,
  trialStatusLabel,
  trialStatusTone,
  TRIAL_STATUS_DOT,
  formatTrialDate,
  formatMoney,
  trialDate,
  overrideSleepTrialProtector,
  fetchTrialItemExceptions,
  fetchExceptionApprovers,
  fetchExceptionReasons,
  fetchMySleepTrialPermissions,
  requestTrialItemException,
  decideTrialItemException,
  exceptionTypeLabel,
  EXCEPTION_EDITABLE_TERMS,
  type SleepTrialEvaluation,
  type TrialStartCorrection,
  type TrialItemException,
  type ExceptionApprover,
  type ExceptionReason,
} from "@/lib/journeys/sleepTrial";
import {
  explainSleepTrialReason,
  sleepTrialReasonLabel,
} from "@/lib/sleepTrial/reasons";
import {
  fetchSleepConcernConfig,
  fetchSleepConcerns,
  fetchSleepConcernIssues,
  fetchSleepConcernEntries,
  fetchSleepConcernDiagnostics,
  fetchSleepTrialExceptions,
  openSleepConcern,
  addSleepConcernEntry,
  requestConcernExchange,
  decideSleepTrialException,
  CONCERN_STATUS_LABELS,
  OPEN_CONCERN_STATUSES,
  type SleepConcern,
  type SleepConcernIssue,
  type SleepConcernEntry,
  type SleepConcernDiagnostic,
  type SleepConcernType,
  type SleepConcernQuestion,
  type SleepTrialExceptionRequest,
  type IssueInput,
  type DiagnosticInput,
} from "@/lib/journeys/concerns";
import {
  fetchCustomerContacts,
  recordJourneyInteraction,
  type CustomerContact,
} from "@/lib/journeys/interactions";
import type { Employee, JourneyWithDetails } from "@/lib/journeys/queries";
import Modal from "@/components/Modal";

// ============================================================
// Next Action bar (spec 19.3 / 20). The evaluator returns
// allowed_ui_actions already filtered by policy AND the caller's
// permissions; this list only decides display order — the first
// present entry is the primary button.
// ============================================================

const ACTION_LABELS: Record<string, string> = {
  START_EXCHANGE: "Start Exchange",
  START_RETURN: "Start Return",
  OVERRIDE_PROTECTOR_REQUIREMENT: "Override Protector",
  VIEW_EXCHANGE: "View Exchange",
  VIEW_RETURN: "View Return",
  VIEW_EXCEPTION_REQUEST: "View Pending Request",
  REQUEST_EXPIRED_TRIAL_EXCEPTION: "Request Expired Exception",
  REQUEST_EXPIRED_RETURN_EXCEPTION: "Request Expired Return",
  ADD_SLEEP_CONCERN: "Add Sleep Concern",
  REQUEST_EARLY_EXCHANGE_EXCEPTION: "Request Early Exchange",
  REQUEST_EXTRA_EXCHANGE_EXCEPTION: "Request Extra Exchange",
  REQUEST_RETURN_EXCEPTION: "Request Return Exception",
  REQUEST_RETURN_APPROVAL: "Request Return Approval",
  REQUEST_PROTECTOR_EXCEPTION: "Request Protector Approval",
  REQUEST_FEE_WAIVER: "Request Fee Waiver",
  EXTEND_TRIAL_REQUEST: "Request Extension",
  SCHEDULE_FOLLOW_UP: "Schedule Follow-Up",
  ADD_NOTE: "Add Note",
  VIEW_HISTORY: "View History",
};

const ACTION_PRIORITY = [
  "START_EXCHANGE",
  "START_RETURN",
  "OVERRIDE_PROTECTOR_REQUIREMENT",
  "VIEW_EXCHANGE",
  "VIEW_RETURN",
  "VIEW_EXCEPTION_REQUEST",
  "REQUEST_EXPIRED_TRIAL_EXCEPTION",
  "REQUEST_EXPIRED_RETURN_EXCEPTION",
  "ADD_SLEEP_CONCERN",
  "REQUEST_EARLY_EXCHANGE_EXCEPTION",
  "REQUEST_EXTRA_EXCHANGE_EXCEPTION",
  "REQUEST_RETURN_EXCEPTION",
  "REQUEST_RETURN_APPROVAL",
  "REQUEST_PROTECTOR_EXCEPTION",
  "REQUEST_FEE_WAIVER",
  "EXTEND_TRIAL_REQUEST",
  "SCHEDULE_FOLLOW_UP",
  "ADD_NOTE",
  "VIEW_HISTORY",
];

// Actions with no backing RPC yet (ST-6/7/9). They render visibly
// disabled with a "Coming soon" tooltip so the bar is honest about
// what exists today.
const COMING_SOON_ACTIONS = new Set([
  "START_EXCHANGE",
  "START_RETURN",
  // REQUEST_PROTECTOR_EXCEPTION stays unbacked: PROTECTOR_OVERRIDE is
  // deliberately rejected by request_trial_item_exception (074) — the
  // override is a direct action — and an APPROVAL_REQUIRED protector
  // request has no path yet.
  "REQUEST_PROTECTOR_EXCEPTION",
  "SCHEDULE_FOLLOW_UP",
  "VIEW_EXCHANGE",
  "VIEW_RETURN",
  "VIEW_HISTORY",
]);

// Actions that create an approval request (spec 15.5). When nobody can
// approve — empty approver set and the caller can't self-authorize —
// these render disabled with the misconfiguration message instead of
// queueing a request no one could ever decide.
const REQUEST_ACTIONS = new Set([
  "REQUEST_EARLY_EXCHANGE_EXCEPTION",
  "REQUEST_EXTRA_EXCHANGE_EXCEPTION",
  "REQUEST_EXPIRED_TRIAL_EXCEPTION",
  "REQUEST_EXPIRED_RETURN_EXCEPTION",
  "REQUEST_RETURN_EXCEPTION",
  "REQUEST_RETURN_APPROVAL",
  "REQUEST_PROTECTOR_EXCEPTION",
  "REQUEST_FEE_WAIVER",
  "EXTEND_TRIAL_REQUEST",
]);

const NO_APPROVER_MESSAGE =
  "No one in your company can approve this. Ask an admin to update Sleep Trial approvals.";

// Which action result a REQUEST_* action reads its offered exception_type
// from (spec 15.1: the evaluator names the type, the UI never picks one).
// FEE reads whichever action carries a fee; TRIAL is the fixed EXTEND_TRIAL.
const REQUEST_ACTION_SOURCE: Record<
  string,
  "EXCHANGE" | "RETURN" | "FEE" | "TRIAL"
> = {
  REQUEST_EARLY_EXCHANGE_EXCEPTION: "EXCHANGE",
  REQUEST_EXTRA_EXCHANGE_EXCEPTION: "EXCHANGE",
  REQUEST_EXPIRED_TRIAL_EXCEPTION: "EXCHANGE",
  REQUEST_EXPIRED_RETURN_EXCEPTION: "RETURN",
  REQUEST_RETURN_EXCEPTION: "RETURN",
  REQUEST_RETURN_APPROVAL: "RETURN",
  REQUEST_FEE_WAIVER: "FEE",
  EXTEND_TRIAL_REQUEST: "TRIAL",
};

export default function SleepTrialSection({
  journey,
  currentEmployee,
  canModerate,
  onChanged,
}: {
  journey: JourneyWithDetails;
  currentEmployee: Employee | null;
  canModerate: boolean;
  onChanged: () => void;
}) {
  const [concerns, setConcerns] = useState<SleepConcern[]>([]);
  const [issues, setIssues] = useState<SleepConcernIssue[]>([]);
  const [exceptions, setExceptions] = useState<SleepTrialExceptionRequest[]>([]);
  const [corrections, setCorrections] = useState<TrialStartCorrection[]>([]);
  const [contacts, setContacts] = useState<CustomerContact[]>([]);
  const [evals, setEvals] = useState<SleepTrialEvaluation[]>([]);
  const [expandedConcern, setExpandedConcern] = useState<string | null>(null);
  const [showConcernForm, setShowConcernForm] = useState(false);
  const [showEntryForm, setShowEntryForm] = useState<string | null>(null);
  const [showCorrection, setShowCorrection] = useState(false);
  const [requestDraft, setRequestDraft] = useState<{
    evaluation: SleepTrialEvaluation;
    exceptionType: string;
    action: "EXCHANGE" | "RETURN" | null;
  } | null>(null);
  const [overrideEval, setOverrideEval] =
    useState<SleepTrialEvaluation | null>(null);
  const [itemExceptions, setItemExceptions] = useState<TrialItemException[]>([]);
  const [approvers, setApprovers] = useState<ExceptionApprover[]>([]);
  const [permKeys, setPermKeys] = useState<Set<string>>(new Set());
  const [decideException, setDecideException] =
    useState<TrialItemException | null>(null);
  const [showNote, setShowNote] = useState(false);
  const [showCorrectionsLog, setShowCorrectionsLog] = useState(false);
  const [showAllTrials, setShowAllTrials] = useState(false);
  const exceptionRef = useRef<HTMLDivElement>(null);

  // The evaluator is the single source of trial truth (ST-4). Heroes render
  // most-urgent-first (spec 19.1); "+N more" expands the rest.
  const orderedEvals = useMemo(() => sortEvaluationsByUrgency(evals), [evals]);

  const hasTrial = journey.delivered_at != null || evals.length > 0;

  const load = async () => {
    const evalMap = await evaluateSleepTrialItems([journey.id]);
    setEvals(evalMap.get(journey.id) ?? []);
    const [c, ex, corr, ct, iex, appr, pk] = await Promise.all([
      fetchSleepConcerns(journey.id),
      fetchSleepTrialExceptions(journey.id),
      fetchTrialStartCorrections(journey.id),
      journey.customer ? fetchCustomerContacts(journey.customer.id) : Promise.resolve([]),
      fetchTrialItemExceptions(journey.id),
      fetchExceptionApprovers(journey.id),
      fetchMySleepTrialPermissions(currentEmployee?.role),
    ]);
    setConcerns(c);
    setExceptions(ex);
    setCorrections(corr);
    setContacts(ct);
    setItemExceptions(iex);
    setApprovers(appr);
    setPermKeys(pk);
    setIssues(await fetchSleepConcernIssues(c.map((x) => x.id)));
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [journey.id, journey.delivered_at]);

  async function refresh() {
    await load();
    onChanged();
  }

  if (!hasTrial) {
    return (
      <div className="rounded-md border border-slate-300 bg-slate-50 px-3 py-2">
        <p className="text-sm font-medium text-slate-700">
          Eligibility Unknown
        </p>
        <p className="mt-0.5 text-xs text-slate-500">
          No sleep trial items are bound to this journey and no delivery has
          been recorded. Trial items are created automatically when the sale is
          completed.
        </p>
      </div>
    );
  }

  const openConcerns = concerns.filter((c) => OPEN_CONCERN_STATUSES.includes(c.status));
  const closedConcerns = concerns.filter((c) => !OPEN_CONCERN_STATUSES.includes(c.status));
  // Effective expiry on read: a 'pending' request whose window passed
  // is treated as expired even before a write path persists it.
  const isEffectivelyPending = (e: SleepTrialExceptionRequest) =>
    e.status === "pending" &&
    (!e.expires_at || new Date(e.expires_at) > new Date());
  const pendingException = exceptions.find(isEffectivelyPending);
  const approvedException = exceptions.find((e) => e.status === "approved");
  const decidedExceptions = exceptions.filter(
    (e) => !isEffectivelyPending(e) && e.status !== "approved"
  );

  // Exceptions v2 (sleep_trial_exceptions): pending/decided panels below.
  // A legacy request that was migrated (073 set legacy_request_id) is
  // suppressed so it doesn't render twice.
  const migratedIds = new Set(
    itemExceptions.map((e) => e.legacy_request_id).filter(Boolean)
  );
  const pendingItemExceptions = itemExceptions.filter(
    (e) => e.status === "PENDING"
  );
  const decidedItemExceptions = itemExceptions.filter(
    (e) => e.status !== "PENDING"
  );
  const showLegacyPending =
    pendingException && !migratedIds.has(pendingException.id);

  // Spec 15.5: the request button is replaced when nobody can approve —
  // empty approver set AND the caller can't self-authorize (self-auth
  // never touches the queue).
  const canSelfAuthorize =
    permKeys.has("sleep_trial.approve_exceptions") &&
    permKeys.has("sleep_trial.approve_own_exceptions");
  const noApproverForRequest =
    !canSelfAuthorize &&
    !approvers.some((a) => a.employee_id !== currentEmployee?.id);
  // "Customer wants an exchange" is enabled when any live item's exchange
  // action evaluates ELIGIBLE (an approved exception already folds into
  // ELIGIBLE inside the evaluator).
  const canExchange = evals.some(
    (e) => e.actions?.EXCHANGE?.status === "ELIGIBLE"
  );
  const isManager = canModerate;

  function issuesFor(concernId: string) {
    return issues.filter((i) => i.sleep_concern_id === concernId);
  }

  // Single dispatch point for the Next Action bar. Only actions with real
  // backing reach here — unbacked entries render disabled (Coming soon).
  function handleAction(e: SleepTrialEvaluation, action: string) {
    switch (action) {
      case "ADD_SLEEP_CONCERN":
        setShowConcernForm(true);
        break;
      case "OVERRIDE_PROTECTOR_REQUIREMENT":
        setOverrideEval(e);
        break;
      case "VIEW_EXCEPTION_REQUEST":
        exceptionRef.current?.scrollIntoView({
          behavior: "smooth",
          block: "center",
        });
        break;
      case "ADD_NOTE":
        setShowNote(true);
        break;
      default:
        // Request actions: the exception type comes from the action
        // result's offered exception_type, never a UI-side choice.
        if (REQUEST_ACTIONS.has(action)) {
          const src = REQUEST_ACTION_SOURCE[action];
          let type: string | null = null;
          let act: "EXCHANGE" | "RETURN" | null = null;
          if (src === "TRIAL") {
            type = "EXTEND_TRIAL";
          } else if (src === "FEE") {
            type = "FEE_WAIVER";
            act =
              (e.actions?.EXCHANGE?.fee?.amount_cents ?? 0) > 0
                ? "EXCHANGE"
                : "RETURN";
          } else {
            const res = e.actions?.[src];
            if (res?.exception_available && res.exception_type) {
              type = res.exception_type;
              act = src;
            }
          }
          if (type) {
            setRequestDraft({
              evaluation: e,
              exceptionType: type,
              action: act,
            });
          } else {
            // e.g. FEE_WINDOW_NEEDS_APPROVAL offers exception_type null —
            // there is no requestable type for that blocker yet.
            window.alert(
              "This blocker can't be requested as an exception yet."
            );
          }
        }
        break;
    }
  }

  return (
    <div className="rounded-md border border-teal-200 bg-teal-50 px-3 py-2">
      {/* Trial hero — one card per mattress, most urgent first (spec 19.1).
          Every number/word is the evaluator's output, not recomputed here. */}
      {orderedEvals.length > 0 ? (
        <>
          <TrialHeroCard
            key={orderedEvals[0].trial_item_id}
            evaluation={orderedEvals[0]}
            onAction={(a) => handleAction(orderedEvals[0], a)}
            noApproverRequests={noApproverForRequest}
          />
          {orderedEvals.length > 1 &&
            (showAllTrials ? (
              orderedEvals.slice(1).map((e) => (
                <div key={e.trial_item_id} className="mt-2">
                  <TrialHeroCard
                    evaluation={e}
                    onAction={(a) => handleAction(e, a)}
                    noApproverRequests={noApproverForRequest}
                  />
                </div>
              ))
            ) : (
              <button
                onClick={() => setShowAllTrials(true)}
                className="mt-1.5 text-xs font-medium text-teal-700 underline"
              >
                +{orderedEvals.length - 1} more mattress
                {orderedEvals.length - 1 === 1 ? "" : "es"}
              </button>
            ))}
        </>
      ) : (
        <p className="text-sm font-medium text-teal-800">
          Can&apos;t determine eligibility — no trial items on this order
        </p>
      )}

      {/* Trial-start correction */}
      {corrections.length > 0 && (
        <button
          onClick={() => setShowCorrectionsLog((v) => !v)}
          className="mt-1 text-xs text-teal-700 underline"
        >
          Trial start corrected {corrections.length} time
          {corrections.length === 1 ? "" : "s"}
        </button>
      )}
      {showCorrectionsLog &&
        corrections.map((c) => (
          <p key={c.id} className="mt-1 text-xs text-teal-700">
            {c.previous_started_at ?? "unset"} → {c.new_started_at} by{" "}
            {c.corrected_by?.name ?? "Unknown"} on{" "}
            {new Date(c.created_at).toLocaleDateString()} — {c.reason}
          </p>
        ))}
      {isManager && (
        <button
          onClick={() => setShowCorrection(true)}
          className="mt-1 block text-xs text-brand-700 underline"
        >
          Correct trial start date
        </button>
      )}

      {/* Sleep concerns */}
      <div className="mt-3 border-t border-teal-200 pt-2">
        <div className="flex items-center justify-between">
          <h4 className="text-xs font-semibold uppercase text-teal-800">
            Sleep Concerns
          </h4>
          <button
            onClick={() => setShowConcernForm(true)}
            className="rounded-md bg-teal-700 px-2 py-1 text-xs font-medium text-white hover:bg-teal-800"
          >
            + Start Sleep Concern
          </button>
        </div>

        {concerns.length === 0 && (
          <p className="mt-1 text-xs text-teal-700">No sleep concerns reported.</p>
        )}

        {[...openConcerns, ...closedConcerns].map((c) => (
          <ConcernCard
            key={c.id}
            concern={c}
            issues={issuesFor(c.id)}
            expanded={expandedConcern === c.id}
            onToggle={() =>
              setExpandedConcern(expandedConcern === c.id ? null : c.id)
            }
            onAddUpdate={() => setShowEntryForm(c.id)}
            onChanged={refresh}
            canExchange={canExchange && OPEN_CONCERN_STATUSES.includes(c.status)}
          />
        ))}

        {openConcerns.length === 0 && closedConcerns.length > 0 && null}
      </div>

      {/* Exception requests — VIEW_EXCEPTION_REQUEST scrolls here */}
      <div ref={exceptionRef}>
      {pendingItemExceptions.map((ex) => {
        const eligible = approvers.filter(
          (a) => a.employee_id !== ex.requester_employee_id
        );
        const canDecide = eligible.some(
          (a) => a.employee_id === currentEmployee?.id
        );
        return (
          <div
            key={ex.id}
            className="mt-2 rounded-md border border-amber-300 bg-amber-50 p-2 text-xs"
          >
            <p className="font-medium text-amber-800">
              {exceptionTypeLabel(ex.exception_type)} exception — waiting for
              approval
            </p>
            <p className="text-amber-700">
              Requested by {ex.requester?.name ?? "Unknown"} on{" "}
              {new Date(ex.requested_at).toLocaleDateString()}
              {ex.reason?.label ? ` · ${ex.reason.label}` : ""}
            </p>
            {ex.reason_note && (
              <p className="mt-0.5 text-amber-700">{ex.reason_note}</p>
            )}
            <p className="mt-0.5 text-amber-700">
              {eligible.length > 0
                ? `Can be approved by: ${eligible
                    .map((a) => a.employee_name)
                    .join(", ")}`
                : NO_APPROVER_MESSAGE}
            </p>
            {canDecide && (
              <button
                onClick={() => setDecideException(ex)}
                className="mt-1.5 rounded bg-amber-600 px-2 py-1 text-xs font-medium text-white hover:bg-amber-700"
              >
                Decide
              </button>
            )}
          </div>
        );
      })}
      {showLegacyPending && pendingException && (
        <div className="mt-2 rounded-md border border-amber-300 bg-amber-50 p-2 text-xs">
          <p className="font-medium text-amber-800">
            Early exchange exception pending
          </p>
          <p className="text-amber-700">
            Requested by {pendingException.requester?.name ?? "Unknown"} on{" "}
            {new Date(pendingException.requested_at).toLocaleDateString()} · night{" "}
            {pendingException.current_trial_night ?? "?"} · normal eligibility{" "}
            {pendingException.normal_eligibility_date ?? "—"}
          </p>
          <p className="mt-0.5 text-amber-700">{pendingException.reason}</p>
          {isManager &&
            pendingException.requester_employee_id !== currentEmployee?.id && (
              <div className="mt-1.5 flex gap-2">
                <button
                  onClick={async () => {
                    try {
                      const result = await decideSleepTrialException(
                        pendingException.id,
                        "approved"
                      );
                      if (result === "expired") {
                        window.alert(
                          "This request had already expired — the trial reached normal eligibility."
                        );
                      }
                      refresh();
                    } catch (e: any) {
                      window.alert(e.message ?? "Failed to approve");
                    }
                  }}
                  className="rounded bg-green-600 px-2 py-1 text-xs font-medium text-white"
                >
                  Approve
                </button>
                <button
                  onClick={async () => {
                    try {
                      const result = await decideSleepTrialException(
                        pendingException.id,
                        "denied"
                      );
                      if (result === "expired") {
                        window.alert(
                          "This request had already expired — the trial reached normal eligibility."
                        );
                      }
                      refresh();
                    } catch (e: any) {
                      window.alert(e.message ?? "Failed to deny");
                    }
                  }}
                  className="rounded bg-red-600 px-2 py-1 text-xs font-medium text-white"
                >
                  Deny
                </button>
              </div>
            )}
        </div>
      )}
      {approvedException && (
        <p className="mt-2 rounded-md border border-green-300 bg-green-50 p-2 text-xs font-medium text-green-800">
          Early exchange exception approved by{" "}
          {approvedException.approver?.name ?? "a manager"}
          {approvedException.decided_at
            ? ` on ${new Date(approvedException.decided_at).toLocaleDateString()}`
            : ""}
          . Approval grants authority only — it does not start an exchange.
        </p>
      )}
      {decidedExceptions.map((e) => (
        <p key={e.id} className="mt-1 text-xs text-slate-500">
          Early exchange exception{" "}
          {e.status === "pending" ? "expired" : e.status}
          {e.approver ? ` by ${e.approver.name}` : ""}
          {e.decided_at
            ? ` on ${new Date(e.decided_at).toLocaleDateString()}`
            : ""}
          .
        </p>
      ))}
      {decidedItemExceptions.map((ex) => (
        <p key={ex.id} className="mt-1 text-xs text-slate-500">
          {exceptionTypeLabel(ex.exception_type)} exception{" "}
          {ex.status === "APPROVED"
            ? `approved by ${ex.approver?.name ?? "unknown"}${
                ex.self_authorized ? " (self-authorized)" : ""
              }${
                ex.decided_at
                  ? ` on ${new Date(ex.decided_at).toLocaleDateString()}`
                  : ""
              }${
                ex.valid_until
                  ? ` · valid until ${new Date(ex.valid_until).toLocaleDateString()}`
                  : ""
              }`
            : ex.status === "CONSUMED"
            ? `applied${
                ex.consumed_at
                  ? ` on ${new Date(ex.consumed_at).toLocaleDateString()}`
                  : ""
              }`
            : `${ex.status.toLowerCase()}${
                ex.approver ? ` by ${ex.approver.name}` : ""
              }${
                ex.decided_at
                  ? ` on ${new Date(ex.decided_at).toLocaleDateString()}`
                  : ""
              }`}
          .
          {ex.status === "DENIED" && ex.decision_note
            ? ` ${ex.decision_note}`
            : ""}
        </p>
      ))}
      </div>

      {showConcernForm && (
        <ConcernFormModal
          journey={journey}
          contacts={contacts}
          existingOpen={openConcerns[0] ?? null}
          onClose={() => setShowConcernForm(false)}
          onSaved={() => {
            setShowConcernForm(false);
            refresh();
          }}
        />
      )}

      {showEntryForm && (
        <ConcernEntryModal
          concernId={showEntryForm}
          journey={journey}
          contacts={contacts}
          onClose={() => setShowEntryForm(null)}
          onSaved={() => {
            setShowEntryForm(null);
            refresh();
          }}
        />
      )}

      {showCorrection && (
        <TrialStartCorrectionModal
          journey={journey}
          onClose={() => setShowCorrection(false)}
          onSaved={() => {
            setShowCorrection(false);
            refresh();
          }}
        />
      )}

      {requestDraft && (
        <ExceptionRequestModal
          evaluation={requestDraft.evaluation}
          exceptionType={requestDraft.exceptionType}
          action={requestDraft.action}
          canSelfAuth={canSelfAuthorize}
          onClose={() => setRequestDraft(null)}
          onSaved={() => {
            setRequestDraft(null);
            refresh();
          }}
        />
      )}

      {overrideEval && (
        <ProtectorOverrideModal
          evaluation={overrideEval}
          onClose={() => setOverrideEval(null)}
          onSaved={() => {
            setOverrideEval(null);
            refresh();
          }}
        />
      )}

      {decideException && (
        <ExceptionDecisionModal
          exception={decideException}
          onClose={() => setDecideException(null)}
          onSaved={() => {
            setDecideException(null);
            refresh();
          }}
        />
      )}

      {showNote && (
        <TrialNoteModal
          journey={journey}
          onClose={() => setShowNote(false)}
          onSaved={() => {
            setShowNote(false);
            refresh();
          }}
        />
      )}
    </div>
  );
}

// ============================================================
// Trial Hero (spec 19.1) — one card per mattress. Shows product,
// night counter, status dot, and fee line; hosts the eligibility
// checklist, the Next Action bar, and the policy "Why?" panel.
// Everything below is a render of the evaluator's JSON — no trial
// math in this file.
// ============================================================

function TrialHeroCard({
  evaluation: e,
  onAction,
  noApproverRequests = false,
}: {
  evaluation: SleepTrialEvaluation;
  onAction: (action: string) => void;
  noApproverRequests?: boolean;
}) {
  const status = e.headline?.status ?? "UNKNOWN";
  const actionKey = headlineAction(e);
  const res = e.actions?.[actionKey];
  const fee = res?.fee ?? null;
  const endingSoon = e.display?.ending_soon ?? false;
  const tone = trialStatusTone(status, endingSoon);
  // Checklist open by default when not eligible (spec 19.2).
  const [checklistOpen, setChecklistOpen] = useState(status !== "ELIGIBLE");

  const statusLabel =
    status === "ELIGIBLE"
      ? `Eligible for ${actionKey === "RETURN" ? "return" : "exchange"}`
      : trialStatusLabel(e);

  const title =
    [e.item?.size, e.item?.product_name].filter(Boolean).join(" · ") ||
    "Mattress";

  return (
    <div className="rounded-md border border-teal-200 bg-white p-2.5">
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0">
          <p className="truncate text-sm font-semibold text-slate-900">
            {title}
            {e.item?.unit_index != null && e.item.unit_index > 1 && (
              <span className="font-normal text-slate-500">
                {" "}
                · unit {e.item.unit_index}
              </span>
            )}
          </p>
          {e.display?.night != null && (
            <p className="text-xs text-slate-600">
              Night {e.display.night} of {e.display.length_nights}
              {(e.display.extension_nights ?? 0) > 0 &&
                ` +${e.display.extension_nights} ext`}
            </p>
          )}
          <p
            className={`mt-1 flex items-center gap-1.5 text-xs font-medium ${
              tone === "red"
                ? "text-red-700"
                : tone === "amber"
                ? "text-amber-700"
                : tone === "green"
                ? "text-green-700"
                : "text-slate-600"
            }`}
          >
            <span
              className={`inline-block h-2 w-2 rounded-full ${TRIAL_STATUS_DOT[tone]}`}
            />
            {statusLabel}
          </p>
          {e.headline?.explanation && status !== "ELIGIBLE" && (
            <p className="mt-0.5 text-xs text-slate-600">
              {e.headline.explanation}
            </p>
          )}
        </div>
        <div className="shrink-0 text-right">
          {e.display?.end_date && (
            <p className="text-xs text-slate-600">
              Trial ends {formatTrialDate(e.display.end_date)}
            </p>
          )}
          {fee != null && (fee.amount_cents ?? 0) > 0 && (
            <>
              <p className="mt-0.5 text-xs text-slate-700">
                Fee now: {feeSummary(fee)}
              </p>
              {fee.next_change && (
                <p className="text-xs text-slate-500">
                  drops to{" "}
                  {(fee.next_change.to_percent_bp ?? 0) === 0 &&
                  (fee.next_change.to_flat_cents ?? 0) === 0
                    ? "no fee"
                    : `${(fee.next_change.to_percent_bp ?? 0) / 100}%${
                        (fee.next_change.to_flat_cents ?? 0) > 0
                          ? ` + ${formatMoney(fee.next_change.to_flat_cents)}`
                          : ""
                      }`}
                  {fee.next_change.on
                    ? ` on ${formatTrialDate(fee.next_change.on)}`
                    : ""}
                </p>
              )}
            </>
          )}
          {endingSoon && (
            <p className="mt-1 inline-block rounded-full border border-amber-300 bg-amber-50 px-2 py-0.5 text-[10px] font-medium text-amber-800">
              Ends in {e.display?.nights_remaining} day
              {e.display?.nights_remaining === 1 ? "" : "s"}
            </p>
          )}
        </div>
      </div>

      {/* Eligibility checklist — collapsible, open when not eligible */}
      {e.display?.night != null && (
        <>
          <button
            onClick={() => setChecklistOpen((v) => !v)}
            className="mt-2 flex items-center gap-1 text-xs font-medium text-teal-700"
          >
            <span>{checklistOpen ? "▾" : "▸"}</span> Eligibility
          </button>
          {checklistOpen && <EligibilityChecklist evaluation={e} />}
        </>
      )}

      <NextActionBar
        evaluation={e}
        onAction={onAction}
        noApprovers={noApproverRequests}
      />
      <PolicyWhyPanel evaluation={e} />
    </div>
  );
}

/** "20% + $25.00 ($359.80)" / "20% ($359.80)" / "$359.80" — display only. */
function feeSummary(fee: NonNullable<SleepTrialEvaluation["actions"]["EXCHANGE"]["fee"]>): string {
  const parts: string[] = [];
  if ((fee.percent_bp ?? 0) > 0) parts.push(`${fee.percent_bp / 100}%`);
  if ((fee.flat_cents ?? 0) > 0) parts.push(formatMoney(fee.flat_cents));
  const head = parts.length > 0 ? `${parts.join(" + ")} ` : "";
  return `${head}(${formatMoney(fee.amount_cents)})`;
}

// ============================================================
// Eligibility checklist (spec 19.2) — one line per evaluator check.
// A check shows ✗ when its reason code appears in the headline or
// additional_blockers, and ✓ otherwise. Any blocker outside the five
// named checks (fee window, approvals, missing facts, ...) is listed
// verbatim so nothing the evaluator reported is hidden.
// ============================================================

type ChecklistRow = {
  label: string;
  state: "pass" | "fail" | "warn";
  detail: string;
};

function EligibilityChecklist({ evaluation: e }: { evaluation: SleepTrialEvaluation }) {
  const res = e.actions?.[headlineAction(e)];
  const blockers = [
    ...(res && res.status !== "ELIGIBLE" && res.reason_code
      ? [
          {
            status: res.status,
            reason_code: res.reason_code,
            explanation: res.explanation,
          },
        ]
      : []),
    ...(res?.additional_blockers ?? []),
  ];
  const blockerFor = (codes: string[]) =>
    blockers.find((b) => codes.includes(b.reason_code));

  const d = e.display;
  const metOn = d?.eligible_on
    ? trialDate(d.eligible_on)
    : null;
  if (metOn) metOn.setDate(metOn.getDate() - 1);

  const rows: ChecklistRow[] = [
    {
      label: "Trial window",
      state: blockerFor(["TRIAL_EXPIRED"]) ? "fail" : "pass",
      detail:
        blockerFor(["TRIAL_EXPIRED"])?.explanation ??
        `Active (Night ${d?.night} of ${d?.length_nights})`,
    },
    {
      label: "Minimum nights",
      state: blockerFor(["MINIMUM_NIGHTS_NOT_MET"]) ? "fail" : "pass",
      detail:
        blockerFor(["MINIMUM_NIGHTS_NOT_MET"])?.explanation ??
        `Met${metOn ? ` ${metOn.toLocaleDateString()}` : ""}`,
    },
    {
      label: "Protector",
      state: blockerFor(["PROTECTOR_MISSING", "PROTECTOR_RETURNED"])
        ? "fail"
        : (res?.warnings ?? []).includes("PROTECTOR_MISSING")
        ? "warn"
        : "pass",
      detail:
        blockerFor(["PROTECTOR_MISSING", "PROTECTOR_RETURNED"])
          ?.explanation ??
        ((res?.warnings ?? []).includes("PROTECTOR_MISSING")
          ? explainSleepTrialReason("PROTECTOR_MISSING")
          : "Met"),
    },
    {
      label: "Exchanges",
      state: blockerFor(["EXCHANGE_LIMIT_REACHED"]) ? "fail" : "pass",
      detail:
        blockerFor(["EXCHANGE_LIMIT_REACHED"])?.explanation ??
        `${d?.exchanges_used ?? 0} of ${d?.exchanges_allowed ?? "?"} used`,
    },
    {
      label: "Sleep concern",
      state: blockerFor(["SLEEP_CONCERN_REQUIRED"]) ? "fail" : "pass",
      detail:
        blockerFor(["SLEEP_CONCERN_REQUIRED"])?.explanation ??
        (e.item?.has_open_concern ? "Documented" : "Met"),
    },
  ];

  // Any blocker outside the five named checks gets its own line — the
  // checklist is a straight render of headline + additional_blockers.
  const covered = new Set([
    "TRIAL_EXPIRED",
    "MINIMUM_NIGHTS_NOT_MET",
    "PROTECTOR_MISSING",
    "PROTECTOR_RETURNED",
    "EXCHANGE_LIMIT_REACHED",
    "SLEEP_CONCERN_REQUIRED",
  ]);
  for (const b of blockers) {
    if (covered.has(b.reason_code)) continue;
    covered.add(b.reason_code);
    rows.push({
      label: sleepTrialReasonLabel(b.reason_code),
      state: "fail",
      detail: b.explanation,
    });
  }

  return (
    <ul className="mt-1 space-y-0.5">
      {rows.map((r) => (
        <li key={r.label} className="flex items-start gap-2 text-xs">
          <span className="w-24 shrink-0 truncate text-slate-500">
            {r.label}
          </span>
          <span
            className={
              r.state === "pass"
                ? "text-green-600"
                : r.state === "warn"
                ? "text-amber-600"
                : "text-red-600"
            }
          >
            {r.state === "pass" ? "✓" : r.state === "warn" ? "!" : "✗"}
          </span>
          <span className="min-w-0 text-slate-700">{r.detail}</span>
        </li>
      ))}
    </ul>
  );
}

// ============================================================
// Next Action bar (spec 19.3) — primary = most relevant allowed
// action, secondaries in a row, the rest under "More". Actions with
// no backing RPC render disabled with a "Coming soon" tooltip.
// ============================================================

function NextActionBar({
  evaluation: e,
  onAction,
  noApprovers = false,
}: {
  evaluation: SleepTrialEvaluation;
  onAction: (action: string) => void;
  noApprovers?: boolean;
}) {
  const [moreOpen, setMoreOpen] = useState(false);
  const allowed = e.allowed_ui_actions ?? [];
  const ordered = ACTION_PRIORITY.filter((a) => allowed.includes(a)).concat(
    allowed.filter((a) => !ACTION_PRIORITY.includes(a))
  );
  if (ordered.length === 0 && e.item?.status !== "ACTIVE") return null;

  // Spec 15.5: request actions are replaced (disabled + message) when
  // nobody can approve and the caller can't self-authorize.
  const requestBlocked = (a: string) => noApprovers && REQUEST_ACTIONS.has(a);
  const actionTitle = (a: string, comingSoon: boolean) =>
    comingSoon
      ? "Coming soon"
      : requestBlocked(a)
      ? NO_APPROVER_MESSAGE
      : undefined;

  const [primary, ...rest] = ordered;
  const secondary = rest.slice(0, 3);
  const more = rest.slice(3);

  // Spec 20 rule: a blocked action is shown disabled with its reason when
  // the user would reasonably expect it (e.g. Start Exchange while blocked).
  const showBlockedExchange =
    e.item?.status === "ACTIVE" &&
    e.actions?.EXCHANGE?.status !== "ELIGIBLE" &&
    !ordered.includes("START_EXCHANGE");

  const btnBase =
    "rounded-md px-2.5 py-1.5 text-xs font-medium disabled:cursor-not-allowed disabled:opacity-50";

  const renderAction = (a: string, isPrimary = false) => {
    const comingSoon = COMING_SOON_ACTIONS.has(a);
    const blocked = requestBlocked(a);
    return (
      <button
        key={a}
        disabled={comingSoon || blocked}
        title={actionTitle(a, comingSoon)}
        onClick={() => {
          setMoreOpen(false);
          onAction(a);
        }}
        className={
          isPrimary
            ? `${btnBase} bg-teal-700 text-white hover:bg-teal-800`
            : `${btnBase} border border-slate-300 bg-white text-slate-700 hover:bg-slate-50`
        }
      >
        {ACTION_LABELS[a] ?? a}
      </button>
    );
  };

  return (
    <div className="mt-2 flex flex-wrap items-center gap-1.5">
      {primary && renderAction(primary, true)}
      {secondary.map((a) => renderAction(a))}
      {showBlockedExchange && (
        <button
          disabled
          title={e.actions?.EXCHANGE?.explanation ?? "Blocked"}
          className={`${btnBase} border border-slate-300 bg-white text-slate-700`}
        >
          Start Exchange
        </button>
      )}
      {more.length > 0 && (
        <div className="relative">
          <button
            onClick={() => setMoreOpen((v) => !v)}
            className={`${btnBase} border border-slate-300 bg-white text-slate-700 hover:bg-slate-50`}
          >
            More ▾
          </button>
          {moreOpen && (
            <>
              <div
                className="fixed inset-0 z-10"
                onClick={() => setMoreOpen(false)}
              />
              <div className="absolute left-0 z-20 mt-1 min-w-[190px] rounded-md border border-slate-200 bg-white py-1 shadow-lg">
                {more.map((a) => {
                  const comingSoon = COMING_SOON_ACTIONS.has(a);
                  const blocked = requestBlocked(a);
                  return (
                    <button
                      key={a}
                      disabled={comingSoon || blocked}
                      title={actionTitle(a, comingSoon)}
                      onClick={() => {
                        setMoreOpen(false);
                        onAction(a);
                      }}
                      className="block w-full px-3 py-1.5 text-left text-xs text-slate-700 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-50"
                    >
                      {ACTION_LABELS[a] ?? a}
                      {comingSoon && (
                        <span className="ml-1 text-slate-400">
                          — coming soon
                        </span>
                      )}
                    </button>
                  );
                })}
              </div>
            </>
          )}
        </div>
      )}
    </div>
  );
}

// ============================================================
// Policy "Why?" panel (spec 19.4, collapsed by default) — each bound
// term with its source label, straight from policy.term_sources.
// ============================================================

const TERM_SECTION_LABELS: Record<string, string> = {
  trial: "Trial",
  exchange: "Exchange",
  return: "Return",
  fees: "Fees",
  protector: "Protector",
  split_king: "Split king",
  extensions: "Extensions",
  replacement: "Replacement",
  notifications: "Notifications",
};

function humanizeTermKey(key: string): string {
  const [section, ...rest] = key.split(".");
  const sectionLabel =
    TERM_SECTION_LABELS[section] ??
    section.charAt(0).toUpperCase() + section.slice(1).replace(/_/g, " ");
  const field = rest.join(" ").replace(/_/g, " ");
  return field
    ? `${sectionLabel} — ${field.charAt(0).toUpperCase()}${field.slice(1)}`
    : sectionLabel;
}

// "SAME_AS_POLICY" -> "Same as policy" — for enum-valued terms.
function humanizeToken(token: string): string {
  return token.charAt(0) + token.slice(1).toLowerCase().replace(/_/g, " ");
}

// Resolved value display for the "Why?" panel — formatting only; the value
// comes verbatim from the evaluator's policy.resolved_terms.
function termValue(terms: Record<string, unknown>, key: string): unknown {
  return key
    .split(".")
    .reduce<unknown>(
      (acc, part) =>
        acc != null && typeof acc === "object"
          ? (acc as Record<string, unknown>)[part]
          : undefined,
      terms
    );
}

function formatTermValue(key: string, value: unknown): string {
  if (value == null) return "—";
  if (typeof value === "boolean") return value ? "On" : "Off";
  if (typeof value === "number") {
    if (key.endsWith("_nights")) return `${value} nights`;
    if (key.endsWith("_days")) return `${value} days`;
    if (key.endsWith("_cents")) return formatMoney(value);
    if (key.endsWith("_bp")) return `${value / 100}%`;
    return String(value);
  }
  if (Array.isArray(value)) {
    // e.g. inspection checklist -> "Clean, no stains, No damage, ..."
    return value.map((v) => formatTermValue(key, v)).join(", ");
  }
  if (typeof value === "object") {
    // e.g. {"rule":"SAME_AS_POLICY"} -> "Same as policy"; otherwise join the
    // values rather than dumping raw JSON.
    const rec = value as Record<string, unknown>;
    if (typeof rec.rule === "string") return humanizeToken(rec.rule);
    return Object.values(rec)
      .map((v) => (typeof v === "string" ? humanizeToken(v) : String(v)))
      .join(", ");
  }
  if (typeof value === "string" && /^[A-Z0-9_]+$/.test(value)) {
    return humanizeToken(value);
  }
  return String(value);
}

function PolicyWhyPanel({ evaluation: e }: { evaluation: SleepTrialEvaluation }) {
  const [open, setOpen] = useState(false);
  const sources = e.policy?.term_sources ?? {};
  const terms = e.policy?.resolved_terms ?? {};
  const keys = Object.keys(sources).sort();
  if (keys.length === 0 && !e.policy?.version_label) return null;

  return (
    <div className="mt-2 border-t border-slate-100 pt-1.5">
      <button
        onClick={() => setOpen((v) => !v)}
        className="flex items-center gap-1 text-xs font-medium text-slate-500"
      >
        <span>{open ? "▾" : "▸"}</span>
        Why these terms?
        {e.policy?.version_label ? ` — ${e.policy.version_label}` : ""}
      </button>
      {open && (
        <ul className="mt-1 space-y-1.5 rounded-md bg-slate-50 p-2">
          {keys.map((k) => {
            const src = sources[k];
            const label =
              typeof src === "string"
                ? "Company policy"
                : src?.label ??
                  (src?.scope ? `${src.scope} rule` : "Override");
            return (
              <li key={k} className="text-xs">
                <div className="text-slate-600">
                  {humanizeTermKey(k)}
                </div>
                <div className="pl-3 text-slate-400">
                  {formatTermValue(k, termValue(terms, k))}: {label}
                </div>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}

// ============================================================
// Protector override (072) — direct owner/admin action with a
// required reason. Permanent for this item; audited server-side.
// ============================================================

function ProtectorOverrideModal({
  evaluation: e,
  onClose,
  onSaved,
}: {
  evaluation: SleepTrialEvaluation;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    if (!reason.trim()) return;
    setSaving(true);
    setError(null);
    try {
      await overrideSleepTrialProtector(e.trial_item_id, reason.trim());
      onSaved();
    } catch (err: any) {
      setError(err.message ?? "Failed to record override");
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal onClose={onClose} dirty={reason.trim() !== ""} saving={saving}>
      <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
        <h2 className="mb-2 text-lg font-semibold text-slate-900">
          Override protector requirement
        </h2>
        <p className="mb-3 text-sm text-slate-600">
          No qualifying mattress protector is on this order. Overriding treats
          the protector requirement as satisfied for{" "}
          {e.item?.product_name ?? "this mattress"} going forward — permanent,
          and recorded with your name and reason.
        </p>
        <textarea
          value={reason}
          onChange={(ev) => setReason(ev.target.value)}
          placeholder="Reason for the override (required) — e.g. protector purchased on a different order"
          rows={3}
          className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
        />
        {error && (
          <p className="mt-2 rounded-md border border-red-200 bg-red-50 p-2 text-sm text-red-700">
            {error}
          </p>
        )}
        <div className="mt-4 flex gap-2">
          <button
            onClick={save}
            disabled={!reason.trim() || saving}
            className="flex-1 rounded-md bg-teal-700 px-3 py-2 text-sm font-medium text-white hover:bg-teal-800 disabled:opacity-50"
          >
            {saving ? "Saving…" : "Override requirement"}
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

// ============================================================
// ADD_NOTE — internal note on the journey (existing
// record_journey_interaction backing, sleep-trial topic).
// ============================================================

function TrialNoteModal({
  journey,
  onClose,
  onSaved,
}: {
  journey: JourneyWithDetails;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    if (!note.trim()) return;
    setSaving(true);
    setError(null);
    try {
      await recordJourneyInteraction({
        journey_id: journey.id,
        interaction_type: "internal_note",
        summary: note.trim(),
        idempotency_key: crypto.randomUUID(),
        topic: "return_exchange",
        channel: "internal",
        direction: "internal",
        is_internal: true,
      });
      onSaved();
    } catch (err: any) {
      setError(err.message ?? "Failed to save note");
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal onClose={onClose} dirty={note.trim() !== ""} saving={saving}>
      <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
        <h2 className="mb-2 text-lg font-semibold text-slate-900">Add note</h2>
        <textarea
          value={note}
          onChange={(e) => setNote(e.target.value)}
          placeholder="Internal note about this sleep trial"
          rows={3}
          className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
        />
        {error && (
          <p className="mt-2 rounded-md border border-red-200 bg-red-50 p-2 text-sm text-red-700">
            {error}
          </p>
        )}
        <div className="mt-4 flex gap-2">
          <button
            onClick={save}
            disabled={!note.trim() || saving}
            className="flex-1 rounded-md bg-teal-700 px-3 py-2 text-sm font-medium text-white hover:bg-teal-800 disabled:opacity-50"
          >
            {saving ? "Saving…" : "Save note"}
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

// ============================================================
// Concern card + history (source doc §76, §94)
// ============================================================

function ConcernCard({
  concern,
  issues,
  expanded,
  onToggle,
  onAddUpdate,
  onChanged,
  canExchange,
}: {
  concern: SleepConcern;
  issues: SleepConcernIssue[];
  expanded: boolean;
  onToggle: () => void;
  onAddUpdate: () => void;
  onChanged: () => void;
  canExchange: boolean;
}) {
  const [entries, setEntries] = useState<SleepConcernEntry[]>([]);
  const [diagnostics, setDiagnostics] = useState<SleepConcernDiagnostic[]>([]);
  const [exchangeError, setExchangeError] = useState<string | null>(null);

  useEffect(() => {
    if (expanded) {
      fetchSleepConcernEntries(concern.id).then(setEntries);
      fetchSleepConcernDiagnostics(concern.id).then(setDiagnostics);
    }
  }, [expanded, concern.id, concern.updated_at]);

  const open = OPEN_CONCERN_STATUSES.includes(concern.status);
  const lastRecommendation = entries.find((e) => e.recommendation_summary);

  return (
    <div
      className={`mt-2 rounded-md border p-2 text-sm ${
        concern.status === "resolved"
          ? "border-slate-200 bg-slate-50"
          : concern.status === "exchange_requested"
          ? "border-purple-300 bg-purple-50"
          : "border-teal-300 bg-white"
      }`}
    >
      <div className="flex items-start justify-between gap-2">
        <div>
          <p className="text-xs font-semibold uppercase text-slate-600">
            {CONCERN_STATUS_LABELS[concern.status]} Sleep Concern
          </p>
          <p className="mt-0.5 text-sm font-medium text-slate-800">
            {issues.map((i) => i.issue_name).join(" · ") || "—"}
          </p>
          <p className="text-xs text-slate-500">
            Opened {new Date(concern.opened_at).toLocaleDateString()}
            {concern.opened_by ? ` by ${concern.opened_by.name}` : ""}
            {concern.resolved_at &&
              ` · Resolved ${new Date(concern.resolved_at).toLocaleDateString()}`}
          </p>
          {lastRecommendation && (
            <p className="mt-0.5 text-xs text-slate-600">
              Last recommendation: {lastRecommendation.recommendation_summary}
            </p>
          )}
          {concern.status === "resolved" && concern.resolution_summary && (
            <p className="mt-0.5 text-xs text-slate-600">
              Resolution: {concern.resolution_summary}
            </p>
          )}
          {concern.status === "exchange_requested" && (
            <p className="mt-0.5 text-xs font-medium text-purple-700">
              Customer wants an exchange. No exchange workflow exists yet —
              process it through your normal exchange procedure.
            </p>
          )}
        </div>
        <button
          onClick={onToggle}
          className="shrink-0 text-xs text-brand-600 hover:text-brand-700"
        >
          {expanded ? "Hide" : "View history"}
        </button>
      </div>

      {expanded && (
        <div className="mt-2 space-y-2 border-t border-slate-200 pt-2">
          {diagnostics.length > 0 && (
            <div className="rounded bg-slate-50 p-2">
              <p className="text-xs font-semibold uppercase text-slate-500">
                Diagnostics
              </p>
              {diagnostics.map((d) => (
                <p key={d.id} className="mt-0.5 text-xs text-slate-600">
                  {d.question_snapshot?.text ?? "Question"}:{" "}
                  <span className="font-medium">{d.response}</span>
                </p>
              ))}
            </div>
          )}
          {entries.map((e) => (
            <div key={e.id} className="rounded bg-slate-50 p-2 text-xs">
              <p className="text-slate-400">
                {new Date(e.occurred_at).toLocaleString()} ·{" "}
                {e.created_by?.name ?? "Unknown"}
                {e.entry_type === "status_change" ? " · status change" : ""}
              </p>
              {e.customer_report && (
                <p className="mt-0.5 text-slate-700">
                  Customer: {e.customer_report}
                </p>
              )}
              {e.recommendation_summary && (
                <p className="mt-0.5 text-slate-700">
                  Recommended: {e.recommendation_summary}
                </p>
              )}
              {e.employee_notes && (
                <p className="mt-0.5 text-slate-500">Note: {e.employee_notes}</p>
              )}
            </div>
          ))}
          {entries.length === 0 && (
            <p className="text-xs text-slate-500">No updates yet.</p>
          )}
        </div>
      )}

      {open && (
        <div className="mt-2 flex flex-wrap gap-2">
          <button
            onClick={onAddUpdate}
            className="rounded-md bg-teal-700 px-2 py-1 text-xs font-medium text-white hover:bg-teal-800"
          >
            Add Update
          </button>
          {canExchange && concern.status !== "exchange_requested" && (
            <button
              onClick={async () => {
                setExchangeError(null);
                try {
                  await requestConcernExchange(concern.id);
                  onChanged();
                } catch (e: any) {
                  setExchangeError(e.message ?? "Failed to request exchange");
                }
              }}
              className="rounded-md border border-purple-300 bg-white px-2 py-1 text-xs font-medium text-purple-700 hover:bg-purple-50"
            >
              Customer wants an exchange
            </button>
          )}
        </div>
      )}
      {exchangeError && (
        <p className="mt-1 text-xs text-red-600">{exchangeError}</p>
      )}
    </div>
  );
}

// ============================================================
// Start Sleep Concern modal (source doc §95)
// ============================================================

function ConcernFormModal({
  journey,
  contacts,
  existingOpen,
  onClose,
  onSaved,
}: {
  journey: JourneyWithDetails;
  contacts: CustomerContact[];
  existingOpen: SleepConcern | null;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [keys] = useState(() => ({
    concern: crypto.randomUUID(),
    followUp: crypto.randomUUID(),
  }));
  const [types, setTypes] = useState<SleepConcernType[]>([]);
  const [questions, setQuestions] = useState<SleepConcernQuestion[]>([]);
  const [selected, setSelected] = useState<Map<string, string>>(new Map()); // typeId -> name
  const [answers, setAnswers] = useState<Record<string, string>>({});
  const [customerReport, setCustomerReport] = useState("");
  const [recommendation, setRecommendation] = useState("");
  const [employeeNotes, setEmployeeNotes] = useState("");
  const [contactId, setContactId] = useState("");
  const [followUpDays, setFollowUpDays] = useState("");
  const [followUpMethod, setFollowUpMethod] = useState("call");
  const [allowDuplicate, setAllowDuplicate] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    fetchSleepConcernConfig().then(({ types, questions }) => {
      setTypes(types);
      setQuestions(questions);
    });
  }, []);

  // Questions are seeded per concern type, so the same question can
  // exist under several selected issues. Group by identical text +
  // options and show each group once; the saved diagnostic uses the
  // first question's id and lists every sharing issue in the snapshot.
  const questionGroups = useMemo(() => {
    const ids = new Set(selected.keys());
    const relevant = questions.filter(
      (q) => q.concern_type_id === null || ids.has(q.concern_type_id)
    );
    const groups = new Map<string, SleepConcernQuestion[]>();
    for (const q of relevant) {
      const key = `${q.question_text}${JSON.stringify(q.options ?? null)}`;
      const g = groups.get(key);
      if (g) g.push(q);
      else groups.set(key, [q]);
    }
    return Array.from(groups.values());
  }, [questions, selected]);

  function toggleIssue(t: SleepConcernType) {
    setSelected((prev) => {
      const next = new Map(prev);
      if (next.has(t.id)) next.delete(t.id);
      else next.set(t.id, t.name);
      return next;
    });
  }

  async function save() {
    if (selected.size === 0) return;
    setSaving(true);
    setError(null);

    const issues: IssueInput[] = Array.from(selected.entries()).map(
      ([concern_type_id, name]) => ({ concern_type_id, name })
    );
    const diagnostics: DiagnosticInput[] = questionGroups
      .filter((g) => (answers[g[0].id] ?? "").trim() !== "")
      .map((g) => {
        const q = g[0];
        const sharedNames = g
          .map((x) =>
            x.concern_type_id
              ? selected.get(x.concern_type_id) ??
                types.find((t) => t.id === x.concern_type_id)?.name
              : undefined
          )
          .filter((n): n is string => !!n);
        return {
          question_id: q.id,
          question_snapshot: {
            text: q.question_text,
            options: q.options,
            concern_type_name: sharedNames.length
              ? sharedNames.join(", ")
              : undefined,
          },
          response: answers[q.id].trim(),
        };
      });

    const days = parseInt(followUpDays, 10);
    try {
      await openSleepConcern({
        journey_id: journey.id,
        issues,
        idempotency_key: keys.concern,
        customer_report: customerReport.trim() || null,
        employee_notes: employeeNotes.trim() || null,
        recommendation: recommendation.trim() || null,
        diagnostics,
        follow_up:
          days > 0
            ? {
                due_at: new Date(Date.now() + days * 86400000).toISOString(),
                method: followUpMethod,
                idempotency_key: keys.followUp,
              }
            : null,
        contact_id: contactId || null,
        allow_duplicate: allowDuplicate,
      });
      onSaved();
    } catch (e: any) {
      const msg = e.message ?? "";
      if (msg.startsWith("existing_open_concern")) {
        setError(
          "A sleep concern is already open for this journey. Continue the existing concern, or confirm below to start a separate episode."
        );
        setAllowDuplicate(true);
      } else {
        setError(msg || "Failed to save concern");
      }
    } finally {
      setSaving(false);
    }
  }

  const formDirty =
    selected.size > 0 ||
    Object.values(answers).some((v) => v.trim() !== "") ||
    customerReport.trim() !== "" ||
    recommendation.trim() !== "" ||
    employeeNotes.trim() !== "" ||
    contactId !== "" ||
    followUpDays !== "" ||
    followUpMethod !== "call";

  return (
    <Modal onClose={onClose} dirty={formDirty} saving={saving}>
      <div className="max-h-[90vh] w-full max-w-md overflow-y-auto rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
        <h2 className="mb-3 text-lg font-semibold text-slate-900">
          Start Sleep Concern
        </h2>

        {existingOpen && !allowDuplicate && (
          <p className="mb-3 rounded-md border border-amber-300 bg-amber-50 p-2 text-xs text-amber-800">
            A concern is already open for this journey — consider adding an
            update to it instead of starting a new episode.
          </p>
        )}
        {allowDuplicate && (
          <p className="mb-3 rounded-md border border-amber-300 bg-amber-50 p-2 text-xs text-amber-800">
            Saving will create a new, separate concern episode.
          </p>
        )}

        <p className="mb-1 text-xs font-medium uppercase text-slate-500">
          Issues <span className="font-normal">(select all that apply)</span>
        </p>
        <div className="mb-4 flex flex-wrap gap-1.5">
          {types.map((t) => (
            <button
              key={t.id}
              onClick={() => toggleIssue(t)}
              className={`rounded-full px-3 py-1.5 text-xs font-medium ${
                selected.has(t.id)
                  ? "bg-teal-700 text-white"
                  : "bg-slate-100 text-slate-700 hover:bg-slate-200"
              }`}
            >
              {t.name}
            </button>
          ))}
        </div>

        {questionGroups.length > 0 && (
          <div className="mb-4 space-y-3">
            <p className="text-xs font-medium uppercase text-slate-500">
              Guided questions
            </p>
            {questionGroups.map((g) => {
              const q = g[0];
              return (
              <div key={q.id}>
                <p className="text-sm text-slate-700">{q.question_text}</p>
                {q.options ? (
                  <div className="mt-1 flex flex-wrap gap-1.5">
                    {q.options.map((o) => (
                      <button
                        key={o}
                        onClick={() =>
                          setAnswers((a) => ({ ...a, [q.id]: o }))
                        }
                        className={`rounded-full px-2.5 py-1 text-xs font-medium ${
                          answers[q.id] === o
                            ? "bg-brand-600 text-white"
                            : "bg-slate-100 text-slate-700 hover:bg-slate-200"
                        }`}
                      >
                        {o}
                      </button>
                    ))}
                  </div>
                ) : (
                  <input
                    value={answers[q.id] ?? ""}
                    onChange={(e) =>
                      setAnswers((a) => ({ ...a, [q.id]: e.target.value }))
                    }
                    className="mt-1 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm"
                  />
                )}
              </div>
              );
            })}
          </div>
        )}

        <p className="mb-1 text-xs font-medium uppercase text-slate-500">
          Customer report
        </p>
        <textarea
          value={customerReport}
          onChange={(e) => setCustomerReport(e.target.value)}
          rows={2}
          placeholder="What the customer said, in their words"
          className="mb-3 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
        />

        <p className="mb-1 text-xs font-medium uppercase text-slate-500">
          Recommendation
        </p>
        <textarea
          value={recommendation}
          onChange={(e) => setRecommendation(e.target.value)}
          rows={2}
          placeholder="e.g. Rotate mattress 180°, try 7 more nights, lower-profile pillow"
          className="mb-3 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
        />

        <p className="mb-1 text-xs font-medium uppercase text-slate-500">
          Internal note <span className="font-normal">(optional)</span>
        </p>
        <textarea
          value={employeeNotes}
          onChange={(e) => setEmployeeNotes(e.target.value)}
          rows={2}
          className="mb-3 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
        />

        <div className="mb-3 grid grid-cols-2 gap-2">
          <div>
            <p className="mb-1 text-xs font-medium uppercase text-slate-500">
              Spoke with
            </p>
            <select
              value={contactId}
              onChange={(e) => setContactId(e.target.value)}
              className="w-full rounded-md border border-slate-300 bg-white px-2 py-1.5 text-sm"
            >
              <option value="">
                {journey.customer
                  ? `${journey.customer.first_name} ${journey.customer.last_name} (primary)`
                  : "Primary customer"}
              </option>
              {contacts.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                  {c.role_label ? ` — ${c.role_label}` : ""}
                </option>
              ))}
            </select>
          </div>
          <div>
            <p className="mb-1 text-xs font-medium uppercase text-slate-500">
              Follow up in days
            </p>
            <div className="flex gap-1">
              <input
                type="number"
                min={0}
                value={followUpDays}
                onChange={(e) => setFollowUpDays(e.target.value)}
                placeholder="None"
                className="w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm"
              />
              <select
                value={followUpMethod}
                onChange={(e) => setFollowUpMethod(e.target.value)}
                className="rounded-md border border-slate-300 bg-white px-1 py-1.5 text-sm"
              >
                <option value="call">Call</option>
                <option value="text">Text</option>
                <option value="email">Email</option>
              </select>
            </div>
          </div>
        </div>

        {error && (
          <p className="mb-3 rounded-md border border-red-200 bg-red-50 p-2 text-sm text-red-700">
            {error}
          </p>
        )}

        <div className="flex gap-2">
          <button
            onClick={save}
            disabled={selected.size === 0 || saving}
            className="flex-1 rounded-md bg-teal-700 px-3 py-2 text-sm font-medium text-white hover:bg-teal-800 disabled:opacity-50"
          >
            {saving ? "Saving…" : "Save Concern"}
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
// Add concern update (source doc §96)
// ============================================================

function ConcernEntryModal({
  concernId,
  journey,
  contacts,
  onClose,
  onSaved,
}: {
  concernId: string;
  journey: JourneyWithDetails;
  contacts: CustomerContact[];
  onClose: () => void;
  onSaved: () => void;
}) {
  const [keys] = useState(() => ({
    entry: crypto.randomUUID(),
    followUp: crypto.randomUUID(),
  }));
  const [customerReport, setCustomerReport] = useState("");
  const [recommendation, setRecommendation] = useState("");
  const [employeeNotes, setEmployeeNotes] = useState("");
  const [newStatus, setNewStatus] = useState<string>("");
  const [resolutionSummary, setResolutionSummary] = useState("");
  const [contactId, setContactId] = useState("");
  const [followUpDays, setFollowUpDays] = useState("");
  const [followUpMethod, setFollowUpMethod] = useState("call");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    if (!customerReport.trim() && !recommendation.trim() && !employeeNotes.trim() && !newStatus) return;
    setSaving(true);
    setError(null);
    const days = parseInt(followUpDays, 10);
    try {
      await addSleepConcernEntry({
        concern_id: concernId,
        idempotency_key: keys.entry,
        customer_report: customerReport.trim() || null,
        employee_notes: employeeNotes.trim() || null,
        recommendation: recommendation.trim() || null,
        new_status: (newStatus || null) as any,
        resolution_summary:
          newStatus === "resolved" ? resolutionSummary.trim() || null : null,
        follow_up:
          days > 0
            ? {
                due_at: new Date(Date.now() + days * 86400000).toISOString(),
                method: followUpMethod,
                idempotency_key: keys.followUp,
              }
            : null,
        contact_id: contactId || null,
      });
      onSaved();
    } catch (e: any) {
      setError(e.message ?? "Failed to save update");
    } finally {
      setSaving(false);
    }
  }

  const formDirty =
    customerReport.trim() !== "" ||
    recommendation.trim() !== "" ||
    employeeNotes.trim() !== "" ||
    newStatus !== "" ||
    resolutionSummary.trim() !== "" ||
    contactId !== "" ||
    followUpDays !== "" ||
    followUpMethod !== "call";

  return (
    <Modal onClose={onClose} dirty={formDirty} saving={saving}>
      <div className="max-h-[90vh] w-full max-w-md overflow-y-auto rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
        <h2 className="mb-3 text-lg font-semibold text-slate-900">
          Concern Update
        </h2>

        <p className="mb-1 text-xs font-medium uppercase text-slate-500">
          Customer report
        </p>
        <textarea
          value={customerReport}
          onChange={(e) => setCustomerReport(e.target.value)}
          rows={2}
          placeholder="What changed since the last update?"
          className="mb-3 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
        />

        <p className="mb-1 text-xs font-medium uppercase text-slate-500">
          New recommendation
        </p>
        <textarea
          value={recommendation}
          onChange={(e) => setRecommendation(e.target.value)}
          rows={2}
          placeholder="Leave blank to keep prior recommendations"
          className="mb-3 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
        />

        <p className="mb-1 text-xs font-medium uppercase text-slate-500">
          Internal note <span className="font-normal">(optional)</span>
        </p>
        <textarea
          value={employeeNotes}
          onChange={(e) => setEmployeeNotes(e.target.value)}
          rows={2}
          className="mb-3 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
        />

        <div className="mb-3 grid grid-cols-2 gap-2">
          <div>
            <p className="mb-1 text-xs font-medium uppercase text-slate-500">
              Concern status
            </p>
            <select
              value={newStatus}
              onChange={(e) => setNewStatus(e.target.value)}
              className="w-full rounded-md border border-slate-300 bg-white px-2 py-1.5 text-sm"
            >
              <option value="">No change</option>
              <option value="monitoring">Monitoring</option>
              <option value="resolved">Resolved</option>
              <option value="escalated">Escalated</option>
            </select>
          </div>
          <div>
            <p className="mb-1 text-xs font-medium uppercase text-slate-500">
              Spoke with
            </p>
            <select
              value={contactId}
              onChange={(e) => setContactId(e.target.value)}
              className="w-full rounded-md border border-slate-300 bg-white px-2 py-1.5 text-sm"
            >
              <option value="">
                {journey.customer
                  ? `${journey.customer.first_name} ${journey.customer.last_name} (primary)`
                  : "Primary customer"}
              </option>
              {contacts.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                  {c.role_label ? ` — ${c.role_label}` : ""}
                </option>
              ))}
            </select>
          </div>
        </div>

        {newStatus === "resolved" && (
          <div className="mb-3">
            <p className="mb-1 text-xs font-medium uppercase text-slate-500">
              Resolution summary
            </p>
            <input
              value={resolutionSummary}
              onChange={(e) => setResolutionSummary(e.target.value)}
              placeholder="e.g. Customer reports comfort has improved"
              className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
            />
          </div>
        )}

        <div className="mb-3 flex items-center gap-2 text-sm">
          <span className="text-slate-600">Next follow-up in</span>
          <input
            type="number"
            min={0}
            value={followUpDays}
            onChange={(e) => setFollowUpDays(e.target.value)}
            placeholder="None"
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
          </select>
        </div>

        {error && (
          <p className="mb-3 rounded-md border border-red-200 bg-red-50 p-2 text-sm text-red-700">
            {error}
          </p>
        )}

        <div className="flex gap-2">
          <button
            onClick={save}
            disabled={saving}
            className="flex-1 rounded-md bg-teal-700 px-3 py-2 text-sm font-medium text-white hover:bg-teal-800 disabled:opacity-50"
          >
            {saving ? "Saving…" : "Save Update"}
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
// Trial-start correction (source doc §65)
// ============================================================

function TrialStartCorrectionModal({
  journey,
  onClose,
  onSaved,
}: {
  journey: JourneyWithDetails;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [date, setDate] = useState(journey.delivered_at ?? "");
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function save() {
    if (!date || !reason.trim()) return;
    setSaving(true);
    setError(null);
    try {
      await correctTrialStart(journey.id, date, reason.trim());
      onSaved();
    } catch (e: any) {
      setError(e.message ?? "Failed to correct trial start");
    } finally {
      setSaving(false);
    }
  }

  const formDirty =
    date !== (journey.delivered_at ?? "") || reason.trim() !== "";

  return (
    <Modal onClose={onClose} dirty={formDirty} saving={saving}>
      <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
        <h2 className="mb-2 text-lg font-semibold text-slate-900">
          Correct trial start date
        </h2>
        <p className="mb-3 text-sm text-slate-600">
          Current start: {journey.delivered_at ?? "—"}. The correction is
          preserved in history and recalculates all trial dates.
        </p>
        <input
          type="date"
          value={date}
          onChange={(e) => setDate(e.target.value)}
          className="mb-3 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
        />
        <textarea
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="Reason for correction (required)"
          rows={2}
          className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
        />
        {error && (
          <p className="mt-2 rounded-md border border-red-200 bg-red-50 p-2 text-sm text-red-700">
            {error}
          </p>
        )}
        <div className="mt-4 flex gap-2">
          <button
            onClick={save}
            disabled={!date || !reason.trim() || saving}
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

// ============================================================
// Exception request (074). Files against the NEW exceptions table —
// the evaluator's offered exception_type decides which type is
// requested; employees never pick one. PENDING rows route to My Work
// approvers; self-authorized callers land APPROVED immediately.
// ============================================================

function ExceptionRequestModal({
  evaluation,
  exceptionType,
  action,
  canSelfAuth,
  onClose,
  onSaved,
}: {
  evaluation: SleepTrialEvaluation;
  exceptionType: string;
  action: "EXCHANGE" | "RETURN" | null;
  canSelfAuth: boolean;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [reasons, setReasons] = useState<ExceptionReason[]>([]);
  const [reasonId, setReasonId] = useState("");
  const [reasonNote, setReasonNote] = useState("");
  const [nights, setNights] = useState("");
  const [feePct, setFeePct] = useState("0");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Generated once per open so a retry reuses the key (060 pattern).
  const [idempotencyKey] = useState(() => crypto.randomUUID());

  useEffect(() => {
    fetchExceptionReasons().then((r) => {
      setReasons(r);
      if (r.length > 0) setReasonId((prev) => prev || r[0].id);
    });
  }, []);

  const reason = reasons.find((r) => r.id === reasonId) ?? null;
  const noteRequired = !!reason?.requires_note || canSelfAuth;
  const res = action ? evaluation.actions?.[action] : null;

  async function save() {
    if (!reasonId) {
      setError("Pick a reason");
      return;
    }
    if (noteRequired && !reasonNote.trim()) {
      setError(
        canSelfAuth && !reason?.requires_note
          ? "Self-authorized exceptions require a written note"
          : "A note is required for this reason"
      );
      return;
    }
    const requestedTerms: Record<string, unknown> = {};
    if (exceptionType === "EXTEND_TRIAL") {
      const n = Math.round(Number(nights));
      if (!Number.isFinite(n) || n <= 0) {
        setError("Enter the number of nights to extend");
        return;
      }
      requestedTerms.extension_nights = n;
    }
    if (exceptionType === "FEE_WAIVER") {
      const pct = Number(feePct || "0");
      if (!Number.isFinite(pct) || pct < 0 || pct > 100) {
        setError("Fee percent must be 0–100");
        return;
      }
      requestedTerms.fee_percent_bp = Math.round(pct * 100);
    }
    setSaving(true);
    setError(null);
    try {
      await requestTrialItemException({
        trialItemId: evaluation.trial_item_id,
        exceptionType,
        action,
        reasonCodeId: reasonId,
        reasonNote: reasonNote.trim() || null,
        requestedTerms,
        idempotencyKey,
      });
      onSaved();
    } catch (e: any) {
      setError(e.message ?? "Failed to submit request");
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal onClose={onClose} dirty={reasonNote.trim() !== ""} saving={saving}>
      <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
        <h2 className="mb-2 text-lg font-semibold text-slate-900">
          Request {exceptionTypeLabel(exceptionType)} exception
        </h2>
        <p className="mb-3 text-sm text-slate-600">
          {res?.explanation ??
            (exceptionType === "EXTEND_TRIAL"
              ? `Extends the trial while it's active — currently night ${
                  evaluation.display?.night ?? "—"
                } of ${(evaluation.display?.length_nights ?? 0) +
                  (evaluation.display?.extension_nights ?? 0)}.`
              : "")}{" "}
          {canSelfAuth
            ? "You can self-authorize — this is approved immediately and audited."
            : "An approver must approve this. Approval grants authority to proceed but does not start anything."}
        </p>

        {exceptionType === "EXTEND_TRIAL" && (
          <label className="mb-3 block text-xs text-slate-600">
            Nights to extend
            <input
              type="number"
              min={1}
              value={nights}
              onChange={(e) => setNights(e.target.value)}
              className="mt-0.5 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm"
            />
          </label>
        )}
        {exceptionType === "FEE_WAIVER" && (
          <label className="mb-3 block text-xs text-slate-600">
            Requested fee % (0 = full waiver)
            <input
              type="number"
              min={0}
              max={100}
              step="0.01"
              value={feePct}
              onChange={(e) => setFeePct(e.target.value)}
              className="mt-0.5 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm"
            />
          </label>
        )}

        <label className="block text-xs text-slate-600">
          Reason
          <select
            value={reasonId}
            onChange={(e) => setReasonId(e.target.value)}
            className="mt-0.5 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm"
          >
            {reasons.length === 0 && <option value="">Loading…</option>}
            {reasons.map((r) => (
              <option key={r.id} value={r.id}>
                {r.label}
              </option>
            ))}
          </select>
        </label>

        <textarea
          value={reasonNote}
          onChange={(e) => setReasonNote(e.target.value)}
          placeholder={
            noteRequired
              ? "Note (required)"
              : "Note (optional)"
          }
          rows={3}
          className="mt-3 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
        />
        {error && (
          <p className="mt-2 rounded-md border border-red-200 bg-red-50 p-2 text-sm text-red-700">
            {error}
          </p>
        )}
        <div className="mt-4 flex gap-2">
          <button
            onClick={save}
            disabled={!reasonId || saving}
            className="flex-1 rounded-md bg-amber-600 px-3 py-2 text-sm font-medium text-white hover:bg-amber-700 disabled:opacity-50"
          >
            {saving ? "Submitting…" : "Request approval"}
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

// ============================================================
// Exception decision (075 / spec 15.6-15.8) — approver picks
// Approve as requested / Approve with changes (whitelisted fields
// per type) / Deny (reason required). The server enforces the same
// whitelist and rejects self-decisions.
// ============================================================

type DecisionMode = "APPROVED_AS_REQUESTED" | "APPROVED_MODIFIED" | "DENIED";

function ExceptionDecisionModal({
  exception,
  onClose,
  onSaved,
}: {
  exception: TrialItemException;
  onClose: () => void;
  onSaved: () => void;
}) {
  const editable = EXCEPTION_EDITABLE_TERMS[exception.exception_type] ?? [];
  const hasEditable = editable.length > 0;
  const [mode, setMode] = useState<DecisionMode>("APPROVED_AS_REQUESTED");
  const [terms, setTerms] = useState<Record<string, string | boolean>>({});
  const [denialReason, setDenialReason] = useState("");
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<string | null>(null);

  function buildApprovedTerms(): Record<string, unknown> {
    const out: Record<string, unknown> = {};
    if (editable.includes("fee_percent_bp") && terms.fee_percent_bp !== "" && terms.fee_percent_bp != null)
      out.fee_percent_bp = Math.round(Number(terms.fee_percent_bp) * 100);
    if (editable.includes("fee_flat_cents") && terms.fee_flat_cents !== "" && terms.fee_flat_cents != null)
      out.fee_flat_cents = Math.round(Number(terms.fee_flat_cents) * 100);
    if (editable.includes("fee_amount_cents") && terms.fee_amount_cents !== "" && terms.fee_amount_cents != null)
      out.fee_amount_cents = Math.round(Number(terms.fee_amount_cents) * 100);
    if (editable.includes("extension_nights") && terms.extension_nights !== "" && terms.extension_nights != null)
      out.extension_nights = Math.round(Number(terms.extension_nights));
    if (editable.includes("refund_method") && terms.refund_method)
      out.refund_method = terms.refund_method;
    if (editable.includes("exchange_only") && terms.exchange_only)
      out.exchange_only = true;
    if (editable.includes("deadline_date") && terms.deadline_date)
      out.deadline_date = terms.deadline_date;
    return out;
  }

  async function submit() {
    setSaving(true);
    setError(null);
    try {
      const approvedTerms =
        mode === "APPROVED_MODIFIED" ? buildApprovedTerms() : null;
      if (mode === "APPROVED_MODIFIED" && Object.keys(approvedTerms ?? {}).length === 0) {
        setError("Enter at least one changed term, or choose Approve as requested");
        return;
      }
      if (mode === "DENIED" && !denialReason.trim()) {
        setError("A reason is required to deny");
        return;
      }
      const r = await decideTrialItemException({
        exceptionId: exception.id,
        decision: mode,
        approvedTerms,
        denialReason: mode === "DENIED" ? denialReason.trim() : null,
        note: note.trim() || null,
      });
      if (r.status === "CONSUMED") {
        setResult("Approved and applied — the trial was extended.");
      } else if (r.status === "APPROVED") {
        setResult(
          `Approved by ${r.approver_name ?? "you"}${
            r.valid_until
              ? ` · valid until ${new Date(r.valid_until).toLocaleDateString()}`
              : ""
          }.`
        );
      } else {
        setResult("Denied.");
      }
      // Let the approver read the outcome, then refresh the workspace.
      setTimeout(onSaved, 900);
    } catch (e: any) {
      setError(e.message ?? "Failed to save the decision");
    } finally {
      setSaving(false);
    }
  }

  const requestedSummary =
    exception.exception_type === "EXTEND_TRIAL"
      ? `${(exception.requested_terms as any)?.extension_nights ?? "?"} nights`
      : exception.reason?.label ?? null;

  return (
    <Modal onClose={onClose} dirty saving={saving}>
      <div className="w-full max-w-sm rounded-lg border border-slate-200 bg-white p-6 shadow-lg">
        <h2 className="mb-2 text-lg font-semibold text-slate-900">
          Decide: {exceptionTypeLabel(exception.exception_type)}
        </h2>
        <p className="mb-1 text-sm text-slate-600">
          Requested by {exception.requester?.name ?? "Unknown"} on{" "}
          {new Date(exception.requested_at).toLocaleDateString()}
          {exception.reason?.label ? ` · ${exception.reason.label}` : ""}
          {requestedSummary ? ` · ${requestedSummary}` : ""}
        </p>
        {exception.reason_note && (
          <p className="mb-3 text-sm text-slate-500">
            {exception.reason_note}
          </p>
        )}

        <div className="space-y-1.5 text-sm">
          <label className="flex items-center gap-2">
            <input
              type="radio"
              checked={mode === "APPROVED_AS_REQUESTED"}
              onChange={() => setMode("APPROVED_AS_REQUESTED")}
            />
            Approve as requested
          </label>
          {hasEditable && (
            <label className="flex items-center gap-2">
              <input
                type="radio"
                checked={mode === "APPROVED_MODIFIED"}
                onChange={() => setMode("APPROVED_MODIFIED")}
              />
              Approve with changes
            </label>
          )}
          <label className="flex items-center gap-2">
            <input
              type="radio"
              checked={mode === "DENIED"}
              onChange={() => setMode("DENIED")}
            />
            Deny
          </label>
        </div>

        {mode === "APPROVED_MODIFIED" && (
          <div className="mt-3 space-y-2">
            {editable.includes("extension_nights") && (
              <label className="block text-xs text-slate-600">
                Extension nights
                <input
                  type="number"
                  min={1}
                  value={(terms.extension_nights as string) ?? ""}
                  onChange={(e) =>
                    setTerms({ ...terms, extension_nights: e.target.value })
                  }
                  className="mt-0.5 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm"
                />
              </label>
            )}
            {editable.includes("fee_percent_bp") && (
              <label className="block text-xs text-slate-600">
                Fee % (e.g. 10 = 10%)
                <input
                  type="number"
                  min={0}
                  step="0.01"
                  value={(terms.fee_percent_bp as string) ?? ""}
                  onChange={(e) =>
                    setTerms({ ...terms, fee_percent_bp: e.target.value })
                  }
                  className="mt-0.5 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm"
                />
              </label>
            )}
            {editable.includes("fee_flat_cents") && (
              <label className="block text-xs text-slate-600">
                Flat fee ($)
                <input
                  type="number"
                  min={0}
                  step="0.01"
                  value={(terms.fee_flat_cents as string) ?? ""}
                  onChange={(e) =>
                    setTerms({ ...terms, fee_flat_cents: e.target.value })
                  }
                  className="mt-0.5 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm"
                />
              </label>
            )}
            {editable.includes("fee_amount_cents") && (
              <label className="block text-xs text-slate-600">
                Exact fee ($)
                <input
                  type="number"
                  min={0}
                  step="0.01"
                  value={(terms.fee_amount_cents as string) ?? ""}
                  onChange={(e) =>
                    setTerms({ ...terms, fee_amount_cents: e.target.value })
                  }
                  className="mt-0.5 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm"
                />
              </label>
            )}
            {editable.includes("refund_method") && (
              <label className="block text-xs text-slate-600">
                Refund method
                <select
                  value={(terms.refund_method as string) ?? ""}
                  onChange={(e) =>
                    setTerms({ ...terms, refund_method: e.target.value })
                  }
                  className="mt-0.5 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm"
                >
                  <option value="">— unchanged —</option>
                  <option value="ORIGINAL_TENDER">Original tender</option>
                  <option value="STORE_CREDIT">Store credit</option>
                  <option value="OTHER">Other</option>
                </select>
              </label>
            )}
            {editable.includes("exchange_only") && (
              <label className="flex items-center gap-2 text-xs text-slate-600">
                <input
                  type="checkbox"
                  checked={!!terms.exchange_only}
                  onChange={(e) =>
                    setTerms({ ...terms, exchange_only: e.target.checked })
                  }
                />
                Convert to exchange only (return denied)
              </label>
            )}
            {editable.includes("deadline_date") && (
              <label className="block text-xs text-slate-600">
                Must complete by
                <input
                  type="date"
                  value={(terms.deadline_date as string) ?? ""}
                  onChange={(e) =>
                    setTerms({ ...terms, deadline_date: e.target.value })
                  }
                  className="mt-0.5 w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm"
                />
              </label>
            )}
          </div>
        )}

        {mode === "DENIED" && (
          <textarea
            value={denialReason}
            onChange={(e) => setDenialReason(e.target.value)}
            placeholder="Reason for denying (required)"
            rows={2}
            className="mt-3 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
          />
        )}

        <textarea
          value={note}
          onChange={(e) => setNote(e.target.value)}
          placeholder="Approver note (optional)"
          rows={2}
          className="mt-3 w-full rounded-md border border-slate-300 px-3 py-2 text-sm"
        />

        {error && (
          <p className="mt-2 rounded-md border border-red-200 bg-red-50 p-2 text-sm text-red-700">
            {error}
          </p>
        )}
        {result && (
          <p className="mt-2 rounded-md border border-green-200 bg-green-50 p-2 text-sm text-green-700">
            {result}
          </p>
        )}

        <div className="mt-4 flex gap-2">
          <button
            onClick={submit}
            disabled={saving || !!result}
            className={`flex-1 rounded-md px-3 py-2 text-sm font-medium text-white disabled:opacity-50 ${
              mode === "DENIED"
                ? "bg-red-600 hover:bg-red-700"
                : "bg-teal-700 hover:bg-teal-800"
            }`}
          >
            {saving
              ? "Saving…"
              : mode === "DENIED"
              ? "Deny request"
              : "Approve"}
          </button>
          <button
            onClick={onClose}
            className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700"
          >
            {result ? "Close" : "Cancel"}
          </button>
        </div>
      </div>
    </Modal>
  );
}
