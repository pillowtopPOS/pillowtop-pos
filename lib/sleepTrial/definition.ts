// Sleep Trial policy definition — schema_version 1.
// Single source of truth for the policy JSON stored in
// policy_versions.definition (see docs/sleep-trial-engine.md Sections 5.3,
// 5.4, 13.1, 26.2). Money is integer cents; percents are integer basis
// points (10000 bp = 100%). The DB validator
// (validate_sleep_trial_definition) enforces the same shape server-side.

export type FeeWindowOutcome = "ALLOWED" | "APPROVAL_REQUIRED" | "PROHIBITED";

export interface FeeWindow {
  from_night: number;
  to_night: number | null; // null = open-ended; exactly one, must be last
  outcome: FeeWindowOutcome;
  percent_bp?: number;
  flat_cents?: number;
  min_cents?: number | null;
  max_cents?: number | null;
}

export interface FeeSchedule {
  windows: FeeWindow[];
}

export type ReplacementRule = "FULL_NEW" | "REMAINING" | "FIXED" | "NONE";

export interface ReplacementTrialRule {
  n: number; // which exchange this rule applies to (1-based)
  rule: ReplacementRule;
  nights?: number; // required when rule = FIXED
}

export interface ReplacementMinimum {
  rule: "SAME_AS_POLICY" | "NONE" | "FIXED";
  nights?: number; // required when rule = FIXED
}

export interface PolicyOverride {
  id?: string;
  label?: string;
  scope: {
    type: "CATEGORY" | "BRAND" | "PRODUCT" | "CONDITION";
    value: string;
  };
  set: Record<string, unknown>;
}

export interface SleepTrialDefinition {
  schema_version: 1;
  base: {
    trial: {
      enabled: boolean;
      length_nights: number;
      minimum_nights: number;
      start_event: "FULFILLMENT_COMPLETED"; // SALE_DATE is reserved
      count_starts: "DAY_AFTER_FULFILLMENT" | "FULFILLMENT_DATE";
      ending_soon_days: number;
      extensions_allowed: boolean;
      max_extension_nights: number;
      checkin_nights: number[];
      eligibility_reached_task: boolean;
      ending_soon_task: boolean;
    };
    exchange: {
      allowed: boolean;
      max_count: number;
      replacement_trial: ReplacementTrialRule[];
      replacement_minimum: ReplacementMinimum;
      downgrade_difference: "REFUND_ORIGINAL" | "STORE_CREDIT" | "NOT_REFUNDED";
      require_concern: boolean;
      require_concern_age_days: number;
      early_exception_allowed: boolean;
      expired_exception_allowed: boolean;
      cross_brand_allowed: boolean;
      size_change_allowed: boolean;
    };
    return: {
      allowed: boolean;
      approval_required: boolean;
      exception_allowed: boolean;
      minimum_nights: "SAME_AS_EXCHANGE" | number;
      refund_method: "ORIGINAL_TENDER" | "STORE_CREDIT" | "CUSTOMER_CHOICE";
    };
    fees: {
      tiered: boolean;
      basis: "NET_SELLING_PRICE" | "PRE_DISCOUNT_SELLING_PRICE";
      waiver_allowed: boolean;
      exchange_schedule: string;
      return_schedule: string;
    };
    protector: {
      required: boolean;
      qualifying_category_ids: string[];
      qualifying_product_ids: string[];
      purchase_window_days: number;
      missing_behavior: "BLOCK_WITH_OVERRIDE" | "APPROVAL_REQUIRED" | "WARN_ONLY";
      applies_to: "EXCHANGE_AND_RETURN" | "EXCHANGE_ONLY" | "RETURN_ONLY";
      split_king_units: "ONE" | "TWO";
    };
    split_king: { treatment: "INDEPENDENT" | "PAIRED" };
    inspection: {
      required: boolean;
      checklist: string[];
      photos_required: boolean;
      failed_behavior: "BLOCK" | "APPROVAL_REQUIRED";
    };
    condition: { stains_void_trial: boolean };
    exceptions: {
      approval_valid_days: number;
      reason_required: boolean;
      attachments_allowed: boolean;
      self_approval_note_required: boolean;
    };
    communication: {
      policy_text: string;
      acknowledgment: "NONE" | "CHECKBOX"; // SIGNATURE reserved
      show_on_receipt: boolean;
    };
  };
  fee_schedules: Record<string, FeeSchedule>;
  overrides: PolicyOverride[];
}

