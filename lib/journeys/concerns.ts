import { createClient } from "@/lib/supabase/client";

// ============================================================
// Sleep Concern domain types + RPC wrappers.
// Every concern entry also writes a journey_interactions row
// (source_domain='sleep_concern') — the concern's activity trail is
// the shared Journey Activity feed, not a parallel notes system.
// ============================================================

export type ConcernStatus =
  | "open"
  | "monitoring"
  | "resolved"
  | "escalated"
  | "exchange_requested";

export const CONCERN_STATUS_LABELS: Record<ConcernStatus, string> = {
  open: "Open",
  monitoring: "Monitoring",
  resolved: "Resolved",
  escalated: "Escalated",
  exchange_requested: "Exchange Requested",
};

export const OPEN_CONCERN_STATUSES: ConcernStatus[] = [
  "open",
  "monitoring",
  "escalated",
];

export type SleepConcernType = {
  id: string;
  company_id: string;
  name: string;
  sort_order: number;
  is_active: boolean;
};

export type SleepConcernQuestion = {
  id: string;
  company_id: string;
  concern_type_id: string | null;
  question_text: string;
  options: string[] | null;
  sort_order: number;
  is_active: boolean;
};

export type SleepConcern = {
  id: string;
  journey_id: string;
  trial_item_id: string | null;
  customer_id: string;
  status: ConcernStatus;
  opened_by_employee_id: string | null;
  opened_at: string;
  resolved_at: string | null;
  resolved_by_employee_id: string | null;
  resolution_type: string | null;
  resolution_summary: string | null;
  created_at: string;
  updated_at: string;
  opened_by?: { id: string; name: string } | null;
};

export type SleepConcernIssue = {
  id: string;
  sleep_concern_id: string;
  concern_type_id: string | null;
  issue_name: string;
  created_at: string;
};

export type SleepConcernEntry = {
  id: string;
  sleep_concern_id: string;
  journey_interaction_id: string | null;
  entry_type: "update" | "customer_report" | "recommendation" | "status_change";
  customer_report: string | null;
  employee_notes: string | null;
  recommendation_summary: string | null;
  created_by_employee_id: string | null;
  occurred_at: string;
  recorded_at: string;
  created_at: string;
  created_by?: { id: string; name: string } | null;
};

export type SleepConcernDiagnostic = {
  id: string;
  sleep_concern_id: string;
  entry_id: string | null;
  question_id: string | null;
  question_snapshot: {
    text?: string;
    options?: string[];
    concern_type_name?: string;
  };
  response: string;
  created_at: string;
};

export type SleepTrialExceptionRequest = {
  id: string;
  journey_id: string;
  sleep_concern_id: string | null;
  requester_employee_id: string;
  approver_employee_id: string | null;
  reason: string;
  requested_action: string;
  current_trial_night: number | null;
  normal_eligibility_date: string | null;
  status: "pending" | "approved" | "denied" | "expired" | "cancelled";
  requested_at: string;
  decided_at: string | null;
  expires_at: string | null;
  requester?: { id: string; name: string } | null;
  approver?: { id: string; name: string } | null;
};

export type FollowUpInput = {
  due_at: string;
  method?: string | null;
  notes?: string | null;
  employee_id?: string | null;
  idempotency_key: string;
};

// ============================================================
// Config: concern types + diagnostic questions (seeded on first use)
// ============================================================

export async function fetchSleepConcernConfig(): Promise<{
  types: SleepConcernType[];
  questions: SleepConcernQuestion[];
}> {
  const supabase = createClient();
  await supabase.rpc("ensure_sleep_concern_defaults");

  const [{ data: types, error: tErr }, { data: questions, error: qErr }] =
    await Promise.all([
      supabase
        .from("sleep_concern_types")
        .select("id, company_id, name, sort_order, is_active")
        .eq("is_active", true)
        .order("sort_order"),
      supabase
        .from("sleep_concern_questions")
        .select("id, company_id, concern_type_id, question_text, options, sort_order, is_active")
        .eq("is_active", true)
        .order("sort_order"),
    ]);

  if (tErr) console.error("fetchSleepConcernConfig types error", tErr);
  if (qErr) console.error("fetchSleepConcernConfig questions error", qErr);

  return {
    types: (types as unknown as SleepConcernType[]) ?? [],
    questions: (questions as unknown as SleepConcernQuestion[]) ?? [],
  };
}

