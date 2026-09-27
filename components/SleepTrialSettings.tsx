"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import {
  fetchCurrentEmployee,
  type Employee,
} from "@/lib/journeys/queries";
import { fetchRolePermissionGrants } from "@/lib/sleepTrial/permissions";
import {
  discardSleepTrialDraft,
  fetchManagePolicyPermission,
  fetchSleepTrialPolicy,
  publishSleepTrialDraft,
  saveSleepTrialDraft,
  type SleepTrialPolicyState,
} from "@/lib/sleepTrial/policy";
import {
  formatIssue,
  generateSummary,
  type SleepTrialDefinition,
  type ValidationResult,
} from "@/lib/sleepTrial/definition";
import Modal from "@/components/Modal";
import SleepTrialPermissionsGrid from "@/components/SleepTrialPermissionsGrid";
import {
  ExceptionRulesSection,
  ExchangesSection,
  FeesSection,
  OverviewSection,
  ProtectorSection,
  ReturnsSection,
  TrialTermsSection,
  type IdName,
} from "@/components/SleepTrialPolicySections";

const SECTIONS = [
  "Overview",
  "Trial Terms",
  "Exchanges",
  "Returns",
  "Fees",
  "Protector",
  "Product Rules",
  "Approvals & Exceptions",
  "Customer Communication",
];

// Active in ST-2: Overview, 2/3/4/6, Fees (simple), and Approvals & Exceptions.
// Product Rules and Customer Communication arrive in later phases.
const IMPLEMENTED = new Set([
  "Overview",
  "Trial Terms",
  "Exchanges",
  "Returns",
  "Fees",
  "Protector",
  "Approvals & Exceptions",
]);