export interface ValidationIssue {
  path: string;
  message: string;
}

export interface ValidationResult {
  errors: ValidationIssue[];
  warnings: ValidationIssue[];
}

// Fields an override may set (Section 6.5 whitelist).
export const OVERRIDABLE_FIELDS = [
  "trial.enabled",
  "trial.length_nights",
  "trial.minimum_nights",
  "trial.extensions_allowed",
  "trial.max_extension_nights",
  "exchange.allowed",
  "exchange.max_count",
  "exchange.replacement_trial",
  "exchange.replacement_minimum",
  "exchange.early_exception_allowed",
  "exchange.expired_exception_allowed",
  "return.allowed",
  "return.approval_required",
  "return.exception_allowed",
  "return.minimum_nights",
  "fees.exchange_schedule",
  "fees.return_schedule",
  "protector.required",
] as const;

// Section 5.3 defaults — the "Start from scratch" template and the base for
// every other template. Zach's seeded Version 1 (120/60/15, Section 35)
// lives in migration 067 and differs only in minimum_nights/ending_soon_days.
export const DEFAULT_DEFINITION: SleepTrialDefinition = {
  schema_version: 1,
  base: {
    trial: {
      enabled: true,
      length_nights: 120,
      minimum_nights: 30,
      start_event: "FULFILLMENT_COMPLETED",
      count_starts: "DAY_AFTER_FULFILLMENT",
      ending_soon_days: 14,
      extensions_allowed: true,
      max_extension_nights: 30,
      checkin_nights: [14],
      eligibility_reached_task: false,
      ending_soon_task: false,
    },
    exchange: {
      allowed: true,
      max_count: 1,
      replacement_trial: [{ n: 1, rule: "FULL_NEW" }],
      replacement_minimum: { rule: "SAME_AS_POLICY" },
      downgrade_difference: "STORE_CREDIT",
      require_concern: false,
      require_concern_age_days: 0,
      early_exception_allowed: true,
      expired_exception_allowed: true,
      cross_brand_allowed: true,
      size_change_allowed: true,
    },
    return: {
      allowed: false,
      approval_required: true,
      exception_allowed: true,
      minimum_nights: "SAME_AS_EXCHANGE",
      refund_method: "ORIGINAL_TENDER",
    },
    fees: {
      tiered: false,
      basis: "NET_SELLING_PRICE",
      waiver_allowed: true,
      exchange_schedule: "exchange_default",
      return_schedule: "return_default",
    },
    protector: {
      required: false,
      qualifying_category_ids: [],
      qualifying_product_ids: [],
      purchase_window_days: 0,
      missing_behavior: "BLOCK_WITH_OVERRIDE",
      applies_to: "EXCHANGE_AND_RETURN",
      split_king_units: "ONE",
    },
    split_king: { treatment: "INDEPENDENT" },
    inspection: {
      required: false,
      checklist: [
        "Clean, no stains",
        "No damage",
        "Law tag attached",
        "Protector was used",
      ],
      photos_required: false,
      failed_behavior: "APPROVAL_REQUIRED",
    },
    condition: { stains_void_trial: false },
    exceptions: {
      approval_valid_days: 14,
      reason_required: true,
      attachments_allowed: true,
      self_approval_note_required: true,
    },
    communication: {
      policy_text: "",
      acknowledgment: "NONE",
      show_on_receipt: true,
    },
  },
  fee_schedules: {
    exchange_default: {
      windows: [
        {
          from_night: 1,
          to_night: null,
          outcome: "ALLOWED",
          percent_bp: 0,
          flat_cents: 0,
        },
      ],
    },
    return_default: {
      windows: [
        {
          from_night: 1,
          to_night: null,
          outcome: "ALLOWED",
          percent_bp: 0,
          flat_cents: 0,
        },
      ],
    },
  },
  overrides: [],
};

