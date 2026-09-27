"use client";

import { useEffect, useState, type ReactNode } from "react";
import { X } from "lucide-react";
import {
  cloneDefinition,
  generateSummary,
  getSimpleFee,
  issuesFor,
  POLICY_TEMPLATES,
  setBaseField,
  setSimpleFee,
  type SleepTrialDefinition,
  type ValidationIssue,
} from "@/lib/sleepTrial/definition";
import type { PolicyVersionRow } from "@/lib/sleepTrial/policy";

// Section panels for Settings → Sleep Trial (spec Sections 5.1–5.3). Each
// field writes through `update` to the single Draft version — nothing is live
// until Publish, so every editable field carries the "Affects future sales
// only" note. Validation issues come back from save_sleep_trial_draft and
// render as short plain-English lines under the field they refer to.

export interface SectionProps {
  def: SleepTrialDefinition;
  // True when the viewer can't manage policy — everything renders read-only.
  disabled: boolean;
  update: (next: SleepTrialDefinition) => void;
  errors: ValidationIssue[];
  warnings: ValidationIssue[];
}

function IssueLines({
  errors,
  warnings,
}: {
  errors?: string[];
  warnings?: string[];
}) {
  return (
    <>
      {errors?.map((m, i) => (
        <p key={`e${i}`} className="mt-1 text-xs text-red-600">
          {m}
        </p>
      ))}
      {warnings?.map((m, i) => (
        <p key={`w${i}`} className="mt-1 text-xs text-slate-500">
          {m}
        </p>
      ))}
    </>
  );
}

// Field-level message lists for a section.
function fe(props: SectionProps, anchor: string): string[] {
  return issuesFor(props.errors, anchor);
}
function fw(props: SectionProps, anchor: string): string[] {
  return issuesFor(props.warnings, anchor);
}

const inputCls =
  "w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500 disabled:bg-slate-50 disabled:text-slate-500";

function setField(
  props: SectionProps,
  path: string,
  value: unknown
) {
  props.update(setBaseField(props.def, path, value));
}

function Field({
  label,
  help,
  future,
  errors,
  warnings,
  children,
}: {
  label: string;
  help?: string;
  future?: boolean;
  errors?: string[];
  warnings?: string[];
  children: ReactNode;
}) {
  return (
    <div>
      <label className="mb-1 block text-sm font-medium text-slate-700">
        {label}
      </label>
      {children}
      <IssueLines errors={errors} warnings={warnings} />
      {help && <p className="mt-1 text-xs text-slate-500">{help}</p>}
      {future && (
        <p className="mt-1 text-[11px] italic text-slate-400">
          Affects future sales only.
        </p>
      )}
    </div>
  );
}

function Toggle({
  label,
  help,
  checked,
  disabled,
  future,
  errors,
  warnings,
  onChange,
}: {
  label: string;
  help?: string;
  checked: boolean;
  disabled: boolean;
  future?: boolean;
  errors?: string[];
  warnings?: string[];
  onChange: (v: boolean) => void;
}) {
  return (
    <div className="flex items-start justify-between gap-4 py-1">
      <div className="min-w-0">
        <p className="text-sm font-medium text-slate-700">{label}</p>
        <IssueLines errors={errors} warnings={warnings} />
        {help && <p className="mt-0.5 text-xs text-slate-500">{help}</p>}
        {future && (
          <p className="mt-0.5 text-[11px] italic text-slate-400">
            Affects future sales only.
          </p>
        )}
      </div>
      <button
        type="button"
        role="switch"
        aria-checked={checked}
        aria-label={label}
        disabled={disabled}
        onClick={() => onChange(!checked)}
        className={`relative mt-0.5 inline-flex h-6 w-11 shrink-0 rounded-full transition ${
          checked ? "bg-brand-600" : "bg-slate-300"
        } ${disabled ? "cursor-not-allowed opacity-60" : ""}`}
      >
        <span
          className={`inline-block h-5 w-5 translate-y-0.5 rounded-full bg-white shadow transition ${
            checked ? "translate-x-5" : "translate-x-0.5"
          }`}
        />
      </button>
    </div>
  );
}

function NumField({
  label,
  help,
  value,
  min,
  max,
  disabled,
  future,
  suffix,
  errors,
  warnings,
  onCommit,
}: {
  label: string;
  help?: string;
  value: number;
  min: number;
  max: number;
  disabled: boolean;
  future?: boolean;
  suffix?: string;
  errors?: string[];
  warnings?: string[];
  onCommit: (v: number) => void;
}) {
  const [text, setText] = useState(String(value));
  const [focused, setFocused] = useState(false);

  useEffect(() => {
    if (!focused) setText(String(value));
  }, [value, focused]);

  function commit() {
    setFocused(false);
    const parsed = Math.floor(Number(text));
    if (!Number.isFinite(parsed)) {
      setText(String(value));
      return;
    }
    const clamped = Math.min(max, Math.max(min, parsed));
    setText(String(clamped));
    if (clamped !== value) onCommit(clamped);
  }

  return (
    <Field
      label={label}
      help={help}
      future={future}
      errors={errors}
      warnings={warnings}
    >
      <div className="flex items-center gap-2">
        <input
          type="number"
          min={min}
          max={max}
          disabled={disabled}
          value={focused ? text : String(value)}
          onChange={(e) => setText(e.target.value)}
          onFocus={() => {
            setText(String(value));
            setFocused(true);
          }}
          onBlur={commit}
          onKeyDown={(e) => {
            if (e.key === "Enter") (e.target as HTMLInputElement).blur();
          }}
          className={`${inputCls} w-28`}
        />
        {suffix && <span className="text-sm text-slate-500">{suffix}</span>}
      </div>
    </Field>
  );
}

