import { createClient } from "@/lib/supabase/client";
import {
  explainSleepTrialReason,
  sleepTrialReasonLabel,
} from "@/lib/sleepTrial/reasons";

// ============================================================
// Sleep Trial evaluator — thin formatter over the Postgres
// evaluator's JSON (migration 070, spec Sections 10-13). No trial
// math lives here: statuses, dates, fees, and blockers are
// computed server-side; this file only types, fetches, orders,
// and formats them.
// ============================================================

export type TrialActionStatus =
  | "PENDING"
  | "NOT_YET_ELIGIBLE"
  | "ELIGIBLE"
  | "APPROVAL_REQUIRED"
  | "BLOCKED"
  | "NOT_ELIGIBLE"
  | "EXPIRED"
  | "UNKNOWN";

export interface TrialFeeResult {
  window: {
    from_night: number;
    to_night: number | null;
    label: string;
    outcome: string;
  } | null;
  percent_bp: number;
  flat_cents: number;
  basis_cents: number;
  basis_label: string;
  amount_cents: number;
  min_cents: number | null;
  max_cents: number | null;
  schedule_key?: string;
  next_change: {
    on: string;
    to_percent_bp: number;
    to_flat_cents?: number;
  } | null;
}

export interface TrialActionResult {
  status: TrialActionStatus;
  reason_code: string;
  explanation: string;
  fee: TrialFeeResult | null;
  requires_approval: boolean;
  exception_available: boolean;
  exception_type: string | null;
  additional_blockers: {
    status: TrialActionStatus;
    reason_code: string;
    explanation: string;
  }[];
  warnings: string[];
  applied_exception_id: string | null;
}

export interface SleepTrialEvaluation {
  trial_item_id: string;
  journey_id: string;
  as_of: string | null;
  display: {
    night: number | null;
    length_nights: number | null;
    extension_nights: number | null;
    started_on: string | null;
    eligible_on: string | null;
    end_date: string | null;
    minimum_nights: number | null;
    minimum_met: boolean;
    ending_soon: boolean;
    nights_remaining: number | null;
    days_until_eligible: number | null;
    exchanges_used: number | null;
    exchanges_allowed: number | null;
  };
  item: {
    status: string;
    product_name: string | null;
    brand: string | null;
    size: string | null;
    unit_index: number | null;
    bound_reason: string | null;
    fee_basis_cents: number | null;
    has_open_concern: boolean;
    pending_exception_id: string | null;
  } | null;
  actions: {
    EXCHANGE: TrialActionResult;
    RETURN: TrialActionResult;
  };
  headline: {
    status: TrialActionStatus;
    reason_code: string;
    explanation: string;
  };
  allowed_ui_actions: string[];
  policy: {
    policy_version_id?: string;
    version_label?: string;
    // term path -> 'COMPANY' or { override_id, scope, label } (spec 6.2)
    term_sources?: Record<string, string | { label?: string; scope?: string }>;
    // Bound terms verbatim (072) — the "Why?" panel renders values from this.
    resolved_terms?: Record<string, unknown>;
  };
  evaluated_at: string;
}

// ============================================================
// Fetchers — the only entry points for evaluation results.
// ============================================================

/** Evaluate every trial item on the given journeys (board batch path). */
export async function evaluateSleepTrialItems(
  journeyIds: string[]
): Promise<Map<string, SleepTrialEvaluation[]>> {
  const map = new Map<string, SleepTrialEvaluation[]>();
  if (journeyIds.length === 0) return map;
  const supabase = createClient();
  const { data, error } = await supabase.rpc("evaluate_sleep_trial_items", {
    p_journey_ids: journeyIds,
    p_as_of: null,
  });
  if (error) {
    // A missing/failed evaluation must degrade silently on the board —
    // cards simply render no trial chip (spec failure contract).
    console.error("evaluate_sleep_trial_items error", error);
    return map;
  }
  for (const row of (data as unknown as SleepTrialEvaluation[]) ?? []) {
    const list = map.get(row.journey_id) ?? [];
    list.push(row);
    map.set(row.journey_id, list);
  }
  return map;
}