export function cloneDefinition(
  def: SleepTrialDefinition
): SleepTrialDefinition {
  return JSON.parse(JSON.stringify(def)) as SleepTrialDefinition;
}

// Immutable update of a base field: setBaseField(def, "trial.length_nights", 90).
export function setBaseField(
  def: SleepTrialDefinition,
  path: string,
  value: unknown
): SleepTrialDefinition {
  const next = cloneDefinition(def);
  const keys = path.split(".");
  let obj: Record<string, unknown> = next.base as unknown as Record<
    string,
    unknown
  >;
  for (let i = 0; i < keys.length - 1; i++) {
    obj = obj[keys[i]] as Record<string, unknown>;
  }
  obj[keys[keys.length - 1]] = value;
  return next;
}

// --- Simple-mode fees -------------------------------------------------------
// Simple mode reads/writes the default schedule as one open-ended window
// (Section 5.3: simple fields read/write the default schedules).

export interface SimpleFee {
  enabled: boolean;
  percent: number; // whole percent, 0-100
  flatDollars: number;
}

export function getSimpleFee(
  def: SleepTrialDefinition,
  kind: "exchange" | "return"
): SimpleFee {
  const key =
    kind === "exchange"
      ? def.base.fees.exchange_schedule
      : def.base.fees.return_schedule;
  const window = def.fee_schedules?.[key]?.windows?.[0];
  const percent = Math.round((window?.percent_bp ?? 0) / 100);
  const flatDollars = (window?.flat_cents ?? 0) / 100;
  return { enabled: percent > 0 || flatDollars > 0, percent, flatDollars };
}

export function setSimpleFee(
  def: SleepTrialDefinition,
  kind: "exchange" | "return",
  fee: { percent: number; flatDollars: number }
): SleepTrialDefinition {
  const next = cloneDefinition(def);
  const key =
    kind === "exchange"
      ? next.base.fees.exchange_schedule
      : next.base.fees.return_schedule;
  const schedule = next.fee_schedules[key] ?? { windows: [] };
  schedule.windows = [
    {
      from_night: 1,
      to_night: null,
      outcome: "ALLOWED",
      percent_bp: Math.round(fee.percent * 100),
      flat_cents: Math.round(fee.flatDollars * 100),
    },
  ];
  next.fee_schedules[key] = schedule;
  return next;
}

// --- Templates (Section 5.4) ------------------------------------------------

export interface PolicyTemplate {
  key: string;
  name: string;
  blurb: string;
  build: () => SleepTrialDefinition;
}