function Sel<T extends string>({
  label,
  help,
  value,
  options,
  disabled,
  future,
  errors,
  warnings,
  onChange,
}: {
  label: string;
  help?: string;
  value: T;
  options: { value: T; label: string }[];
  disabled: boolean;
  future?: boolean;
  errors?: string[];
  warnings?: string[];
  onChange: (v: T) => void;
}) {
  return (
    <Field
      label={label}
      help={help}
      future={future}
      errors={errors}
      warnings={warnings}
    >
      <select
        value={value}
        disabled={disabled}
        onChange={(e) => onChange(e.target.value as T)}
        className={inputCls}
      >
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
    </Field>
  );
}

// "14, 30" → [14, 30]. Commits on blur; invalid entries are dropped.
function NightListField({
  label,
  help,
  value,
  disabled,
  future,
  errors,
  warnings,
  onCommit,
}: {
  label: string;
  help?: string;
  value: number[];
  disabled: boolean;
  future?: boolean;
  errors?: string[];
  warnings?: string[];
  onCommit: (v: number[]) => void;
}) {
  const [text, setText] = useState(value.join(", "));
  const [focused, setFocused] = useState(false);

  useEffect(() => {
    if (!focused) setText(value.join(", "));
  }, [value, focused]);

  function commit() {
    setFocused(false);
    const parsed = text
      .split(",")
      .map((s) => Math.floor(Number(s.trim())))
      .filter((n) => Number.isFinite(n) && n >= 1);
    const unique = Array.from(new Set(parsed)).sort((a, b) => a - b);
    onCommit(unique);
  }

  return (
    <Field
      label={label}
      help={help}
      future={future}
      errors={errors}
      warnings={warnings}
    >
      <input
        type="text"
        disabled={disabled}
        value={focused ? text : value.join(", ")}
        placeholder="e.g. 14, 30"
        onChange={(e) => setText(e.target.value)}
        onFocus={() => {
          setText(value.join(", "));
          setFocused(true);
        }}
        onBlur={commit}
        className={inputCls}
      />
    </Field>
  );
}

function SectionHeading({
  title,
  description,
}: {
  title: string;
  description?: string;
}) {
  return (
    <div className="mb-4">
      <h2 className="text-lg font-semibold text-slate-900">{title}</h2>
      {description && <p className="mt-1 text-sm text-slate-500">{description}</p>}
    </div>
  );
}

// --- Overview ---------------------------------------------------------------

export function OverviewSection({
  state,
  canManage,
  onTemplate,
}: {
  state: {
    published: PolicyVersionRow | null;
    draft: PolicyVersionRow | null;
    publisherName: string | null;
  };
  canManage: boolean;
  onTemplate: (def: SleepTrialDefinition) => void;
}) {
  const shown = state.draft ?? state.published;

  return (
    <div>
      <SectionHeading title="Overview" />

      {shown ? (
        <div className="rounded-lg border border-slate-200 bg-slate-50 p-4">
          <p className="text-sm leading-relaxed text-slate-700">
            {generateSummary(shown.definition)}
          </p>
          <p className="mt-2 text-xs text-slate-400">
            Generated from the{" "}
            {state.draft ? "draft" : `Version ${state.published?.version_number}`}{" "}
            definition.
          </p>
        </div>
      ) : (
        <p className="text-sm text-slate-500">
          No sleep trial policy yet. Start from a template below — it creates a
          draft, nothing goes live until you publish.
        </p>
      )}

      {state.draft && (
        <p className="mt-3 text-sm text-amber-700">
          A draft is in progress (Version {state.draft.version_number}). Changes
          apply to future sales only, and nothing is live until you publish.
        </p>
      )}

      <div className="mt-5">
        <h3 className="text-sm font-semibold text-slate-800">
          Start from a template
        </h3>
        <p className="mt-0.5 text-xs text-slate-500">
          Choosing a template fills the draft — nothing is live until you
          publish.
        </p>
        <div className="mt-3 grid gap-3 sm:grid-cols-2">
          {POLICY_TEMPLATES.map((t) => (
            <button
              key={t.key}
              type="button"
              disabled={!canManage}
              onClick={() => {
                if (
                  shown &&
                  !window.confirm(
                    "This replaces your current draft. Your published policy is unchanged until you publish."
                  )
                ) {
                  return;
                }
                onTemplate(t.build());
              }}
              className="rounded-lg border border-slate-200 bg-white p-4 text-left transition hover:border-brand-400 hover:shadow-sm disabled:cursor-not-allowed disabled:opacity-60"
            >
              <p className="text-sm font-medium text-slate-900">{t.name}</p>
              <p className="mt-1 text-xs text-slate-500">{t.blurb}</p>
            </button>
          ))}
        </div>
        {!canManage && (
          <p className="mt-2 text-xs text-slate-400">
            Only users with the Manage sleep trial policy permission can start
            a draft.
          </p>
        )}
      </div>
    </div>
  );
}

