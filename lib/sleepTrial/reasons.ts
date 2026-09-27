// Sleep Trial reason codes — one entry per code from spec Section 10.6
// (plus the internal-only codes the evaluator uses for missing facts).
// The server returns code + parameters + a default English explanation;
// these templates let the UI reformat, never recompute, the reason.
// Placeholders are filled from the evaluator's params with {field} syntax.

export type SleepTrialReasonParams = Record<
  string,
  string | number | null | undefined
>;

export interface SleepTrialReason {
  /** Short label for chips/checklists. */
  label: string;
  /** English explanation template; {field} placeholders from params. */
  template: string;
}

export const SLEEP_TRIAL_REASONS: Record<string, SleepTrialReason> = {
  TRIAL_NOT_STARTED: {
    label: "Trial not started",
    template: "The trial has not started — record the delivery or pickup first.",
  },
  TRIAL_STARTS_TOMORROW: {
    label: "Starts tomorrow",
    template: "Delivered today — Night 1 is {started_on}.",
  },
  TRIAL_CLOSED_EXCHANGED: {
    label: "Exchanged",
    template: "This trial ended — the mattress was exchanged.",
  },
  TRIAL_CLOSED_RETURNED: {
    label: "Returned",
    template: "This trial ended — the mattress was returned.",
  },
  TRIAL_CLOSED_COMPLETED: {
    label: "Completed",
    template: "This trial completed its full length and closed.",
  },
  TRIAL_CLOSED_WARRANTY: {
    label: "Warranty",
    template: "This trial ended — the mattress was replaced under warranty.",
  },
  ACTION_IN_PROGRESS: {
    label: "In progress",
    template: "An exchange or return is already in progress for this mattress.",
  },
  EXCHANGES_NOT_OFFERED: {
    label: "No exchanges",
    template: "Exchanges are not part of this customer's sleep trial policy.",
  },
  RETURNS_NOT_OFFERED: {
    label: "No returns",
    template: "Returns are not part of this customer's sleep trial policy.",
  },
  EXCHANGE_LIMIT_REACHED: {
    label: "Exchange limit reached",
    template:
      "The exchange limit was reached ({exchanges_used} of {exchanges_allowed} used).",
  },
  TRIAL_EXPIRED: {
    label: "Trial ended",
    template: "The sleep trial ended {end_date}.",
  },
  MINIMUM_NIGHTS_NOT_MET: {
    label: "Not yet eligible",
    template:
      "{action_label} eligible {eligible_on} (after Night {minimum_nights}) · {days_until} days.",
  },
  FEE_WINDOW_PROHIBITED: {
    label: "Not allowed in this window",
    template:
      "{action_label} is not allowed on Night {night} ({window_label}).",
  },
  FEE_WINDOW_NEEDS_APPROVAL: {
    label: "Needs approval",
    template: "{action_label} in this fee window requires approval.",
  },
  SLEEP_CONCERN_REQUIRED: {
    label: "Sleep concern required",
    template:
      "A documented sleep concern is required before an exchange — log a sleep concern first.",
  },
  PROTECTOR_MISSING: {
    label: "No protector",
    template: "No qualifying mattress protector on this order.",
  },
  PROTECTOR_RETURNED: {
    label: "Protector returned",
    template: "The qualifying mattress protector was returned or refunded.",
  },
  RETURN_NEEDS_APPROVAL: {
    label: "Needs approval",
    template: "Returns under this policy require approval.",
  },
  WITHIN_POLICY: {
    label: "Within policy",
    template: "Within policy.",
  },
  EXCEPTION_APPLIED: {
    label: "Exception applied",
    template: "An approved exception applies to this action.",
  },
  NO_TRIAL_CONDITION_RULE: {
    label: "No trial",
    template: "No sleep trial: this item's condition is excluded by policy.",
  },
  NO_TRIAL_NOT_ELIGIBLE_PRODUCT: {
    label: "No trial",
    template: "No sleep trial: this product is not trial-eligible.",
  },
  MISSING_FEE_BASIS: {
    label: "Can't determine",
    template:
      "Can't determine eligibility — the sale price for this unit was not captured.",
  },
  MISSING_START_DATE: {
    label: "Can't determine",
    template:
      "Can't determine eligibility — the trial start date is missing.",
  },
  // Internal codes used by the evaluator's failure contract — not in the
  // Section 10.6 list but required so a broken evaluation never reads as
  // eligible.
  MISSING_POLICY_TERMS: {
    label: "Can't determine",
    template:
      "Can't determine eligibility — the bound policy terms are missing.",
  },
  MISSING_FEE_SCHEDULE: {
    label: "Can't determine",
    template:
      "Can't determine eligibility — the policy's fee schedule is missing.",
  },
  MISSING_ITEM: {
    label: "Can't determine",
    template: "Can't determine eligibility — the trial item was not found.",
  },
  EVALUATION_ERROR: {
    label: "Can't determine",
    template: "Can't determine eligibility right now — {error}",
  },
};

/** Render a reason code's template with evaluator-supplied params. */
export function explainSleepTrialReason(
  code: string | null | undefined,
  params: SleepTrialReasonParams = {}
): string {
  const entry = code ? SLEEP_TRIAL_REASONS[code] : undefined;
  const template = entry?.template ?? code ?? "Unknown";
  return template.replace(/\{(\w+)\}/g, (_, k) =>
    params[k] != null ? String(params[k]) : ""
  );
}

/** Short label for a reason code (chips, checklist lines). */
export function sleepTrialReasonLabel(code: string | null | undefined): string {
  return (
    (code && SLEEP_TRIAL_REASONS[code]?.label) ?? code ?? "Unknown"
  );
}