export const POLICY_TEMPLATES: PolicyTemplate[] = [
  {
    key: "simple_120",
    name: "Simple 120-Night Exchange",
    blurb:
      "120-night trial, 30-night minimum, one exchange with a fresh trial, no fee, no returns.",
    build: () => {
      const d = cloneDefinition(DEFAULT_DEFINITION);
      d.base.trial.length_nights = 120;
      d.base.trial.minimum_nights = 30;
      d.base.exchange.replacement_trial = [{ n: 1, rule: "REMAINING" }];
      return d;
    },
  },
  {
    key: "protector_backed",
    name: "Protector-Backed Exchange",
    blurb:
      "Same as Simple, but a qualifying protector is required and the exchange gets a full new trial.",
    build: () => {
      const d = cloneDefinition(DEFAULT_DEFINITION);
      d.base.trial.length_nights = 120;
      d.base.trial.minimum_nights = 30;
      d.base.protector.required = true;
      d.base.protector.missing_behavior = "BLOCK_WITH_OVERRIDE";
      d.base.exchange.replacement_trial = [{ n: 1, rule: "FULL_NEW" }];
      return d;
    },
  },
  {
    key: "tiered_comfort_fee",
    name: "Tiered Comfort Fee",
    blurb:
      "120-night trial, 14-night minimum, exchange fee steps down 40% → 30% → 20% → free.",
    build: () => {
      const d = cloneDefinition(DEFAULT_DEFINITION);
      d.base.trial.length_nights = 120;
      d.base.trial.minimum_nights = 14;
      d.base.fees.tiered = true;
      // Section 13.1 example schedule.
      d.fee_schedules.exchange_default = {
        windows: [
          { from_night: 1, to_night: 13, outcome: "PROHIBITED" },
          {
            from_night: 14,
            to_night: 27,
            outcome: "ALLOWED",
            percent_bp: 4000,
            flat_cents: 0,
          },
          {
            from_night: 28,
            to_night: 41,
            outcome: "ALLOWED",
            percent_bp: 3000,
            flat_cents: 0,
          },
          {
            from_night: 42,
            to_night: 55,
            outcome: "ALLOWED",
            percent_bp: 2000,
            flat_cents: 0,
          },
          {
            from_night: 56,
            to_night: null,
            outcome: "ALLOWED",
            percent_bp: 0,
            flat_cents: 0,
          },
        ],
      };
      return d;
    },
  },
  {
    key: "returns_allowed",
    name: "Returns Allowed",
    blurb:
      "100-night trial, 30-night minimum, free exchanges, returns allowed with approval at a 15% fee.",
    build: () => {
      const d = cloneDefinition(DEFAULT_DEFINITION);
      d.base.trial.length_nights = 100;
      d.base.trial.minimum_nights = 30;
      d.base.return.allowed = true;
      d.base.return.approval_required = true;
      d.fee_schedules.return_default = {
        windows: [
          {
            from_night: 1,
            to_night: null,
            outcome: "ALLOWED",
            percent_bp: 1500,
            flat_cents: 0,
          },
        ],
      };
      return d;
    },
  },
  {
    key: "scratch",
    name: "Start from scratch",
    blurb: "All Section 5.3 defaults — adjust everything yourself.",
    build: () => cloneDefinition(DEFAULT_DEFINITION),
  },
];

// --- Overview summary (canonical Section 17.78) ------------------------------
// Generated, never hand-typed. Produces the plain-English sentence shown on
// the Overview card and stored as policy_versions.summary_text.

function money(cents: number): string {
  return `$${(cents / 100).toFixed(2)}`;
}

function feePhrase(
  def: SleepTrialDefinition,
  kind: "exchange" | "return"
): string | null {
  const key =
    kind === "exchange"
      ? def.base.fees.exchange_schedule
      : def.base.fees.return_schedule;
  const windows = def.fee_schedules?.[key]?.windows ?? [];
  const charged = windows.filter(
    (w) => (w.percent_bp ?? 0) > 0 || (w.flat_cents ?? 0) > 0
  );
  if (charged.length === 0) return null;
  if (charged.length === 1 && windows.length === 1) {
    const w = charged[0];
    const parts: string[] = [];
    if ((w.percent_bp ?? 0) > 0) parts.push(`${(w.percent_bp ?? 0) / 100}%`);
    if ((w.flat_cents ?? 0) > 0) parts.push(money(w.flat_cents ?? 0));
    return parts.join(" plus ");
  }
  return "a tiered fee";
}

function scopeLabel(o: PolicyOverride): string {
  if (o.label) return o.label;
  const v = o.scope.value;
  switch (o.scope.type) {
    case "CATEGORY":
      return `${v} category`;
    case "BRAND":
      return v;
    case "CONDITION":
      return v.charAt(0).toUpperCase() + v.slice(1).toLowerCase();
    default:
      return v;
  }
}