/** Evaluate one trial item (journey detail path). */
export async function evaluateSleepTrialItem(
  itemId: string
): Promise<SleepTrialEvaluation | null> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("evaluate_sleep_trial_item", {
    p_trial_item_id: itemId,
    p_as_of: null,
  });
  if (error) {
    console.error("evaluate_sleep_trial_item error", error);
    return null;
  }
  return (data as unknown as SleepTrialEvaluation) ?? null;
}

// ============================================================
// Formatting + ordering — display only, no eligibility logic.
// ============================================================

// Spec 19.1 "most urgent" order: Blocked w/ open concern > approval pending
// or required > ending soon > eligible w/ open concern > not yet eligible >
// eligible > pending > closed/expired/not-eligible > unknown.
export function trialUrgencyRank(e: SleepTrialEvaluation): number {
  const status = e.headline?.status ?? e.actions?.EXCHANGE?.status ?? "UNKNOWN";
  const openConcern = e.item?.has_open_concern ?? false;
  switch (status) {
    case "BLOCKED":
      return openConcern ? 1 : 3;
    case "APPROVAL_REQUIRED":
      return 2;
    case "ELIGIBLE":
      if (e.display?.ending_soon) return 4;
      return openConcern ? 5 : 7;
    case "NOT_YET_ELIGIBLE":
      return 6;
    case "PENDING":
      return 8;
    case "EXPIRED":
      return 9;
    default:
      return 10; // NOT_ELIGIBLE / CLOSED-adjacent / UNKNOWN — least urgent
  }
}

export function mostUrgentEvaluation(
  evals: SleepTrialEvaluation[] | null | undefined
): SleepTrialEvaluation | null {
  if (!evals || evals.length === 0) return null;
  return [...evals].sort(
    (a, b) =>
      trialUrgencyRank(a) - trialUrgencyRank(b) ||
      (a.item?.unit_index ?? 0) - (b.item?.unit_index ?? 0)
  )[0];
}

/** All evals ordered most-urgent-first (spec 19.1 hero ordering). */
export function sortEvaluationsByUrgency(
  evals: SleepTrialEvaluation[] | null | undefined
): SleepTrialEvaluation[] {
  return [...(evals ?? [])].sort(
    (a, b) =>
      trialUrgencyRank(a) - trialUrgencyRank(b) ||
      (a.item?.unit_index ?? 0) - (b.item?.unit_index ?? 0)
  );
}

/**
 * Which action result produced the headline. The evaluator picks EXCHANGE
 * unless the policy doesn't offer exchanges — detectable via an
 * EXCHANGES_NOT_OFFERED blocker anywhere in the EXCHANGE result (not just
 * the headline: a missing protector now outranks it).
 */
export function headlineAction(e: SleepTrialEvaluation): "EXCHANGE" | "RETURN" {
  const x = e.actions?.EXCHANGE;
  if (!x) return "RETURN";
  const codes = [
    x.reason_code,
    ...(x.additional_blockers ?? []).map((b) => b.reason_code),
  ];
  return codes.includes("EXCHANGES_NOT_OFFERED") ? "RETURN" : "EXCHANGE";
}

/** Parse a YYYY-MM-DD business date without timezone drift. */
export function trialDate(iso: string | null | undefined): Date | null {
  if (!iso) return null;
  const d = new Date(`${iso}T00:00:00`);
  return Number.isNaN(d.getTime()) ? null : d;
}

export function formatTrialDate(iso: string | null | undefined): string {
  return trialDate(iso)?.toLocaleDateString() ?? "";
}

export function formatMoney(cents: number | null | undefined): string {
  if (cents == null) return "";
  return `$${(cents / 100).toFixed(2)}`;
}

/**
 * One-line status label for a headline/action result. The "not yet eligible"
 * label deliberately names the eligible date (spec 11.2 — the old "at
 * Night 30" wording implied Night 30 itself was eligible, which is wrong).
 */