// ============================================================
// Concern fetchers
// ============================================================

export async function fetchSleepConcerns(
  journeyId: string
): Promise<SleepConcern[]> {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("sleep_concerns")
    .select(
      `id, journey_id, trial_item_id, customer_id, status, opened_by_employee_id, opened_at,
       resolved_at, resolved_by_employee_id, resolution_type, resolution_summary,
       created_at, updated_at,
       opened_by:employees!opened_by_employee_id ( id, name )`
    )
    .eq("journey_id", journeyId)
    .order("opened_at", { ascending: false });

  if (error) {
    console.error("fetchSleepConcerns error", error);
    return [];
  }
  return (data as unknown as SleepConcern[]) ?? [];
}

export async function fetchSleepConcernIssues(
  concernIds: string[]
): Promise<SleepConcernIssue[]> {
  if (concernIds.length === 0) return [];
  const supabase = createClient();
  const { data, error } = await supabase
    .from("sleep_concern_issues")
    .select("id, sleep_concern_id, concern_type_id, issue_name, created_at")
    .in("sleep_concern_id", concernIds)
    .order("created_at", { ascending: true });

  if (error) {
    console.error("fetchSleepConcernIssues error", error);
    return [];
  }
  return (data as unknown as SleepConcernIssue[]) ?? [];
}

export async function fetchSleepConcernEntries(
  concernId: string
): Promise<SleepConcernEntry[]> {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("sleep_concern_entries")
    .select(
      `id, sleep_concern_id, journey_interaction_id, entry_type,
       customer_report, employee_notes, recommendation_summary,
       created_by_employee_id, occurred_at, recorded_at, created_at,
       created_by:employees!created_by_employee_id ( id, name )`
    )
    .eq("sleep_concern_id", concernId)
    .order("occurred_at", { ascending: false });

  if (error) {
    console.error("fetchSleepConcernEntries error", error);
    return [];
  }
  return (data as unknown as SleepConcernEntry[]) ?? [];
}

export async function fetchSleepConcernDiagnostics(
  concernId: string
): Promise<SleepConcernDiagnostic[]> {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("sleep_concern_diagnostic_responses")
    .select("id, sleep_concern_id, entry_id, question_id, question_snapshot, response, created_at")
    .eq("sleep_concern_id", concernId)
    .order("created_at", { ascending: true });

  if (error) {
    console.error("fetchSleepConcernDiagnostics error", error);
    return [];
  }
  return (data as unknown as SleepConcernDiagnostic[]) ?? [];
}

// ============================================================
// Concern mutations (RPCs — idempotent, transactional)
// ============================================================

export type IssueInput = { concern_type_id: string | null; name: string };

export type DiagnosticInput = {
  question_id: string | null;
  question_snapshot: { text: string; options?: string[] | null; concern_type_name?: string };
  response: string;
};

export async function openSleepConcern(input: {
  journey_id: string;
  issues: IssueInput[];
  idempotency_key: string;
  customer_report?: string | null;
  employee_notes?: string | null;
  recommendation?: string | null;
  diagnostics?: DiagnosticInput[];
  follow_up?: FollowUpInput | null;
  contact_id?: string | null;
  channel?: string | null;
  allow_duplicate?: boolean;
}): Promise<string> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("open_sleep_concern", {
    p_journey_id: input.journey_id,
    p_issues: input.issues,
    p_idempotency_key: input.idempotency_key,
    p_customer_report: input.customer_report ?? null,
    p_employee_notes: input.employee_notes ?? null,
    p_recommendation: input.recommendation ?? null,
    p_diagnostics: input.diagnostics ?? null,
    p_follow_up: input.follow_up ?? null,
    p_contact_id: input.contact_id ?? null,
    p_channel: input.channel ?? null,
    p_occurred_at: null,
    p_allow_duplicate: input.allow_duplicate ?? false,
  });
  if (error) throw new Error(error.message);
  return data as string;
}