export function generateSummary(def: SleepTrialDefinition): string {
  const t = def.base.trial;
  const x = def.base.exchange;
  const r = def.base.return;
  const p = def.base.protector;
  const sentences: string[] = [];

  if (!t.enabled) {
    sentences.push("No sleep trial is offered.");
  } else {
    const start =
      t.count_starts === "FULFILLMENT_DATE"
        ? "on the day their mattress is delivered or picked up"
        : "the day after their mattress is delivered or picked up";
    sentences.push(
      `Customers get a ${t.length_nights}-night sleep trial starting ${start}.`
    );

    if (x.allowed) {
      sentences.push(
        t.minimum_nights > 0
          ? `They can exchange after ${t.minimum_nights} nights.`
          : "They can exchange at any time during the trial."
      );
      sentences.push(
        x.max_count === 1
          ? "One exchange is allowed."
          : `Up to ${x.max_count} exchanges are allowed.`
      );
      const fee = feePhrase(def, "exchange");
      sentences.push(
        fee ? `An exchange fee of ${fee} applies.` : "There is no exchange fee."
      );
    } else {
      sentences.push("Exchanges are not allowed.");
    }

    if (p.required) sentences.push("A qualifying mattress protector is required.");

    if (r.allowed) {
      const fee = feePhrase(def, "return");
      const feePart = fee ? ` with a ${fee} fee` : "";
      sentences.push(
        r.approval_required
          ? `Returns are allowed with approval${feePart}.`
          : `Returns are allowed${feePart}.`
      );
    } else {
      sentences.push("Returns are not allowed.");
    }
  }

  for (const o of def.overrides ?? []) {
    const label = scopeLabel(o);
    if (o.set["trial.enabled"] === false) {
      sentences.push(`${label} mattresses have no trial.`);
    } else if (typeof o.set["trial.length_nights"] === "number") {
      sentences.push(
        `${label} mattresses have a ${o.set["trial.length_nights"]}-night trial.`
      );
    }
  }

  return sentences.join(" ");
}

// --- Validation issues → field anchors + plain English -----------------------
// The DB validator returns {path, message} with paths like
// "base.trial.length_nights". The settings UI renders each issue as a short
// line under the field it refers to — never a raw path.

export const FIELD_LABELS: Record<string, string> = {
  "trial.enabled": "Offer a sleep trial",
  "trial.length_nights": "Trial length",
  "trial.minimum_nights": "Nights before exchange is allowed",
  "trial.start_event": "Trial starts on",
  "trial.count_starts": "Night 1 is",
  "trial.ending_soon_days": "Ending-soon window",
  "trial.extensions_allowed": "Allow trial extensions",
  "trial.max_extension_nights": "Most extra nights per trial",
  "trial.checkin_nights": "Automatic check-in follow-ups",
  "trial.eligibility_reached_task": "Eligibility-reached follow-up",
  "trial.ending_soon_task": "Ending-soon follow-up",
  "exchange.allowed": "Allow comfort exchanges",
  "exchange.max_count": "Exchanges allowed per trial",
  "exchange.replacement_trial": "Replacement trial rules",
  "exchange.replacement_minimum": "Minimum nights on a replacement",
  "exchange.downgrade_difference": "Downgrade difference",
  "exchange.require_concern": "Documented sleep concern",
  "exchange.require_concern_age_days": "Concern age",
  "exchange.early_exception_allowed": "Early exchange exceptions",
  "exchange.expired_exception_allowed": "After-trial exchange requests",
  "exchange.cross_brand_allowed": "Different-brand replacement",
  "exchange.size_change_allowed": "Different-size replacement",
  "return.allowed": "Allow sleep trial returns",
  "return.approval_required": "Return approval",
  "return.exception_allowed": "Return exceptions",
  "return.minimum_nights": "Nights before a return is allowed",
  "return.refund_method": "Refund method",
  "fees.basis": "Fee basis",
  "fees.tiered": "Tiered fees",
  "fees.waiver_allowed": "Fee waivers",
  "fees.exchange_schedule": "Exchange fee schedule",
  "fees.return_schedule": "Return fee schedule",
  fees: "Fee schedule",
  "protector.required": "Protector requirement",
  "protector.qualifying_category_ids": "Protector categories that count",
  "protector.qualifying_product_ids": "Qualifying protector products",
  "protector.purchase_window_days": "Protector purchase window",
  "protector.missing_behavior": "Missing-protector behavior",
  "protector.applies_to": "Protector requirement scope",
  "protector.split_king_units": "Split king protectors",
  "split_king.treatment": "Split king handling",
  "inspection.required": "Inspection requirement",
  "inspection.checklist": "Inspection checklist",
  "inspection.photos_required": "Inspection photos",
  "inspection.failed_behavior": "Failed-inspection behavior",
  "exceptions.approval_valid_days": "Approval validity",
  "exceptions.reason_required": "Reason code",
  "exceptions.attachments_allowed": "Attachments",
  "exceptions.self_approval_note_required": "Self-approval note",
  "communication.policy_text": "Customer-facing policy text",
  "communication.acknowledgment": "Policy acknowledgment",
  "communication.show_on_receipt": "Show on receipt",
};

