"use client";

import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import TimezonePicker from "@/components/TimezonePicker";
import {
  fetchCurrentEmployee,
  fetchStores,
  type Employee,
  type Store,
} from "@/lib/journeys/queries";

type CompanySettings = {
  business_timezone: string;
  managers_can_adjust_inventory: boolean;
  managers_can_edit_products: boolean;
  managers_can_view_physical_inventory: boolean;
  managers_can_manage_par_levels: boolean;
  restock_generation_mode: "automatic" | "manual";
};

export default function CompanySettingsForm() {
  const [employee, setEmployee] = useState<Employee | null>(null);
  const [stores, setStores] = useState<Store[]>([]);
  const [companyId, setCompanyId] = useState<string | null>(null);
  const [settings, setSettings] = useState<CompanySettings>({
    business_timezone: "America/Denver",
    managers_can_adjust_inventory: false,
    managers_can_edit_products: false,
    managers_can_view_physical_inventory: false,
    managers_can_manage_par_levels: false,
    restock_generation_mode: "automatic",
  });
  const [loading, setLoading] = useState(true);
  // business_timezone arrives with migration 066; until it exists the
  // timezone field stays hidden instead of breaking the page.
  const [timezoneSupported, setTimezoneSupported] = useState(false);
  const [saving, setSaving] = useState<keyof CompanySettings | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    Promise.all([fetchCurrentEmployee(), fetchStores()]).then(([e, s]) => {
      setEmployee(e);
      setStores(s);
      const company = s.find((st) => st.id === e?.home_store_id)?.company_id;
      setCompanyId(company ?? null);
      loadSettings(company);
    });
  }, []);

  async function loadSettings(company: string | undefined) {
    if (!company) {
      setLoading(false);
      return;
    }
    const supabase = createClient();
    const { data, error } = await (supabase as any)
      .from("companies")
      .select(
        "managers_can_adjust_inventory, managers_can_edit_products, managers_can_view_physical_inventory, managers_can_manage_par_levels, restock_generation_mode"
      )
      .eq("id", company)
      .single();

    if (error) {
      setError(error.message);
    } else if (data) {
      setSettings((prev) => ({
        business_timezone: prev.business_timezone,
        managers_can_adjust_inventory: data.managers_can_adjust_inventory ?? false,
        managers_can_edit_products: data.managers_can_edit_products ?? false,
        managers_can_view_physical_inventory:
          data.managers_can_view_physical_inventory ?? false,
        managers_can_manage_par_levels: data.managers_can_manage_par_levels ?? false,
        restock_generation_mode: data.restock_generation_mode ?? "automatic",
      }));
    }

    const { data: tzRow, error: tzError } = await (supabase as any)
      .from("companies")
      .select("business_timezone")
      .eq("id", company)
      .single();

    if (!tzError) {
      setTimezoneSupported(true);
      if (tzRow?.business_timezone) {
        setSettings((prev) => ({
          ...prev,
          business_timezone: tzRow.business_timezone,
        }));
      }
    }

    setLoading(false);
  }

  async function handleSave(
    key: keyof CompanySettings,
    next: CompanySettings[keyof CompanySettings]
  ) {
    if (!companyId) return;
    setSaving(key);
    setError(null);

    const supabase = createClient();
    const { error } = await (supabase as any)
      .from("companies")
      .update({ [key]: next })
      .eq("id", companyId);

    setSaving(null);

    if (error) {
      setError(error.message);
    } else {
      setSettings((prev) => ({ ...prev, [key]: next }));
    }
  }

  if (loading) {
    return (
      <div className="min-h-screen bg-slate-50 p-8">
        <div className="mx-auto max-w-2xl text-slate-500">Loading…</div>
      </div>
    );
  }

  const renderCheckbox = (
    key: Exclude<
      keyof CompanySettings,
      "restock_generation_mode" | "business_timezone"
    >,
    id: string,
    label: string
  ) => (
    <div className="flex items-start gap-3">
      <input
        id={id}
        type="checkbox"
        checked={settings[key]}
        disabled={saving === key}
        onChange={(e) => handleSave(key, e.target.checked)}
        className="mt-1 h-4 w-4 rounded border-slate-300 text-brand-600 focus:ring-brand-500"
      />
      <label
        htmlFor={id}
        className="block text-sm font-medium text-slate-700"
      >
        {label}
      </label>
    </div>
  );

  return (
    <main className="min-h-screen bg-slate-50 p-8">
      <div className="mx-auto max-w-2xl rounded-lg border border-slate-200 bg-white p-6 shadow-sm">
        <h1 className="text-2xl font-semibold text-slate-900">Company Settings</h1>

        <div className="mt-6 space-y-4">
          {timezoneSupported && (
            <div className="border-b border-slate-200 pb-4">
              <label
                htmlFor="company-timezone"
                className="block text-sm font-medium text-slate-700"
              >
                Timezone
              </label>
              <div className="mt-2">
                <TimezonePicker
                  id="company-timezone"
                  value={settings.business_timezone}
                  disabled={saving === "business_timezone"}
                  onChange={(tz) => {
                    if (tz) handleSave("business_timezone", tz);
                  }}
                />
              </div>
              <p className="mt-1 text-xs text-slate-500">
                Business dates (for example sleep trial nights) are calculated
                in this timezone. Individual stores can override it in Store
                Management.
              </p>
            </div>
          )}
          {renderCheckbox(
            "managers_can_adjust_inventory",
            "managers-can-adjust-inventory",
            "Allow managers to adjust inventory quantities"
          )}
          {renderCheckbox(
            "managers_can_edit_products",
            "managers-can-edit-products",
            "Allow managers to edit product pricing and details"
          )}
          {renderCheckbox(
            "managers_can_view_physical_inventory",
            "managers-can-view-physical-inventory",
            "Allow managers to view physical on-hand quantities"
          )}
          {renderCheckbox(
            "managers_can_manage_par_levels",
            "managers-can-manage-par-levels",
            "Allow managers to manage par levels"
          )}

          <div className="border-t border-slate-200 pt-4">
            <label
              htmlFor="restock-generation-mode"
              className="block text-sm font-medium text-slate-700"
            >
              Restock requests
            </label>
            <select
              id="restock-generation-mode"
              value={settings.restock_generation_mode}
              disabled={saving === "restock_generation_mode"}
              onChange={(e) =>
                handleSave(
                  "restock_generation_mode",
                  e.target.value as "automatic" | "manual"
                )
              }
              className="mt-2 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm"
            >
              <option value="automatic">
                Automatically generate transfer requests when a store hits its reorder point
              </option>
              <option value="manual">
                Require a manager to review and request restocks manually
              </option>
            </select>
          </div>
        </div>

        {error && (
          <p className="mt-4 text-sm text-red-600">{error}</p>
        )}
      </div>
    </main>
  );
}