// --- 2. Trial Terms ----------------------------------------------------------

export function TrialTermsSection(props: SectionProps) {
  const { def, disabled } = props;
  const t = def.base.trial;
  const future = !disabled;

  return (
    <div>
      <SectionHeading
        title="Trial Terms"
        description="How long the trial runs and when the clock starts."
      />
      <div className="space-y-4">
        <Toggle
          label="Offer a sleep trial"
          checked={t.enabled}
          disabled={disabled}
          future={future}
          errors={fe(props, "trial.enabled")}
          warnings={fw(props, "trial.enabled")}
          onChange={(v) => setField(props, "trial.enabled", v)}
        />
        {t.enabled && (
          <>
            <div className="grid gap-4 sm:grid-cols-2">
              <NumField
                label="Trial length (nights)"
                value={t.length_nights}
                min={1}
                max={730}
                disabled={disabled}
                future={future}
                errors={fe(props, "trial.length_nights")}
                warnings={fw(props, "trial.length_nights")}
                onCommit={(v) => setField(props, "trial.length_nights", v)}
              />
              <NumField
                label="Nights before exchange is allowed"
                help="0 = no minimum."
                value={t.minimum_nights}
                min={0}
                max={Math.max(t.length_nights - 1, 0)}
                disabled={disabled}
                future={future}
                errors={fe(props, "trial.minimum_nights")}
                warnings={fw(props, "trial.minimum_nights")}
                onCommit={(v) => setField(props, "trial.minimum_nights", v)}
              />
            </div>
            <div className="grid gap-4 sm:grid-cols-2">
              <Sel
                label="Trial starts on"
                help="The delivery or pickup date. Starting at the sale date is not supported yet."
                value={t.start_event}
                options={[
                  {
                    value: "FULFILLMENT_COMPLETED" as const,
                    label: "Delivery or pickup is confirmed",
                  },
                ]}
                disabled={disabled}
                future={future}
                errors={fe(props, "trial.start_event")}
                warnings={fw(props, "trial.start_event")}
                onChange={(v) => setField(props, "trial.start_event", v)}
              />
              <Sel
                label="Night 1 is"
                value={t.count_starts}
                options={[
                  {
                    value: "DAY_AFTER_FULFILLMENT" as const,
                    label: "The day after delivery/pickup",
                  },
                  {
                    value: "FULFILLMENT_DATE" as const,
                    label: "The delivery/pickup date itself",
                  },
                ]}
                disabled={disabled}
                future={future}
                errors={fe(props, "trial.count_starts")}
                warnings={fw(props, "trial.count_starts")}
                onChange={(v) => setField(props, "trial.count_starts", v)}
              />
            </div>
            <NumField
              label='Show "ending soon" this many days before the end'
              value={t.ending_soon_days}
              min={0}
              max={60}
              disabled={disabled}
              future={future}
              suffix="days"
              errors={fe(props, "trial.ending_soon_days")}
              warnings={fw(props, "trial.ending_soon_days")}
              onCommit={(v) => setField(props, "trial.ending_soon_days", v)}
            />
            <Toggle
              label="Allow trial extensions"
              checked={t.extensions_allowed}
              disabled={disabled}
              future={future}
              errors={fe(props, "trial.extensions_allowed")}
              warnings={fw(props, "trial.extensions_allowed")}
              onChange={(v) => setField(props, "trial.extensions_allowed", v)}
            />
            {t.extensions_allowed && (
              <NumField
                label="Most extra nights per trial"
                value={t.max_extension_nights}
                min={1}
                max={365}
                disabled={disabled}
                future={future}
                suffix="nights"
                errors={fe(props, "trial.max_extension_nights")}
                warnings={fw(props, "trial.max_extension_nights")}
                onCommit={(v) =>
                  setField(props, "trial.max_extension_nights", v)
                }
              />
            )}
            <NightListField
              label="Automatic check-in follow-ups on nights"
              help="Comma-separated night numbers. Empty = none."
              value={t.checkin_nights}
              disabled={disabled}
              future={future}
              errors={fe(props, "trial.checkin_nights")}
              warnings={fw(props, "trial.checkin_nights")}
              onCommit={(v) => setField(props, "trial.checkin_nights", v)}
            />
            {t.minimum_nights > 0 && (
              <Toggle
                label="Create a follow-up when exchange eligibility is reached"
                checked={t.eligibility_reached_task}
                disabled={disabled}
                future={future}
                errors={fe(props, "trial.eligibility_reached_task")}
                warnings={fw(props, "trial.eligibility_reached_task")}
                onChange={(v) =>
                  setField(props, "trial.eligibility_reached_task", v)
                }
              />
            )}
            <Toggle
              label="Create a follow-up when ending soon starts"
              checked={t.ending_soon_task}
              disabled={disabled}
              future={future}
              errors={fe(props, "trial.ending_soon_task")}
              warnings={fw(props, "trial.ending_soon_task")}
              onChange={(v) => setField(props, "trial.ending_soon_task", v)}
            />
          </>
        )}
      </div>
    </div>
  );
}