export default function SleepTrialSettings() {
  const [employee, setEmployee] = useState<Employee | null>(null);
  const [grants, setGrants] = useState<Set<string> | null>(null);
  const [grantsInstalled, setGrantsInstalled] = useState(true);
  const [policy, setPolicy] = useState<SleepTrialPolicyState | null>(null);
  const [policyInstalled, setPolicyInstalled] = useState(true);
  const [canManage, setCanManage] = useState(false);
  const [working, setWorking] = useState<SleepTrialDefinition | null>(null);
  const [draftExists, setDraftExists] = useState(false);
  const [categories, setCategories] = useState<IdName[]>([]);
  const [products, setProducts] = useState<IdName[]>([]);
  const [section, setSection] = useState("Overview");
  const [validation, setValidation] = useState<ValidationResult | null>(null);
  const [saving, setSaving] = useState(false);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [publishOpen, setPublishOpen] = useState(false);
  const [publishNote, setPublishNote] = useState("");
  const [publishing, setPublishing] = useState(false);
  const [publishError, setPublishError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);

  // Draft saves are serialized: rapid field edits queue the latest definition
  // and writes happen one at a time so responses can't land out of order.
  const savingRef = useRef(false);
  const pendingRef = useRef<SleepTrialDefinition | null>(null);

  const load = useCallback(async () => {
    const [emp, g, pol, can] = await Promise.all([
      fetchCurrentEmployee(),
      fetchRolePermissionGrants(),
      fetchSleepTrialPolicy(),
      fetchManagePolicyPermission(),
    ]);
    setEmployee(emp);
    if (g === null) {
      setGrantsInstalled(false);
    } else {
      setGrants(g);
      setGrantsInstalled(true);
    }
    if (pol === null) {
      setPolicyInstalled(false);
    } else {
      setPolicyInstalled(true);
      setPolicy(pol);
      setDraftExists(pol.draft !== null);
      setWorking(pol.draft?.definition ?? pol.published?.definition ?? null);
    }
    // Fall back to the role check when the permission RPC isn't there yet.
    setCanManage(
      can === true || (can === null && (emp?.role === "owner" || emp?.role === "admin"))
    );

    const supabase = createClient();
    const [cats, prods] = await Promise.all([
      (supabase as any)
        .from("product_categories")
        .select("id, name")
        .order("name"),
      (supabase as any)
        .from("products")
        .select("id, item_name, brand, sku")
        .order("item_name")
        .limit(1000),
    ]);
    setCategories(
      ((cats.data ?? []) as { id: string; name: string }[]).map((c) => ({
        id: c.id,
        label: c.name,
      }))
    );
    setProducts(
      (
        (prods.data ?? []) as {
          id: string;
          item_name: string;
          brand: string | null;
          sku: string;
        }[]
      ).map((p) => ({
        id: p.id,
        label: p.item_name,
        sublabel: [p.brand, p.sku].filter(Boolean).join(" · "),
      }))
    );

    setLoading(false);
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  async function flushSaves() {
    if (savingRef.current) return;
    savingRef.current = true;
    setSaving(true);
    while (pendingRef.current) {
      const def = pendingRef.current;
      pendingRef.current = null;
      try {
        const result = await saveSleepTrialDraft(def);
        setValidation(result);
        setDraftExists(true);
        setSaveError(null);
      } catch (err) {
        setSaveError(err instanceof Error ? err.message : "Save failed");
      }
    }
    savingRef.current = false;
    setSaving(false);
  }

  // Every field edit flows through here: update local state, then persist the
  // whole definition to the single draft row.
  function commit(next: SleepTrialDefinition) {
    setWorking(next);
    if (!canManage) return;
    pendingRef.current = next;
    void flushSaves();
  }

  async function discard() {
    if (!window.confirm("Discard the draft? The published version stays active."))
      return;
    try {
      await discardSleepTrialDraft();
      setPublishNote("");
      await load();
      setValidation(null);
    } catch (err) {
      setSaveError(err instanceof Error ? err.message : "Discard failed");
    }
  }

  async function publish() {
    if (!working) return;
    setPublishing(true);
    setPublishError(null);
    try {
      await publishSleepTrialDraft(generateSummary(working), publishNote.trim());
      setPublishOpen(false);
      setPublishNote("");
      setValidation(null);
      await load();
    } catch (err) {
      setPublishError(err instanceof Error ? err.message : "Publish failed");
    } finally {
      setPublishing(false);
    }
  }

  if (loading) {
    return (
      <main className="min-h-screen bg-slate-50 p-8">
        <div className="mx-auto max-w-5xl text-slate-500">Loading…</div>
      </main>
    );
  }

  const errors = validation?.errors ?? [];
  const warnings = validation?.warnings ?? [];
  const published = policy?.published ?? null;

  return (
    <main className="min-h-screen bg-slate-50 p-8">
      <div className="mx-auto max-w-5xl">
        <div className="flex flex-wrap items-start justify-between gap-4">
          <div>
            <h1 className="text-2xl font-semibold text-slate-900">
              Sleep Trial Policy
            </h1>
            <p className="mt-1 text-sm text-slate-500">
              {published
                ? `Currently active: Version ${published.version_number}, published ${new Date(
                    published.published_at ?? published.created_at
                  ).toLocaleDateString("en-US", {
                    month: "short",
                    day: "numeric",
                    year: "numeric",
                  })}${policy?.publisherName ? ` by ${policy.publisherName}` : ""}`
                : "No active policy yet."}
            </p>
          </div>
          {policyInstalled && (
            <div className="flex items-center gap-2">
              {draftExists && (
                <span className="rounded-full bg-amber-100 px-3 py-1 text-xs font-medium text-amber-800">
                  Draft has unsaved changes
                </span>
              )}
              <button
                type="button"
                disabled
                title="Coming in a later update"
                className="rounded-md border border-slate-300 px-3 py-1.5 text-sm text-slate-400"
              >
                Test a Scenario
              </button>
              {canManage && draftExists && (
                <button
                  type="button"
                  onClick={discard}
                  className="rounded-md border border-slate-300 px-3 py-1.5 text-sm text-slate-600 hover:bg-slate-100"
                >
                  Discard draft
                </button>
              )}
              {canManage && (
                <button
                  type="button"
                  disabled={!draftExists || saving}
                  onClick={() => setPublishOpen(true)}
                  className="rounded-md bg-brand-600 px-4 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:cursor-not-allowed disabled:opacity-50"
                >
                  Publish
                </button>
              )}
            </div>
          )}
        </div>

        {!policyInstalled && (
          <div className="mt-4 rounded-md border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800">
            The Sleep Trial policy model is not installed yet. Apply migration
            067_sleep_trial_policy.sql, then reload this page. (The Approvals
            &amp; Exceptions grid below still works if 066 is applied.)
          </div>
        )}

        {policyInstalled && saving && (
          <p className="mt-2 text-xs text-slate-400">Saving draft…</p>
        )}
        {saveError && (
          <p className="mt-2 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
            {saveError}
          </p>
        )}

        <div className="mt-6 flex overflow-hidden rounded-lg border border-slate-200 bg-white shadow-sm">
          <nav className="w-56 shrink-0 border-r border-slate-200 py-3">
            <ol className="space-y-0.5">
              {SECTIONS.map((s, i) => (
                <li key={s}>
                  <button
                    onClick={() => setSection(s)}
                    className={`flex w-full items-center gap-2 px-4 py-2 text-left text-sm ${
                      section === s
                        ? "bg-brand-50 font-medium text-brand-700"
                        : "text-slate-600 hover:bg-slate-50"
                    }`}
                  >
                    <span className="w-4 text-xs text-slate-400">{i + 1}.</span>
                    {s}
                  </button>
                </li>
              ))}
            </ol>
          </nav>

          <div className="min-w-0 flex-1 p-6">
            {!IMPLEMENTED.has(section) ? (
              <div className="flex h-full items-center justify-center">
                <p className="text-sm text-slate-400">
                  Coming in the next update.
                </p>
              </div>
            ) : !policyInstalled ? (
              section === "Approvals & Exceptions" ? (
                grantsInstalled && grants ? (
                  <SleepTrialPermissionsGrid
                    grants={grants}
                    canEdit={
                      employee?.role === "owner" || employee?.role === "admin"
                    }
                    onGrantsChange={setGrants}
                  />
                ) : (
                  <div className="rounded-md border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800">
                    Sleep Trial foundations are not installed yet. Apply
                    migration 066_sleep_trial_foundations.sql, then reload this
                    page.
                  </div>
                )
              ) : (
                <div className="flex h-full items-center justify-center">
                  <p className="text-sm text-slate-400">
                    Available after migration 067 is applied.
                  </p>
                </div>
              )
            ) : section === "Overview" ? (
              <OverviewSection
                state={{
                  published,
                  draft: policy?.draft ?? null,
                  publisherName: policy?.publisherName ?? null,
                }}
                canManage={canManage}
                onTemplate={commit}
              />
            ) : !working ? (
              <div className="flex h-full items-center justify-center">
                <p className="text-sm text-slate-400">
                  No draft yet — start from a template on the Overview tab.
                </p>
              </div>
            ) : (
              <PolicySection
                section={section}
                def={working}
                disabled={!canManage}
                update={commit}
                categories={categories}
                products={products}
                grants={grants}
                grantsInstalled={grantsInstalled}
                canEditGrants={
                  employee?.role === "owner" || employee?.role === "admin"
                }
                onGrantsChange={setGrants}
                errors={errors}
                warnings={warnings}
              />
            )}
          </div>
        </div>
      </div>

      {publishOpen && working && (
        <Modal onClose={() => setPublishOpen(false)} saving={publishing}>
          <div className="w-full max-w-lg rounded-lg bg-white p-6 shadow-xl">
            <h2 className="text-lg font-semibold text-slate-900">
              Publish Sleep Trial Policy
            </h2>
            <p className="mt-2 text-sm text-slate-600">
              This applies to sales made on or after today. Existing customers
              keep the terms they were sold under.
            </p>

            {errors.length > 0 && (
              <div className="mt-3 rounded-md border border-red-200 bg-red-50 p-3">
                <p className="text-sm font-medium text-red-800">
                  Fix these before publishing:
                </p>
                <ul className="mt-1 list-inside list-disc text-sm text-red-700">
                  {errors.map((e, i) => (
                    <li key={i}>{formatIssue(e)}</li>
                  ))}
                </ul>
              </div>
            )}

            {publishError && (
              <p className="mt-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
                {publishError}
              </p>
            )}

            <div className="mt-4">
              <label className="mb-1 block text-sm font-medium text-slate-700">
                Publish note (optional)
              </label>
              <textarea
                value={publishNote}
                onChange={(e) => setPublishNote(e.target.value)}
                rows={2}
                placeholder="Why this change is being made"
                className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
              />
            </div>

            <div className="mt-5 flex justify-end gap-2">
              <button
                type="button"
                onClick={() => setPublishOpen(false)}
                disabled={publishing}
                className="rounded-md border border-slate-300 px-4 py-2 text-sm text-slate-600 hover:bg-slate-50"
              >
                Cancel
              </button>
              <button
                type="button"
                onClick={publish}
                disabled={publishing || saving || errors.length > 0}
                className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:cursor-not-allowed disabled:opacity-50"
              >
                {publishing ? "Publishing…" : "Publish"}
              </button>
            </div>
          </div>
        </Modal>
      )}
    </main>
  );
}

function PolicySection({
  section,
  def,
  disabled,
  update,
  categories,
  products,
  grants,
  grantsInstalled,
  canEditGrants,
  onGrantsChange,
  errors,
  warnings,
}: {
  section: string;
  def: SleepTrialDefinition;
  disabled: boolean;
  update: (d: SleepTrialDefinition) => void;
  categories: IdName[];
  products: IdName[];
  grants: Set<string> | null;
  grantsInstalled: boolean;
  canEditGrants: boolean;
  onGrantsChange: (g: Set<string>) => void;
  errors: { path: string; message: string }[];
  warnings: { path: string; message: string }[];
}) {
  const issueProps = { errors, warnings };

  switch (section) {
    case "Trial Terms":
      return (
        <TrialTermsSection
          def={def}
          disabled={disabled}
          update={update}
          {...issueProps}
        />
      );
    case "Exchanges":
      return (
        <ExchangesSection
          def={def}
          disabled={disabled}
          update={update}
          {...issueProps}
        />
      );
    case "Returns":
      return (
        <ReturnsSection
          def={def}
          disabled={disabled}
          update={update}
          {...issueProps}
        />
      );
    case "Fees":
      return (
        <FeesSection
          def={def}
          disabled={disabled}
          update={update}
          {...issueProps}
        />
      );
    case "Protector":
      return (
        <ProtectorSection
          def={def}
          disabled={disabled}
          update={update}
          categories={categories}
          products={products}
          {...issueProps}
        />
      );
    case "Approvals & Exceptions":
      return (
        <>
          {grantsInstalled && grants ? (
            <SleepTrialPermissionsGrid
              grants={grants}
              canEdit={canEditGrants}
              onGrantsChange={onGrantsChange}
            />
          ) : (
            <div className="rounded-md border border-amber-200 bg-amber-50 p-4 text-sm text-amber-800">
              Sleep Trial foundations are not installed yet. Apply migration
              066_sleep_trial_foundations.sql, then reload this page.
            </div>
          )}
          <ExceptionRulesSection
            def={def}
            disabled={disabled}
            update={update}
            {...issueProps}
          />
        </>
      );
    default:
      return null;
  }
}