// Maps a validator path to the field key it refers to.
export function issueAnchor(path: string): string {
  let p = path;
  const setMatch = /^overrides\[\d+\]\.set\.(.+)$/.exec(p);
  if (setMatch) {
    p = setMatch[1];
  } else if (p.startsWith("base.")) {
    p = p.slice(5);
  } else if (p.startsWith("fee_schedules.exchange_default")) {
    return "fees.exchange_schedule";
  } else if (p.startsWith("fee_schedules.return_default")) {
    return "fees.return_schedule";
  } else if (p.startsWith("fee_schedules")) {
    return "fees";
  } else if (p.startsWith("overrides")) {
    return "overrides";
  }
  // Longest field-label key that prefixes the path, so
  // "exchange.replacement_trial[0].n" anchors to "exchange.replacement_trial".
  const hit = Object.keys(FIELD_LABELS)
    .sort((a, b) => b.length - a.length)
    .find((k) => p === k || p.startsWith(k + ".") || p.startsWith(k + "["));
  return hit ?? p;
}

// One short plain-English line for an issue. Known validator messages get a
// friendlier sentence; everything else is "<Field label> <message>."
export function formatIssue(issue: ValidationIssue): string {
  const anchor = issueAnchor(issue.path);

  const checkin = /^Check-in night (\d+) is beyond/.exec(issue.message);
  if (anchor === "trial.checkin_nights" && checkin) {
    return `Night ${checkin[1]} is after the trial ends, so that check-in won't happen.`;
  }
  const protectorWindow =
    /^Protector purchase window is longer than the (\d+)-night minimum/.exec(
      issue.message
    );
  if (anchor === "protector.purchase_window_days" && protectorWindow) {
    return `The purchase window is longer than the ${protectorWindow[1]}-night minimum, so a protector added in that gap won't count.`;
  }
  if (/requires approval but charges no fee/i.test(issue.message)) {
    return "Requires approval but charges no fee.";
  }

  const label = FIELD_LABELS[anchor];
  const msg = issue.message.replace(/\.$/, "");
  if (label) return `${label} ${msg}.`;
  return msg.charAt(0).toUpperCase() + msg.slice(1) + ".";
}

// Issues anchored to a field, formatted for display under it.
export function issuesFor(
  issues: ValidationIssue[],
  anchor: string
): string[] {
  return issues
    .filter((i) => issueAnchor(i.path) === anchor)
    .map(formatIssue);
}