export function trialStatusLabel(e: SleepTrialEvaluation): string {
  const h = e.headline;
  const d = e.display;
  const fallbackReason = e.actions?.EXCHANGE?.reason_code;
  const code = h?.reason_code ?? fallbackReason;
  switch (h?.status) {
    case "PENDING":
      return code === "TRIAL_STARTS_TOMORROW"
        ? "Night 1 starts tomorrow"
        : "Trial starts at delivery";
    case "NOT_YET_ELIGIBLE":
      return `Exchange eligible ${formatTrialDate(d?.eligible_on)}${
        d?.minimum_nights != null ? ` (after Night ${d.minimum_nights})` : ""
      }`;
    case "ELIGIBLE":
      return "Eligible";
    case "APPROVAL_REQUIRED":
      return "Needs approval";
    case "BLOCKED":
      return `Blocked — ${sleepTrialReasonLabel(code)}`;
    case "EXPIRED":
      return `Trial ended ${formatTrialDate(d?.end_date)}`;
    case "NOT_ELIGIBLE":
      return sleepTrialReasonLabel(code);
    case "UNKNOWN":
    default:
      return "Can't determine eligibility";
  }
}

export function trialExplanation(e: SleepTrialEvaluation): string {
  return (
    e.headline?.explanation ??
    explainSleepTrialReason(e.actions?.EXCHANGE?.reason_code)
  );
}

// ============================================================
// Status tone — the single color rule shared by the hero's status
// dot and the board chip (spec 19.1 / 19.5): gray Pending/Not yet
// eligible, green Eligible, amber Approval required/Ending soon,
// red Blocked/Expired.
// ============================================================

export type TrialStatusTone = "slate" | "green" | "amber" | "red";

export function trialStatusTone(
  status: TrialActionStatus | null | undefined,
  endingSoon = false
): TrialStatusTone {
  switch (status) {
    case "ELIGIBLE":
      return endingSoon ? "amber" : "green";
    case "APPROVAL_REQUIRED":
      return "amber";
    case "BLOCKED":
    case "EXPIRED":
      return "red";
    default:
      return "slate"; // PENDING, NOT_YET_ELIGIBLE, NOT_ELIGIBLE, UNKNOWN
  }
}

export const TRIAL_STATUS_DOT: Record<TrialStatusTone, string> = {
  slate: "bg-slate-400",
  green: "bg-green-500",
  amber: "bg-amber-500",
  red: "bg-red-500",
};

export const TRIAL_STATUS_CHIP: Record<TrialStatusTone, string> = {
  slate: "border-slate-300 bg-slate-50 text-slate-700",
  green: "border-green-300 bg-green-50 text-green-800",
  amber: "border-amber-300 bg-amber-50 text-amber-800",
  red: "border-red-300 bg-red-50 text-red-800",
};

// ============================================================
// Protector override (072) — direct owner/admin action, not a
// request/approval workflow. One permanent override per item.
// ============================================================

export async function overrideSleepTrialProtector(
  trialItemId: string,
  reason: string
): Promise<string> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("override_sleep_trial_protector", {
    p_trial_item_id: trialItemId,
    p_reason: reason,
  });
  if (error) throw new Error(error.message);
  return data as string;
}

// ============================================================
// Exceptions v2 (073/074/075) — the sleep_trial_exceptions table,
// eligible approvers, and the decide RPC. The legacy
// sleep_trial_exception_requests helpers live in concerns.ts and
// stay until that table is dropped.
// ============================================================

export type TrialItemException = {
  id: string;
  journey_id: string;
  trial_item_id: string | null;
  exception_type: string;
  action: string;
  rule_reference: string | null;
  requested_terms: Record<string, unknown> | null;
  reason_code_id: string | null;
  reason_note: string | null;
  requester_employee_id: string;
  requested_at: string;
  status:
    | "PENDING"
    | "APPROVED"
    | "DENIED"
    | "CANCELLED"
    | "EXPIRED"
    | "STALE"
    | "CONSUMED";
  decision: string | null;
  approved_terms: Record<string, unknown> | null;
  approver_employee_id: string | null;
  decided_at: string | null;
  decision_note: string | null;
  self_authorized: boolean;
  valid_until: string | null;
  consumed_at: string | null;
  legacy_request_id: string | null;
  requester?: { id: string; name: string } | null;
  approver?: { id: string; name: string } | null;
  reason?: { id: string; label: string } | null;
};