// --- 3. Exchanges ------------------------------------------------------------

const REPLACEMENT_RULE_OPTIONS = [
  { value: "FULL_NEW" as const, label: "A full new trial" },
  { value: "REMAINING" as const, label: "The remaining nights" },
  { value: "FIXED" as const, label: "A fixed number of nights" },
  { value: "NONE" as const, label: "No further trial" },
];

function setReplacementRule(
  props: SectionProps,
  n: number,
  rule: "FULL_NEW" | "REMAINING" | "FIXED" | "NONE",
  nights?: number
) {
  const next = cloneDefinition(props.def);
  const list = next.base.exchange.replacement_trial;
  const idx = list.findIndex((r) => r.n === n);
  const entry = {
    n,
    rule,
    ...(rule === "FIXED" ? { nights: nights ?? 30 } : {}),
  };
  if (idx >= 0) list[idx] = entry;
  else list.push(entry);
  list.sort((a, b) => a.n - b.n);
  props.update(next);
}

export function ExchangesSection(props: SectionProps) {
  const { def, disabled } = props;
  const x = def.base.exchange;
  const t = def.base.trial;
  const future = !disabled;

  const ruleFor = (n: number) =>
    x.replacement_trial.find((r) => r.n === n) ?? { n, rule: "NONE" as const };

  return (
    <div>
      <SectionHeading
        title="Exchanges"
        description="Comfort exchanges during the trial."
      />
      <div className="space-y-4">
        <Toggle
          label="Allow comfort exchanges"
          checked={x.allowed}
          disabled={disabled || !t.enabled}
          future={future}
          errors={fe(props, "exchange.allowed")}
          warnings={fw(props, "exchange.allowed")}
          onChange={(v) => setField(props, "exchange.allowed", v)}
        />
        {x.allowed && t.enabled && (
          <>
            <NumField
              label="Exchanges allowed per trial"
              value={x.max_count}
              min={1}
              max={5}
              disabled={disabled}
              future={future}
              errors={fe(props, "exchange.max_count")}
              warnings={fw(props, "exchange.max_count")}
              onCommit={(v) => {
                const next = setBaseField(def, "exchange.max_count", v);
                next.base.exchange.replacement_trial =
                  next.base.exchange.replacement_trial.filter(
                    (r) => r.n <= v
                  );
                props.update(next);
              }}
            />
            <div>
              <p className="mb-2 text-sm font-medium text-slate-700">
                What the replacement mattress gets
              </p>
              <IssueLines
                errors={fe(props, "exchange.replacement_trial")}
                warnings={fw(props, "exchange.replacement_trial")}
              />
              <div className="space-y-3">
                {Array.from({ length: x.max_count }, (_, i) => i + 1).map(
                  (n) => {
                    const r = ruleFor(n);
                    return (
                      <div
                        key={n}
                        className="flex flex-wrap items-end gap-3 rounded-md border border-slate-100 bg-slate-50 px-3 py-2"
                      >
                        <Sel
                          label={
                            n === 1 ? "After exchange 1" : `After exchange ${n}`
                          }
                          value={r.rule}
                          options={REPLACEMENT_RULE_OPTIONS}
                          disabled={disabled}
                          onChange={(v) =>
                            setReplacementRule(
                              props,
                              n,
                              v,
                              "nights" in r ? r.nights : undefined
                            )
                          }
                        />
                        {r.rule === "FIXED" && (
                          <NumField
                            label="Nights"
                            value={"nights" in r ? r.nights ?? 30 : 30}
                            min={1}
                            max={730}
                            disabled={disabled}
                            onCommit={(v) =>
                              setReplacementRule(props, n, "FIXED", v)
                            }
                          />
                        )}
                      </div>
                    );
                  }
                )}
              </div>
            </div>
            <div className="grid gap-4 sm:grid-cols-2">
              <Sel
                label="Minimum nights on a replacement"
                value={x.replacement_minimum.rule}
                options={[
                  { value: "SAME_AS_POLICY" as const, label: "Same as policy" },
                  { value: "NONE" as const, label: "No minimum" },
                  { value: "FIXED" as const, label: "Fixed nights" },
                ]}
                disabled={disabled}
                future={future}
                errors={fe(props, "exchange.replacement_minimum")}
                warnings={fw(props, "exchange.replacement_minimum")}
                onChange={(v) =>
                  setField(props, "exchange.replacement_minimum", {
                    rule: v,
                    ...(v === "FIXED"
                      ? { nights: x.replacement_minimum.nights ?? 30 }
                      : {}),
                  })
                }
              />
              {x.replacement_minimum.rule === "FIXED" && (
                <NumField
                  label="Replacement minimum nights"
                  value={x.replacement_minimum.nights ?? 30}
                  min={0}
                  max={Math.max(t.length_nights - 1, 0)}
                  disabled={disabled}
                  future={future}
                  onCommit={(v) =>
                    setField(props, "exchange.replacement_minimum", {
                      rule: "FIXED",
                      nights: v,
                    })
                  }
                />
              )}
            </div>
            <Sel
              label="When the replacement costs less, the difference is"
              value={x.downgrade_difference}
              options={[
                { value: "STORE_CREDIT" as const, label: "Store credit" },
                {
                  value: "REFUND_ORIGINAL" as const,
                  label: "Refunded to the original tender",
                },
                { value: "NOT_REFUNDED" as const, label: "Not refunded" },
              ]}
              disabled={disabled}
              future={future}
              errors={fe(props, "exchange.downgrade_difference")}
              warnings={fw(props, "exchange.downgrade_difference")}
              onChange={(v) => setField(props, "exchange.downgrade_difference", v)}
            />
            <Toggle
              label="Require a documented sleep concern before an exchange"
              checked={x.require_concern}
              disabled={disabled}
              future={future}
              errors={fe(props, "exchange.require_concern")}
              warnings={fw(props, "exchange.require_concern")}
              onChange={(v) => setField(props, "exchange.require_concern", v)}
            />
            {x.require_concern && (
              <NumField
                label="Concern must be at least this many days old"
                value={x.require_concern_age_days}
                min={0}
                max={60}
                disabled={disabled}
                future={future}
                suffix="days"
                errors={fe(props, "exchange.require_concern_age_days")}
                warnings={fw(props, "exchange.require_concern_age_days")}
                onCommit={(v) =>
                  setField(props, "exchange.require_concern_age_days", v)
                }
              />
            )}
            {t.minimum_nights > 0 && (
              <Toggle
                label="Allow early exchange exception requests"
                checked={x.early_exception_allowed}
                disabled={disabled}
                future={future}
                errors={fe(props, "exchange.early_exception_allowed")}
                warnings={fw(props, "exchange.early_exception_allowed")}
                onChange={(v) =>
                  setField(props, "exchange.early_exception_allowed", v)
                }
              />
            )}
            <Toggle
              label="Allow exchange requests after the trial ends"
              checked={x.expired_exception_allowed}
              disabled={disabled}
              future={future}
              errors={fe(props, "exchange.expired_exception_allowed")}
              warnings={fw(props, "exchange.expired_exception_allowed")}
              onChange={(v) =>
                setField(props, "exchange.expired_exception_allowed", v)
              }
            />
            <Toggle
              label="Replacement can be a different brand"
              checked={x.cross_brand_allowed}
              disabled={disabled}
              future={future}
              errors={fe(props, "exchange.cross_brand_allowed")}
              warnings={fw(props, "exchange.cross_brand_allowed")}
              onChange={(v) =>
                setField(props, "exchange.cross_brand_allowed", v)
              }
            />
            <Toggle
              label="Replacement can be a different size"
              checked={x.size_change_allowed}
              disabled={disabled}
              future={future}
              errors={fe(props, "exchange.size_change_allowed")}
              warnings={fw(props, "exchange.size_change_allowed")}
              onChange={(v) =>
                setField(props, "exchange.size_change_allowed", v)
              }
            />
          </>
        )}
      </div>
    </div>
  );
}

