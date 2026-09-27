import { createClient } from "@/lib/supabase/client";
import type {
  SleepTrialDefinition,
  ValidationResult,
} from "@/lib/sleepTrial/definition";

// Data layer for the versioned Sleep Trial policy (migration 067,
// spec Sections 5.2, 7.1, 26.2). All writes go through the RPCs; the tables
// are select-only for authenticated users.

export interface PolicyVersionRow {
  id: string;
  version_number: number;
  status: "DRAFT" | "PUBLISHED" | "RETIRED";
  definition: SleepTrialDefinition;
  summary_text: string | null;
  effective_from: string | null;
  effective_until: string | null;
  published_at: string | null;
  published_by: string | null;
  publish_note: string | null;
  created_at: string;
}

export interface SleepTrialPolicyState {
  // Null until migration 067 is applied.
  policyId: string | null;
  published: PolicyVersionRow | null;
  draft: PolicyVersionRow | null;
  publisherName: string | null;
}

// Returns null when the policies tables don't exist yet (067 not applied),
// so the page can show an install notice instead of breaking.
export async function fetchSleepTrialPolicy(): Promise<SleepTrialPolicyState | null> {
  const supabase = createClient();

  const { data: policy, error: policyError } = await (supabase as any)
    .from("policies")
    .select("id, current_version_id")
    .eq("policy_type", "SLEEP_TRIAL")
    .maybeSingle();

  if (policyError) {
    console.error("fetchSleepTrialPolicy error", policyError);
    return null;
  }
  if (!policy) {
    return { policyId: null, published: null, draft: null, publisherName: null };
  }

  const { data: versions, error: versionsError } = await (supabase as any)
    .from("policy_versions")
    .select(
      "id, version_number, status, definition, summary_text, effective_from, effective_until, published_at, published_by, publish_note, created_at"
    )
    .eq("policy_id", policy.id)
    .order("version_number", { ascending: false });

  if (versionsError) {
    console.error("fetchSleepTrialPolicy versions error", versionsError);
    return null;
  }

  const rows = (versions ?? []) as PolicyVersionRow[];
  const published = rows.find((v) => v.status === "PUBLISHED") ?? null;
  const draft = rows.find((v) => v.status === "DRAFT") ?? null;

  let publisherName: string | null = null;
  if (published?.published_by) {
    const { data: emp } = await (supabase as any)
      .from("employees")
      .select("name")
      .eq("id", published.published_by)
      .maybeSingle();
    publisherName = emp?.name ?? null;
  }

  return { policyId: policy.id, published, draft, publisherName };
}

// True/false from the permission registry; null when the RPC is missing
// (migration 066 not applied) so callers can fall back to a role check.
export async function fetchManagePolicyPermission(): Promise<boolean | null> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc("has_permission", {
    p_key: "sleep_trial.manage_policy",
  });
  if (error) {
    console.error("has_permission error", error);
    return null;
  }
  return data === true;
}

export async function saveSleepTrialDraft(
  definition: SleepTrialDefinition
): Promise<ValidationResult> {
  const supabase = createClient();
  const { data, error } = await (supabase as any).rpc("save_sleep_trial_draft", {
    p_definition: definition,
  });
  if (error) throw new Error(error.message);
  return (data ?? { errors: [], warnings: [] }) as ValidationResult;
}

export async function discardSleepTrialDraft(): Promise<void> {
  const supabase = createClient();
  const { error } = await (supabase as any).rpc("discard_sleep_trial_draft");
  if (error) throw new Error(error.message);
}

export async function publishSleepTrialDraft(
  summaryText: string,
  note: string
): Promise<void> {
  const supabase = createClient();
  const { error } = await (supabase as any).rpc("publish_sleep_trial_draft", {
    p_summary_text: summaryText,
    p_note: note || null,
  });
  if (error) throw new Error(error.message);
}