export const EXCEPTION_TYPE_LABELS: Record<string, string> = {
  EARLY_EXCHANGE: "Early exchange",
  EXPIRED_EXCHANGE: "Expired-trial exchange",
  EXTRA_EXCHANGE: "Extra exchange",
  FEE_WAIVER: "Fee waiver",
  RETURN_NOT_ALLOWED: "Return exception",
  RETURN_APPROVAL: "Return approval",
  EXPIRED_RETURN: "Expired-trial return",
  PROTECTOR_OVERRIDE: "Protector override",
  EXTEND_TRIAL: "Trial extension",
  REPLACEMENT_TRIAL: "Replacement trial",
  INSPECTION_OVERRIDE: "Inspection override",
  NON_ELIGIBLE_ITEM: "Non-eligible item",
};

// Whitelist of approver-editable approved_terms keys per type — mirrors
// the server-side map in decide_trial_item_exception (075). When a type
// has no editable keys the UI hides "Approve with changes".
export const EXCEPTION_EDITABLE_TERMS: Record<string, string[]> = {
  EARLY_EXCHANGE: ["fee_percent_bp", "fee_flat_cents", "fee_amount_cents"],
  EXPIRED_EXCHANGE: [
    "fee_percent_bp",
    "fee_flat_cents",
    "fee_amount_cents",
    "deadline_date",
  ],
  EXTRA_EXCHANGE: ["fee_percent_bp", "fee_flat_cents", "fee_amount_cents"],
  FEE_WAIVER: ["fee_percent_bp", "fee_flat_cents", "fee_amount_cents"],
  RETURN_NOT_ALLOWED: [
    "fee_percent_bp",
    "fee_flat_cents",
    "fee_amount_cents",
    "refund_method",
    "exchange_only",
  ],
  RETURN_APPROVAL: [
    "fee_percent_bp",
    "fee_flat_cents",
    "fee_amount_cents",
    "refund_method",
  ],
  EXPIRED_RETURN: ["fee_percent_bp", "fee_flat_cents", "fee_amount_cents"],
  EXTEND_TRIAL: ["extension_nights"],
};

export function exceptionTypeLabel(type: string | null | undefined): string {
  if (!type) return "Exception";
  return EXCEPTION_TYPE_LABELS[type] ?? type.toLowerCase().replace(/_/g, " ");
}

export async function fetchTrialItemExceptions(
  journeyId: string
): Promise<TrialItemException[]> {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("sleep_trial_exceptions")
    .select(
      `id, journey_id, trial_item_id, exception_type, action, rule_reference,
       requested_terms, reason_code_id, reason_note,
       requester_employee_id, requested_at,
       status, decision, approved_terms, approver_employee_id, decided_at,
       decision_note, self_authorized, valid_until, consumed_at, legacy_request_id,
       requester:employees!requester_employee_id ( id, name ),
       approver:employees!approver_employee_id ( id, name ),
       reason:sleep_trial_exception_reasons!reason_code_id ( id, label )`
    )
    .eq("journey_id", journeyId)
    .order("requested_at", { ascending: false });

  if (error) {
    console.error("fetchTrialItemExceptions error", error);
    return [];
  }
  return (data as unknown as TrialItemException[]) ?? [];
}

export type ExceptionReason = {
  id: string;
  label: string;
  requires_note: boolean;
};

export async function fetchExceptionReasons(): Promise<ExceptionReason[]> {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("sleep_trial_exception_reasons")
    .select("id, label, requires_note")
    .eq("is_active", true)
    .order("sort_order");
  if (error) {
    console.error("fetchExceptionReasons error", error);
    return [];
  }
  return (data as unknown as ExceptionReason[]) ?? [];
}

/**
 * File an exception request (074). The caller passes the exception_type
 * the EVALUATOR offered for the current blocker — employees never pick a
 * type (spec 15.1). `action` is only sent for FEE_WAIVER (the type has no
 * fixed action); every other type derives its own.
 */
export async function requestTrialItemException(input: {
  trialItemId: string;
  exceptionType: string;
  action?: "EXCHANGE" | "RETURN" | null;
  reasonCodeId?: string | null;
  reasonNote?: string | null;
  requestedTerms?: Record<string, unknown>;
  customerCircumstances?: string | null;
  notes?: string | null;
  idempotencyKey?: string | null;
}): Promise<string> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("request_trial_item_exception", {
    p_trial_item_id: input.trialItemId,
    p_exception_type: input.exceptionType,
    p_action: input.action ?? null,
    p_reason_code_id: input.reasonCodeId ?? null,
    p_reason_note: input.reasonNote ?? null,
    p_requested_terms: input.requestedTerms ?? {},
    p_customer_circumstances: input.customerCircumstances ?? null,
    p_notes: input.notes ?? null,
    p_attachments: [],
    p_idempotency_key: input.idempotencyKey ?? null,
  });
  if (error) throw new Error(error.message);
  return data as string;
}