// --- 4. Returns --------------------------------------------------------------

export function ReturnsSection(props: SectionProps) {
  const { def, disabled } = props;
  const r = def.base.return;
  const t = def.base.trial;
  const future = !disabled;
  const minIsFixed = typeof r.minimum_nights === "number";

  return (
    <div>
      <SectionHeading
        title="Returns"
        description="Whether mattresses can be returned for a refund."
      />
      <div className="space-y-4">
        <Toggle
          label="Allow sleep trial returns"
          checked={r.allowed}
          disabled={disabled || !t.enabled}
          future={future}
          errors={fe(props, "return.allowed")}
          warnings={fw(props, "return.allowed")}
          onChange={(v) => setField(props, "return.allowed", v)}
        />
        {r.allowed && (
          <>
            <Toggle
              label="Returns need approval"
              checked={r.approval_required}
              disabled={disabled}
              future={future}
              errors={fe(props, "return.approval_required")}
              warnings={fw(props, "return.approval_required")}
              onChange={(v) => setField(props, "return.approval_required", v)}
            />
            <div className="grid gap-4 sm:grid-cols-2">
              <Sel
                label="Nights before a return is allowed"
                value={minIsFixed ? "FIXED" : "SAME_AS_EXCHANGE"}
                options={[
                  {
                    value: "SAME_AS_EXCHANGE" as const,
                    label: "Same as the exchange minimum",
                  },
                  { value: "FIXED" as const, label: "Fixed nights" },
                ]}
                disabled={disabled}
                future={future}
                errors={fe(props, "return.minimum_nights")}
                warnings={fw(props, "return.minimum_nights")}
                onChange={(v) =>
                  setField(
                    props,
                    "return.minimum_nights",
                    v === "FIXED" ? 0 : "SAME_AS_EXCHANGE"
                  )
                }
              />
              {minIsFixed && (
                <NumField
                  label="Return minimum nights"
                  value={r.minimum_nights as number}
                  min={0}
                  max={Math.max(t.length_nights - 1, 0)}
                  disabled={disabled}
                  future={future}
                  onCommit={(v) =>
                    setField(props, "return.minimum_nights", v)
                  }
                />
              )}
            </div>
            <Sel
              label="Refund as"
              value={r.refund_method}
              options={[
                {
                  value: "ORIGINAL_TENDER" as const,
                  label: "Original tender",
                },
                { value: "STORE_CREDIT" as const, label: "Store credit" },
                {
                  value: "CUSTOMER_CHOICE" as const,
                  label: "Customer chooses",
                },
              ]}
              disabled={disabled}
              future={future}
              errors={fe(props, "return.refund_method")}
              warnings={fw(props, "return.refund_method")}
              onChange={(v) => setField(props, "return.refund_method", v)}
            />
          </>
        )}
        {!r.allowed && t.enabled && (
          <Toggle
            label="Allow return exception requests when returns are off"
            checked={r.exception_allowed}
            disabled={disabled}
            future={future}
            errors={fe(props, "return.exception_allowed")}
            warnings={fw(props, "return.exception_allowed")}
            onChange={(v) => setField(props, "return.exception_allowed", v)}
          />
        )}
      </div>
    </div>
  );
}

