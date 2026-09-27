"use client";

import { useEffect, useState } from "react";
import {
  fetchDepositPolicy,
  upsertDepositPolicy,
  type DepositPolicy,
} from "@/lib/journeys/deposit";
import { fetchCurrentEmployee } from "@/lib/journeys/queries";
import { createClient } from "@/lib/supabase/client";

const POLICY_OPTIONS: { value: DepositPolicy["policy_type"]; label: string }[] = [
  { value: "none", label: "No required deposit" },
  { value: "fixed_amount", label: "Fixed dollar amount" },
  { value: "percentage", label: "Percentage of order total" },
  { value: "greater_of_fixed_or_percentage", label: "Greater of fixed or percentage" },
];

export default function DepositPolicyForm() {
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [companyId, setCompanyId] = useState<string | null>(null);
  const [policy, setPolicy] = useState<DepositPolicy["policy_type"]>("none");
  const [fixed, setFixed] = useState<string>("");
  const [percentage, setPercentage] = useState<string>("");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const supabase = createClient();
    Promise.all([fetchCurrentEmployee(), fetchDepositPolicy()]).then(
      ([employee, saved]) => {
        if (!employee?.home_store_id) {
          setError("Your employee record has no assigned store.");
          setLoading(false);
          return;
        }

        supabase
          .from("stores")
          .select("company_id")
          .eq("id", employee.home_store_id)
          .maybeSingle()
          .then(({ data: store, error: storeError }) => {
            if (storeError || !store?.company_id) {
              setError("Could not determine your company.");
            } else {
              setCompanyId(store.company_id);
            }
            setLoading(false);
          });

        setPolicy(saved?.policy_type ?? "none");
        setFixed(saved?.fixed_amount?.toString() ?? "");
        setPercentage(saved?.percentage?.toString() ?? "");
      }
    );
  }, []);

  async function handleSave(e: React.FormEvent) {
    e.preventDefault();
    if (!companyId) {
      setError("Could not determine your company. Please refresh or contact support.");
      return;
    }
    setSaving(true);
    setError(null);

    try {
      await upsertDepositPolicy({
        company_id: companyId,
        policy_type: policy,
        fixed_amount: policy !== "percentage" ? parseFloat(fixed) || null : null,
        percentage:
          policy !== "fixed_amount" ? parseFloat(percentage) || null : null,
      });
    } catch (err: any) {
      setError(err.message ?? "Failed to save deposit policy");
    } finally {
      setSaving(false);
    }
  }

  if (loading) {
    return <p className="p-8 text-sm text-slate-500">Loading…</p>;
  }

  return (
    <main className="min-h-screen bg-slate-50 p-8">
      <div className="mx-auto max-w-2xl">
        <h1 className="mb-6 text-2xl font-semibold text-slate-900">
          Deposit Policy
        </h1>

        {error && (
          <p className="mb-4 rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-700">
            {error}
          </p>
        )}

        <form onSubmit={handleSave} className="space-y-4 rounded-lg border border-slate-200 bg-white p-6 shadow-sm">
          <div>
            <label className="mb-1 block text-sm font-medium text-slate-700">
              Required deposit
            </label>
            <select
              value={policy}
              onChange={(e) => setPolicy(e.target.value as DepositPolicy["policy_type"])}
              className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
            >
              {POLICY_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </select>
          </div>

          {policy !== "none" && (
            <div className="grid grid-cols-2 gap-4">
              {policy !== "percentage" && (
                <div>
                  <label className="mb-1 block text-sm font-medium text-slate-700">
                    Fixed amount ($)
                  </label>
                  <input
                    type="number"
                    step="0.01"
                    value={fixed}
                    onChange={(e) => setFixed(e.target.value)}
                    className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                  />
                </div>
              )}
              {policy !== "fixed_amount" && (
                <div>
                  <label className="mb-1 block text-sm font-medium text-slate-700">
                    Percentage (%)
                  </label>
                  <input
                    type="number"
                    step="0.01"
                    value={percentage}
                    onChange={(e) => setPercentage(e.target.value)}
                    className="w-full rounded-md border border-slate-300 px-3 py-2 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
                  />
                </div>
              )}
            </div>
          )}

          <div className="flex justify-end">
            <button
              type="submit"
              disabled={saving}
              className="rounded-md bg-brand-600 px-4 py-2 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
            >
              {saving ? "Saving…" : "Save Policy"}
            </button>
          </div>
        </form>
      </div>
    </main>
  );
}