export async function addSleepConcernEntry(input: {
  concern_id: string;
  idempotency_key: string;
  customer_report?: string | null;
  employee_notes?: string | null;
  recommendation?: string | null;
  diagnostics?: DiagnosticInput[];
  new_issues?: IssueInput[];
  new_status?: "open" | "monitoring" | "resolved" | "escalated" | null;
  resolution_type?: string | null;
  resolution_summary?: string | null;
  follow_up?: FollowUpInput | null;
  contact_id?: string | null;
  channel?: string | null;
}): Promise<string> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("add_sleep_concern_entry", {
    p_concern_id: input.concern_id,
    p_idempotency_key: input.idempotency_key,
    p_customer_report: input.customer_report ?? null,
    p_employee_notes: input.employee_notes ?? null,
    p_recommendation: input.recommendation ?? null,
    p_diagnostics: input.diagnostics ?? null,
    p_new_issues: input.new_issues ?? null,
    p_new_status: input.new_status ?? null,
    p_resolution_type: input.resolution_type ?? null,
    p_resolution_summary: input.resolution_summary ?? null,
    p_follow_up: input.follow_up ?? null,
    p_contact_id: input.contact_id ?? null,
    p_channel: input.channel ?? null,
    p_occurred_at: null,
  });
  if (error) throw new Error(error.message);
  return data as string;
}

export async function requestConcernExchange(concernId: string) {
  const supabase = createClient();
  const { error } = await supabase.rpc("request_concern_exchange", {
    p_concern_id: concernId,
  });
  if (error) throw new Error(error.message);
}

// ============================================================
// Early exchange exception requests
// ============================================================

export async function fetchSleepTrialExceptions(
  journeyId: string
): Promise<SleepTrialExceptionRequest[]> {
  const supabase = createClient();
  const { data, error } = await supabase
    .from("sleep_trial_exception_requests")
    .select(
      `id, journey_id, sleep_concern_id, requester_employee_id,
       approver_employee_id, reason, requested_action, current_trial_night,
       normal_eligibility_date, status, requested_at, decided_at, expires_at,
       requester:employees!requester_employee_id ( id, name ),
       approver:employees!approver_employee_id ( id, name )`
    )
    .eq("journey_id", journeyId)
    .order("requested_at", { ascending: false });

  if (error) {
    console.error("fetchSleepTrialExceptions error", error);
    return [];
  }
  return (data as unknown as SleepTrialExceptionRequest[]) ?? [];
}

export async function requestSleepTrialException(input: {
  journey_id: string;
  sleep_concern_id?: string | null;
  reason: string;
}): Promise<string> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("request_sleep_trial_exception", {
    p_journey_id: input.journey_id,
    p_sleep_concern_id: input.sleep_concern_id ?? null,
    p_reason: input.reason,
  });
  if (error) throw new Error(error.message);
  return data as string;
}

export async function decideSleepTrialException(
  requestId: string,
  decision: "approved" | "denied"
): Promise<"approved" | "denied" | "expired"> {
  const supabase = createClient();
  const { data, error } = await supabase.rpc("decide_sleep_trial_exception", {
    p_request_id: requestId,
    p_decision: decision,
  });
  if (error) throw new Error(error.message);
  // 'expired' means the request's window had already passed; the RPC
  // persisted status='expired' rather than applying the decision.
  return (data as "approved" | "denied" | "expired") ?? decision;
}