export type ExceptionApprover = {
  employee_id: string;
  employee_name: string;
};

/** Eligible approvers for a journey (075). Caller-side exclusion is done
 *  per context: request button excludes the caller, a pending request's
 *  "can be approved by" excludes its requester. */
export async function fetchExceptionApprovers(
  journeyId: string
): Promise<ExceptionApprover[]> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("stv_exception_approvers", {
    p_journey_id: journeyId,
    p_exclude_employee_id: null,
  });
  if (error) {
    console.error("stv_exception_approvers error", error);
    return [];
  }
  return (data as unknown as ExceptionApprover[]) ?? [];
}

export type DecideExceptionResult = {
  id: string;
  status: string;
  decision: string;
  approved_terms: Record<string, unknown> | null;
  valid_until: string | null;
  approver_name: string | null;
  consumed: boolean;
};

export async function decideTrialItemException(input: {
  exceptionId: string;
  decision: "APPROVED_AS_REQUESTED" | "APPROVED_MODIFIED" | "DENIED";
  approvedTerms?: Record<string, unknown> | null;
  denialReason?: string | null;
  note?: string | null;
}): Promise<DecideExceptionResult> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("decide_trial_item_exception", {
    p_exception_id: input.exceptionId,
    p_decision: input.decision,
    p_approved_terms: input.approvedTerms ?? null,
    p_denial_reason: input.denialReason ?? null,
    p_note: input.note ?? null,
  });
  if (error) throw new Error(error.message);
  return data as DecideExceptionResult;
}

/**
 * The caller's role's sleep-trial permission keys (role_permission_grants
 * is company-readable via RLS; 'owner' is hardcoded all-true server-side,
 * mirrored here so the UI's self-authorization check matches
 * has_permission).
 */
export async function fetchMySleepTrialPermissions(
  role: string | null | undefined
): Promise<Set<string>> {
  if (!role) return new Set();
  if (role === "owner") {
    return new Set([
      "sleep_trial.request_exceptions",
      "sleep_trial.approve_exceptions",
      "sleep_trial.approve_own_exceptions",
      "sleep_trial.override_protector",
    ]);
  }
  const supabase = createClient();
  const { data, error } = await supabase
    .from("role_permission_grants")
    .select("permission_key")
    .eq("role", role);
  if (error) {
    console.error("fetchMySleepTrialPermissions error", error);
    return new Set();
  }
  return new Set(
    ((data as { permission_key: string }[]) ?? []).map((r) => r.permission_key)
  );
}

// ============================================================
// Trial-start correction history (unchanged — journey-level RPC
// writes delivered_at, which item triggers then propagate).
// ============================================================

export type TrialStartCorrection = {
  id: string;
  journey_id: string;
  previous_started_at: string | null;
  new_started_at: string;
  reason: string;
  corrected_by_employee_id: string;
  created_at: string;
  corrected_by?: { id: string; name: string } | null;
};

export async function fetchTrialStartCorrections(
  journeyId: string
): Promise<TrialStartCorrection[]> {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("sleep_trial_start_corrections")
    .select(
      `id, journey_id, previous_started_at, new_started_at, reason,
       corrected_by_employee_id, created_at,
       corrected_by:employees!corrected_by_employee_id ( id, name )`
    )
    .eq("journey_id", journeyId)
    .order("created_at", { ascending: false });

  if (error) {
    console.error("fetchTrialStartCorrections error", error);
    return [];
  }
  return (data as unknown as TrialStartCorrection[]) ?? [];
}

export async function correctTrialStart(
  journeyId: string,
  newStartedAt: string,
  reason: string
) {
  const supabase = createClient();
  const { error } = await supabase.rpc("correct_trial_start", {
    p_journey_id: journeyId,
    p_new_started_at: newStartedAt,
    p_reason: reason,
  });
  if (error) throw new Error(error.message);
}