// --- 5. Fees (simple mode) ---------------------------------------------------
// Simple mode writes one open-ended window on the default schedule (Section
// 5.3). The tiered schedule builder is a later phase (ST-7).

function SimpleFeeFields({
  props,
  kind,
  label,
  anchor,
}: {
  props: SectionProps;
  kind: "exchange" | "return";
  label: string;
  anchor: string;
}) {
  const { def, disabled } = props;
  const fee = getSimpleFee(def, kind);
  const future = !disabled;

  return (
    <div className="space-y-3">
      <Toggle
        label={label}
        checked={fee.enabled}
        disabled={disabled}
        future={future}
        errors={fe(props, anchor)}
        warnings={fw(props, anchor)}
        onChange={(v) =>
          props.update(
            setSimpleFee(def, kind, {
              percent: v ? fee.percent || 0 : 0,
              flatDollars: v ? fee.flatDollars || 0 : 0,
            })
          )
        }
      />
      {fee.enabled && (
        <div className="flex flex-wrap items-end gap-4 pl-1">
          <NumField
            label="Percent"
            value={fee.percent}
            min={0}
            max={100}
            disabled={disabled}
            future={future}
            suffix="%"
            onCommit={(v) =>
              props.update(
                setSimpleFee(def, kind, {
                  percent: v,
                  flatDollars: fee.flatDollars,
                })
              )
            }
          />
          <NumField
            label="Flat amount"
            help="Added on top of the percent."
            value={fee.flatDollars}
            min={0}
            max={5000}
            disabled={disabled}
            future={future}
            suffix="$"
            onCommit={(v) =>
              props.update(
                setSimpleFee(def, kind, { percent: fee.percent, flatDollars: v })
              )
            }
          />
        </div>
      )}
    </div>
  );
}

export function FeesSection(props: SectionProps) {
  const { def, disabled } = props;
  const f = def.base.fees;
  const x = def.base.exchange;
  const r = def.base.return;
  const future = !disabled;

  const exchangeFee = getSimpleFee(def, "exchange");
  const returnFee = getSimpleFee(def, "return");
  const anyFee = exchangeFee.enabled || returnFee.enabled;

  return (
    <div>
      <SectionHeading
        title="Fees"
        description="Comfort exchange and restocking fees. No fee is charged by default."
      />
      <IssueLines
        errors={[...fe(props, "fees"), ...fe(props, "fees.tiered")]}
        warnings={[...fw(props, "fees"), ...fw(props, "fees.tiered")]}
      />
      {f.tiered ? (
        <p className="rounded-md border border-amber-200 bg-amber-50 p-3 text-sm text-amber-800">
          This policy uses a tiered fee schedule. The schedule builder is coming
          in a later update — until then the tiered schedule is preserved as-is.
        </p>
      ) : (
        <div className="space-y-4">
          {x.allowed && (
            <SimpleFeeFields
              props={props}
              kind="exchange"
              label="Charge an exchange fee"
              anchor="fees.exchange_schedule"
            />
          )}
          {(r.allowed || r.exception_allowed) && (
            <SimpleFeeFields
              props={props}
              kind="return"
              label="Charge a return (restocking) fee"
              anchor="fees.return_schedule"
            />
          )}
          {!x.allowed && !r.allowed && !r.exception_allowed && (
            <p className="text-sm text-slate-500">
              No exchanges or returns are enabled, so there are no fees to
              configure.
            </p>
          )}
          {anyFee && (
            <>
              <Sel
                label="Calculate percentage fees on"
                value={f.basis}
                options={[
                  {
                    value: "NET_SELLING_PRICE" as const,
                    label: "Net selling price (after discounts)",
                  },
                  {
                    value: "PRE_DISCOUNT_SELLING_PRICE" as const,
                    label: "Pre-discount selling price",
                  },
                ]}
                disabled={disabled}
                future={future}
                errors={fe(props, "fees.basis")}
                warnings={fw(props, "fees.basis")}
                onChange={(v) => setField(props, "fees.basis", v)}
              />
              <Toggle
                label="Allow fee waivers or reductions by exception"
                checked={f.waiver_allowed}
                disabled={disabled}
                future={future}
                errors={fe(props, "fees.waiver_allowed")}
                warnings={fw(props, "fees.waiver_allowed")}
                onChange={(v) => setField(props, "fees.waiver_allowed", v)}
              />
            </>
          )}
        </div>
      )}
    </div>
  );
}

// --- 6. Protector -------------------------------------------------------------

export interface IdName {
  id: string;
  label: string;
  sublabel?: string;
}

// Checkbox list for the (small) category list.
function CategoryPick({
  options,
  selected,
  disabled,
  onChange,
}: {
  options: IdName[];
  selected: string[];
  disabled: boolean;
  onChange: (ids: string[]) => void;
}) {
  if (options.length === 0) {
    return (
      <p className="text-sm text-slate-500">
        No product categories yet — add them under Products first.
      </p>
    );
  }
  return (
    <div className="max-h-48 space-y-1 overflow-y-auto rounded-md border border-slate-200 p-2">
      {options.map((o) => {
        const checked = selected.includes(o.id);
        return (
          <label
            key={o.id}
            className={`flex items-center gap-2 rounded px-2 py-1.5 text-sm ${
              disabled ? "opacity-60" : "cursor-pointer hover:bg-slate-50"
            }`}
          >
            <input
              type="checkbox"
              checked={checked}
              disabled={disabled}
              onChange={() =>
                onChange(
                  checked
                    ? selected.filter((id) => id !== o.id)
                    : [...selected, o.id]
                )
              }
              className="h-4 w-4 rounded border-slate-300 text-brand-600"
            />
            {o.label}
          </label>
        );
      })}
    </div>
  );
}

// Searchable multi-pick for products — catalogs can be large.
function ProductPick({
  options,
  selected,
  disabled,
  onChange,
}: {
  options: IdName[];
  selected: string[];
  disabled: boolean;
  onChange: (ids: string[]) => void;
}) {
  const [query, setQuery] = useState("");
  const byId = new Map(options.map((o) => [o.id, o]));
  const selectedItems = selected
    .map((id) => byId.get(id))
    .filter((o): o is IdName => Boolean(o));

  const q = query.trim().toLowerCase();
  const matches = q
    ? options
        .filter((o) => !selected.includes(o.id))
        .filter((o) => o.label.toLowerCase().includes(q))
        .slice(0, 20)
    : [];

  return (
    <div>
      {selectedItems.length > 0 && (
        <div className="mb-2 flex flex-wrap gap-1.5">
          {selectedItems.map((o) => (
            <span
              key={o.id}
              className="inline-flex items-center gap-1 rounded-full bg-brand-50 px-2.5 py-1 text-xs font-medium text-brand-700"
            >
              {o.label}
              {!disabled && (
                <button
                  type="button"
                  aria-label={`Remove ${o.label}`}
                  onClick={() => onChange(selected.filter((id) => id !== o.id))}
                  className="text-brand-400 hover:text-brand-700"
                >
                  <X className="h-3 w-3" />
                </button>
              )}
            </span>
          ))}
        </div>
      )}
      {!disabled && (
        <>
          <input
            type="text"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search products to add…"
            className={inputCls}
          />
          {matches.length > 0 && (
            <div className="mt-1 max-h-44 overflow-y-auto rounded-md border border-slate-200">
              {matches.map((o) => (
                <button
                  key={o.id}
                  type="button"
                  onClick={() => {
                    onChange([...selected, o.id]);
                    setQuery("");
                  }}
                  className="block w-full px-3 py-2 text-left text-sm hover:bg-brand-50"
                >
                  {o.label}
                  {o.sublabel && (
                    <span className="ml-1 text-xs text-slate-400">
                      {o.sublabel}
                    </span>
                  )}
                </button>
              ))}
            </div>
          )}
          {q && matches.length === 0 && (
            <p className="mt-1 text-xs text-slate-400">No matching products.</p>
          )}
        </>
      )}
    </div>
  );
}

export function ProtectorSection(
  props: SectionProps & { categories: IdName[]; products: IdName[] }
) {
  const { def, disabled, categories, products } = props;
  const p = def.base.protector;
  const t = def.base.trial;
  const future = !disabled;

  return (
    <div>
      <SectionHeading
        title="Protector"
        description="Require a qualifying mattress protector for exchanges and returns."
      />
      <div className="space-y-4">
        <Toggle
          label="Require a mattress protector for exchanges and returns"
          checked={p.required}
          disabled={disabled || !t.enabled}
          future={future}
          errors={fe(props, "protector.required")}
          warnings={fw(props, "protector.required")}
          onChange={(v) => setField(props, "protector.required", v)}
        />
        {p.required && t.enabled && (
          <>
            <Field
              label="Protector categories that count"
              help="Pick at least one."
              future={future}
              errors={fe(props, "protector.qualifying_category_ids")}
              warnings={fw(props, "protector.qualifying_category_ids")}
            >
              <CategoryPick
                options={categories}
                selected={p.qualifying_category_ids}
                disabled={disabled}
                onChange={(v) =>
                  setField(props, "protector.qualifying_category_ids", v)
                }
              />
            </Field>
            <Field
              label="Also count these specific products"
              help="Optional — for protectors that aren't in a qualifying category."
              future={future}
              errors={fe(props, "protector.qualifying_product_ids")}
              warnings={fw(props, "protector.qualifying_product_ids")}
            >
              <ProductPick
                options={products}
                selected={p.qualifying_product_ids}
                disabled={disabled}
                onChange={(v) =>
                  setField(props, "protector.qualifying_product_ids", v)
                }
              />
            </Field>
            <NumField
              label="Protector can be added up to this many days after delivery"
              help="0 = must be on the sale before delivery."
              value={p.purchase_window_days}
              min={0}
              max={120}
              disabled={disabled}
              future={future}
              suffix="days"
              errors={fe(props, "protector.purchase_window_days")}
              warnings={fw(props, "protector.purchase_window_days")}
              onCommit={(v) =>
                setField(props, "protector.purchase_window_days", v)
              }
            />
            <div className="grid gap-4 sm:grid-cols-2">
              <Sel
                label="If the protector is missing"
                value={p.missing_behavior}
                options={[
                  {
                    value: "BLOCK_WITH_OVERRIDE" as const,
                    label: "Block — only permitted roles can override",
                  },
                  {
                    value: "APPROVAL_REQUIRED" as const,
                    label: "Require an approved exception",
                  },
                  { value: "WARN_ONLY" as const, label: "Warn, but allow" },
                ]}
                disabled={disabled}
                future={future}
                errors={fe(props, "protector.missing_behavior")}
                warnings={fw(props, "protector.missing_behavior")}
                onChange={(v) =>
                  setField(props, "protector.missing_behavior", v)
                }
              />
              <Sel
                label="Requirement applies to"
                value={p.applies_to}
                options={[
                  {
                    value: "EXCHANGE_AND_RETURN" as const,
                    label: "Exchanges and returns",
                  },
                  { value: "EXCHANGE_ONLY" as const, label: "Exchanges only" },
                  { value: "RETURN_ONLY" as const, label: "Returns only" },
                ]}
                disabled={disabled}
                future={future}
                errors={fe(props, "protector.applies_to")}
                warnings={fw(props, "protector.applies_to")}
                onChange={(v) => setField(props, "protector.applies_to", v)}
              />
            </div>
            <Sel
              label="A split king pair needs"
              value={p.split_king_units}
              options={[
                { value: "ONE" as const, label: "One protector for the pair" },
                { value: "TWO" as const, label: "One protector per side" },
              ]}
              disabled={disabled}
              future={future}
              errors={fe(props, "protector.split_king_units")}
              warnings={fw(props, "protector.split_king_units")}
              onChange={(v) =>
                setField(props, "protector.split_king_units", v)
              }
            />
          </>
        )}
      </div>
    </div>
  );
}

// --- 8. Exception rules (the policy-field half of Approvals & Exceptions) ----

export function ExceptionRulesSection(props: SectionProps) {
  const { def, disabled } = props;
  const e = def.base.exceptions;
  const future = !disabled;

  return (
    <div className="mt-8 border-t border-slate-200 pt-6">
      <h3 className="text-base font-semibold text-slate-900">Exception rules</h3>
      <p className="mt-1 text-sm text-slate-500">
        Part of the policy definition — changes go into the draft and apply to
        future sales only.
      </p>
      <div className="mt-4 space-y-4">
        <NumField
          label="An approval can be used for this many days"
          value={e.approval_valid_days}
          min={1}
          max={90}
          disabled={disabled}
          future={future}
          suffix="days"
          errors={fe(props, "exceptions.approval_valid_days")}
          warnings={fw(props, "exceptions.approval_valid_days")}
          onCommit={(v) => setField(props, "exceptions.approval_valid_days", v)}
        />
        <Toggle
          label="Require a reason code"
          checked={e.reason_required}
          disabled={disabled}
          future={future}
          errors={fe(props, "exceptions.reason_required")}
          warnings={fw(props, "exceptions.reason_required")}
          onChange={(v) => setField(props, "exceptions.reason_required", v)}
        />
        <Toggle
          label="Allow photo/document attachments"
          checked={e.attachments_allowed}
          disabled={disabled}
          future={future}
          errors={fe(props, "exceptions.attachments_allowed")}
          warnings={fw(props, "exceptions.attachments_allowed")}
          onChange={(v) =>
            setField(props, "exceptions.attachments_allowed", v)
          }
        />
        <Toggle
          label="Self-approvals require a written note"
          checked={e.self_approval_note_required}
          disabled={disabled}
          future={future}
          errors={fe(props, "exceptions.self_approval_note_required")}
          warnings={fw(props, "exceptions.self_approval_note_required")}
          onChange={(v) =>
            setField(props, "exceptions.self_approval_note_required", v)
          }
        />
      </div>
    </div>
  );
}
