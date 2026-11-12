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
import {
  fetchRolePermissionGrants,
  grantKey,
  PERMISSION_ROLES,
  setRolePermission,
} from "@/lib/sleepTrial/permissions";
import {
  fetchCompanyWeekStart,
  fetchDeliveryCutoff,
  fetchDeliveryDaySettings,
  setCompanyWeekStart,
  setDeliveryDaySettings,
  type DeliverySettings,
} from "@/lib/delivery/queries";
import {
  minutesToLabel,
  minutesToTimeStr,
  timeStrToMinutes,
} from "@/lib/delivery/windows";
import {
  fetchDeliveryContactHoldDays,
  setDeliveryContactHoldDays,
} from "@/lib/delivery/contacts";

// 15-minute time choices for the delivery day fields, 12h labels.
const DAY_TIME_OPTIONS = Array.from({ length: 96 }, (_, i) => i * 15).map(
  (m) => ({ value: minutesToTimeStr(m), label: minutesToLabel(m) })
);

// Company-editable role grants that are not Sleep Trial scoped (plus the
// exchange/inspection keys from Exchange Builder spec Section 12); they live
// here instead of the Sleep Trial "Who can do what" grid.
const INVENTORY_PERMISSIONS = [
  {
    key: "inventory.reduce_below_committed",
    label: "Reduce stock below committed reservations",
  },
  {
    key: "sleep_trial.complete_exchange",
    label: "Complete exchanges and returns",
  },
  {
    key: "sleep_trial.void_refund",
    label: "Void exchange refunds",
  },
  {
    key: "inventory.inspect_returns",
    label: "Inspect and disposition returned mattresses",
  },
  {
    key: "inventory.manage_inspection_checklist",
    label: "Edit the returned mattress inspection checklist",
  },
];

type CompanySettings = {
  business_timezone: string;
  managers_can_adjust_inventory: boolean;
  managers_can_edit_products: boolean;
  managers_can_view_physical_inventory: boolean;
  managers_can_manage_par_levels: boolean;
  restock_generation_mode: "automatic" | "manual";
  exchange_stalled_days: number;
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
    exchange_stalled_days: 14,
  });
  const [loading, setLoading] = useState(true);
  // business_timezone arrives with migration 066; until it exists the
  // timezone field stays hidden instead of breaking the page.
  const [timezoneSupported, setTimezoneSupported] = useState(false);
  // exchange_stalled_days arrives with migration 091; same hide-until-
  // supported pattern as business_timezone.
  const [stalledSupported, setStalledSupported] = useState(false);
  const [stalledDraft, setStalledDraft] = useState("14");
  const [saving, setSaving] = useState<keyof CompanySettings | null>(null);
  const [error, setError] = useState<string | null>(null);
  // null while loading or when role_permission_grants doesn't exist yet
  const [permGrants, setPermGrants] = useState<Set<string> | null>(null);
  const [permSaving, setPermSaving] = useState<string | null>(null);
  const [permError, setPermError] = useState<string | null>(null);
  // week_start_day arrives with migration 128; hidden until it exists.
  const [weekStartSupported, setWeekStartSupported] = useState(false);
  const [weekStartDay, setWeekStartDay] = useState<1 | 7>(1);
  const [weekStartSaving, setWeekStartSaving] = useState(false);
  const [weekStartError, setWeekStartError] = useState<string | null>(null);
  // delivery_cutoff_time arrives with migration 129; hidden until the
  // read RPC exists.
  const [cutoffSupported, setCutoffSupported] = useState(false);
  const [cutoffTime, setCutoffTime] = useState("17:00");
  const [cutoffNone, setCutoffNone] = useState(false);
  // The last value the server confirmed. Unticking "No cutoff" restores
  // this into the time box (or 5:00 PM when nothing was ever saved) and
  // waits for Save — it never writes by itself.
  const [cutoffSavedTime, setCutoffSavedTime] = useState<string | null>(null);
  const [cutoffCanEdit, setCutoffCanEdit] = useState(false);
  const [cutoffSaving, setCutoffSaving] = useState(false);
  const [cutoffError, setCutoffError] = useState<string | null>(null);
  // delivery_contact_hold_days arrives with migration 134; hidden until
  // the read RPC exists. Saved only via the Save button, never on change.
  const [holdSupported, setHoldSupported] = useState(false);
  const [holdDays, setHoldDays] = useState(2);
  const [holdDraft, setHoldDraft] = useState("2");
  const [holdCanEdit, setHoldCanEdit] = useState(false);
  const [holdSaving, setHoldSaving] = useState(false);
  const [holdError, setHoldError] = useState<string | null>(null);
  // Delivery day settings (delivery_day_start/end, window hours, day
  // mode) arrive with migration 137 and read through
  // get_delivery_calendar. Saved only via the Save button.
  const [daySettings, setDaySettings] = useState<DeliverySettings | null>(null);
  const [dayStart, setDayStart] = useState("09:00");
  const [dayEnd, setDayEnd] = useState("17:00");
  const [windowChoice, setWindowChoice] = useState<"2" | "3" | "4" | "custom">("3");
  const [windowCustomDraft, setWindowCustomDraft] = useState("4");
  const [dayMode, setDayMode] = useState<"window" | "day_only">("window");
  const [daySaving, setDaySaving] = useState(false);
  const [daySaved, setDaySaved] = useState(false);
  const [dayError, setDayError] = useState<string | null>(null);

  useEffect(() => {
    Promise.all([fetchCurrentEmployee(), fetchStores()]).then(([e, s]) => {
      setEmployee(e);
      setStores(s);
      const company = s.find((st) => st.id === e?.home_store_id)?.company_id;
      setCompanyId(company ?? null);
      loadSettings(company);
    });
    fetchRolePermissionGrants().then(setPermGrants);
    fetchCompanyWeekStart().then((d) => {
      if (d === null) {
        setWeekStartSupported(false);
      } else {
        setWeekStartSupported(true);
        setWeekStartDay(d === 7 ? 7 : 1);
      }
    });
    fetchDeliveryCutoff().then((d) => {
      if (d === null) {
        setCutoffSupported(false);
      } else {
        setCutoffSupported(true);
        setCutoffCanEdit(d.can_edit);
        const none = d.cutoff_time === null;
        const time = d.cutoff_time ? d.cutoff_time.slice(0, 5) : "17:00";
        setCutoffNone(none);
        setCutoffTime(time);
        setCutoffSavedTime(d.cutoff_time ? time : null);
      }
    });
    fetchDeliveryContactHoldDays().then((d) => {
      if (d === null) {
        setHoldSupported(false);
      } else {
        setHoldSupported(true);
        setHoldCanEdit(d.can_edit);
        setHoldDays(d.hold_days);
        setHoldDraft(String(d.hold_days));
      }
    });
    fetchDeliveryDaySettings().then((d) => {
      if (d) {
        setDaySettings(d);
        setDayStart((d.delivery_day_start ?? "09:00").slice(0, 5));
        setDayEnd((d.delivery_day_end ?? "17:00").slice(0, 5));
        const hrs = d.delivery_window_hours ?? 3;
        if (hrs === 2 || hrs === 3 || hrs === 4) {
          setWindowChoice(String(hrs) as "2" | "3" | "4");
        } else {
          setWindowChoice("custom");
          setWindowCustomDraft(String(hrs));
        }
        setDayMode(d.delivery_day_mode === "day_only" ? "day_only" : "window");
      }
    });
  }, []);

  async function loadSettings(company: string | undefined) {
    setError(null);
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
        exchange_stalled_days: prev.exchange_stalled_days,
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

    const { data: stalledRow, error: stalledError } = await (supabase as any)
      .from("companies")
      .select("exchange_stalled_days")
      .eq("id", company)
      .single();

    if (!stalledError) {
      setStalledSupported(true);
      const days = stalledRow?.exchange_stalled_days;
      if (typeof days === "number" && days > 0) {
        setSettings((prev) => ({ ...prev, exchange_stalled_days: days }));
        setStalledDraft(String(days));
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

  async function changeWeekStart(day: 1 | 7) {
    if (weekStartSaving || day === weekStartDay) return;
    setWeekStartError(null);
    setWeekStartSaving(true);
    try {
      await setCompanyWeekStart(day);
      setWeekStartDay(day);
    } catch {
      setWeekStartError("Couldn't save that setting. Please try again.");
    } finally {
      setWeekStartSaving(false);
    }
  }

  // Same save path as the other company options: a direct companies
  // update under the owner/admin RLS policy. The RPC only reads.
  // Returns true on success so callers can revert drafts on failure.
  async function changeDeliveryCutoff(
    nextTime: string,
    nextNone: boolean
  ): Promise<boolean> {
    if (!companyId || cutoffSaving) return false;
    setCutoffError(null);
    setCutoffSaving(true);
    const supabase = createClient();
    const { error } = await (supabase as any)
      .from("companies")
      .update({ delivery_cutoff_time: nextNone ? null : nextTime })
      .eq("id", companyId);
    setCutoffSaving(false);
    if (error) {
      setCutoffError(error.message);
      return false;
    }
    setCutoffTime(nextTime);
    setCutoffNone(nextNone);
    setCutoffSavedTime(nextNone ? null : nextTime);
    return true;
  }

  async function changeHoldDays() {
    if (holdSaving || !holdCanEdit) return;
    const days = parseInt(holdDraft, 10);
    if (!Number.isInteger(days) || days < 0 || days > 14) {
      setHoldError("Enter a whole number from 0 to 14.");
      return;
    }
    setHoldError(null);
    setHoldSaving(true);
    try {
      await setDeliveryContactHoldDays(days);
      setHoldDays(days);
      setHoldDraft(String(days));
    } catch (e: any) {
      setHoldError(e?.message ?? "Couldn't save that setting. Please try again.");
    } finally {
      setHoldSaving(false);
    }
  }

  async function changeDaySettings() {
    if (daySaving || !canEditPermissions) return;
    let hours: number;
    if (windowChoice === "custom") {
      hours = parseInt(windowCustomDraft, 10);
      if (!Number.isInteger(hours) || hours < 1 || hours > 8) {
        setDayError("Enter a whole number from 1 to 8 for the window length.");
        return;
      }
    } else {
      hours = parseInt(windowChoice, 10);
    }
    setDayError(null);
    setDaySaving(true);
    try {
      await setDeliveryDaySettings({
        dayStart,
        dayEnd,
        windowHours: hours,
        dayMode,
      });
      setDaySaved(true);
      const fresh = await fetchDeliveryDaySettings();
      if (fresh) setDaySettings(fresh);
    } catch (e: any) {
      setDayError(e?.message ?? "Couldn't save that setting. Please try again.");
    } finally {
      setDaySaving(false);
    }
  }

  const canEditPermissions =
    employee?.role === "owner" || employee?.role === "admin";

  const dayHoursNow =
    windowChoice === "custom"
      ? parseInt(windowCustomDraft, 10)
      : parseInt(windowChoice, 10);
  const dayFormDirty =
    !!daySettings &&
    (dayStart !== (daySettings.delivery_day_start ?? "").slice(0, 5) ||
      dayEnd !== (daySettings.delivery_day_end ?? "").slice(0, 5) ||
      dayMode !==
        (daySettings.delivery_day_mode === "day_only" ? "day_only" : "window") ||
      dayHoursNow !== daySettings.delivery_window_hours);

  function permGranted(role: string, permissionKey: string): boolean {
    // Owner always holds every permission, whether or not a row exists.
    if (role === "owner") return true;
    return permGrants?.has(grantKey(role, permissionKey)) ?? false;
  }

  async function togglePermission(
    role: string,
    permissionKey: string,
    granted: boolean
  ) {
    if (!permGrants) return;
    const cell = grantKey(role, permissionKey);
    setPermSaving(cell);
    setPermError(null);

    const next = new Set(permGrants);
    if (granted) next.add(cell);
    else next.delete(cell);

    try {
      await setRolePermission(role, permissionKey, granted);
      setPermGrants(next);
    } catch (e) {
      setPermError(e instanceof Error ? e.message : "Save failed");
    } finally {
      setPermSaving(null);
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
      | "restock_generation_mode"
      | "business_timezone"
      | "exchange_stalled_days"
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
          {weekStartSupported && (
            <div className="border-b border-slate-200 pb-4">
              <span className="block text-sm font-medium text-slate-700">
                Week starts on
              </span>
              <div className="mt-2 flex gap-2">
                {([
                  { day: 7 as const, label: "Sunday" },
                  { day: 1 as const, label: "Monday" },
                ]).map((opt) => (
                  <button
                    key={opt.day}
                    type="button"
                    disabled={weekStartSaving || !canEditPermissions}
                    onClick={() => changeWeekStart(opt.day)}
                    className={`rounded-md border px-3 py-1.5 text-sm ${
                      weekStartDay === opt.day
                        ? "border-brand-600 bg-brand-600 text-white"
                        : "border-slate-300 bg-white text-slate-600 hover:bg-slate-50"
                    } disabled:opacity-50`}
                  >
                    {opt.label}
                  </button>
                ))}
              </div>
              {weekStartSaving && (
                <p className="mt-1 text-xs text-slate-400">Saving…</p>
              )}
              {weekStartError && (
                <p className="mt-1 text-xs text-red-600">{weekStartError}</p>
              )}
              <p className="mt-1 text-xs text-slate-500">
                Which day the company week begins on — calendars, reports,
                and commissions all follow it.
                {!canEditPermissions && " Only owners and admins can change this."}
              </p>
            </div>
          )}
          {cutoffSupported && (
            <div className="border-b border-slate-200 pb-4">
              <span className="block text-sm font-medium text-slate-700">
                Delivery cutoff
              </span>
              <div className="mt-2 flex items-center gap-3">
                <input
                  id="delivery-cutoff-time"
                  data-testid="delivery-cutoff-time"
                  type="time"
                  value={cutoffTime}
                  disabled={cutoffSaving || cutoffNone || !cutoffCanEdit}
                  onChange={(e) => {
                    if (e.target.value) setCutoffTime(e.target.value);
                  }}
                  className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm disabled:opacity-50"
                />
                <label className="flex items-center gap-2 text-sm text-slate-600">
                  <input
                    type="checkbox"
                    data-testid="delivery-cutoff-none"
                    checked={cutoffNone}
                    disabled={cutoffSaving || !cutoffCanEdit}
                    onChange={async (e) => {
                      const next = e.target.checked;
                      if (!next) {
                        // Unticking never saves: pre-fill the last saved
                        // time (5:00 PM when none was ever saved) and let
                        // the user press Save.
                        setCutoffNone(false);
                        setCutoffTime(cutoffSavedTime ?? "17:00");
                        return;
                      }
                      // Ticking saves immediately; a failure reverts.
                      const prev = cutoffNone;
                      setCutoffNone(true);
                      const ok = await changeDeliveryCutoff(
                        cutoffSavedTime ?? "17:00",
                        true
                      );
                      if (!ok) setCutoffNone(prev);
                    }}
                    className="h-4 w-4 rounded border-slate-300 text-brand-600 focus:ring-brand-500 disabled:opacity-50"
                  />
                  No cutoff
                </label>
              </div>
              {cutoffCanEdit && !cutoffNone && (
                <button
                  type="button"
                  data-testid="delivery-cutoff-save"
                  disabled={cutoffSaving}
                  onClick={() => changeDeliveryCutoff(cutoffTime, false)}
                  className="mt-2 rounded-md bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                >
                  {cutoffSaving ? "Saving…" : "Save cutoff"}
                </button>
              )}
              {cutoffSaving && (
                <p className="mt-1 text-xs text-slate-400">Saving…</p>
              )}
              {cutoffError && (
                <p className="mt-1 text-xs text-red-600">{cutoffError}</p>
              )}
              <p className="mt-1 text-xs text-slate-500">
                Orders booked at or after this time start the day after
                tomorrow. The clock is the timezone of the warehouse each
                order ships from.
                {!cutoffCanEdit && " Only owners and admins can change this."}
              </p>
            </div>
          )}
          {holdSupported && (
            <div className="border-b border-slate-200 pb-4">
              <label
                htmlFor="settings-hold-days"
                className="block text-sm font-medium text-slate-700"
              >
                Waiting on customer days
              </label>
              <div className="mt-2 flex items-center gap-3">
                <input
                  id="settings-hold-days"
                  data-testid="settings-hold-days"
                  type="number"
                  min={0}
                  max={14}
                  step={1}
                  value={holdDraft}
                  disabled={holdSaving || !holdCanEdit}
                  onChange={(e) => {
                    setHoldDraft(e.target.value);
                    setHoldError(null);
                  }}
                  className="w-20 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm disabled:opacity-50"
                />
                {holdCanEdit && (
                  <button
                    type="button"
                    data-testid="settings-hold-days-save"
                    disabled={holdSaving || holdDraft === String(holdDays)}
                    onClick={changeHoldDays}
                    className="rounded-md bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                  >
                    {holdSaving ? "Saving…" : "Save"}
                  </button>
                )}
              </div>
              {holdSaving && (
                <p className="mt-1 text-xs text-slate-400">Saving…</p>
              )}
              {holdError && (
                <p className="mt-1 text-xs text-red-600">{holdError}</p>
              )}
              <p className="mt-1 text-xs text-slate-500">
                After a call that does not reach the customer, show Waiting on
                customer for this many days. 0 turns it off.
                {!holdCanEdit && " Only owners and admins can change this."}
              </p>
            </div>
          )}
          {daySettings && (
            <div className="border-b border-slate-200 pb-4">
              <span className="block text-sm font-medium text-slate-700">
                Delivery hours
              </span>
              <div className="mt-2 grid grid-cols-1 gap-3 sm:grid-cols-2">
                <div>
                  <label
                    htmlFor="settings-day-start"
                    className="block text-xs font-medium text-slate-600"
                  >
                    Drivers start at
                  </label>
                  <select
                    id="settings-day-start"
                    data-testid="settings-day-start"
                    value={dayStart}
                    disabled={daySaving || !canEditPermissions}
                    onChange={(e) => {
                      setDayStart(e.target.value);
                      setDaySaved(false);
                      setDayError(null);
                    }}
                    className="mt-1 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm disabled:opacity-50"
                  >
                    {DAY_TIME_OPTIONS.map((o) => (
                      <option key={o.value} value={o.value}>
                        {o.label}
                      </option>
                    ))}
                  </select>
                </div>
                <div>
                  <label
                    htmlFor="settings-day-end"
                    className="block text-xs font-medium text-slate-600"
                  >
                    Drivers finish at
                  </label>
                  <select
                    id="settings-day-end"
                    data-testid="settings-day-end"
                    value={dayEnd}
                    disabled={daySaving || !canEditPermissions}
                    onChange={(e) => {
                      setDayEnd(e.target.value);
                      setDaySaved(false);
                      setDayError(null);
                    }}
                    className="mt-1 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm disabled:opacity-50"
                  >
                    {DAY_TIME_OPTIONS.map((o) => (
                      <option key={o.value} value={o.value}>
                        {o.label}
                      </option>
                    ))}
                  </select>
                </div>
              </div>
              <div className="mt-3">
                <span className="block text-xs font-medium text-slate-600">
                  Arrival window length
                </span>
                <div className="mt-1 flex items-center gap-2">
                  <select
                    id="settings-window-length"
                    data-testid="settings-window-length"
                    value={windowChoice}
                    disabled={daySaving || !canEditPermissions}
                    onChange={(e) => {
                      setWindowChoice(e.target.value as typeof windowChoice);
                      setDaySaved(false);
                      setDayError(null);
                    }}
                    className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm disabled:opacity-50"
                  >
                    <option value="2">2 hours</option>
                    <option value="3">3 hours</option>
                    <option value="4">4 hours</option>
                    <option value="custom">Custom</option>
                  </select>
                  {windowChoice === "custom" && (
                    <span className="flex items-center gap-1 text-sm text-slate-600">
                      <input
                        id="settings-window-custom"
                        data-testid="settings-window-custom"
                        type="number"
                        min={1}
                        max={8}
                        step={1}
                        value={windowCustomDraft}
                        disabled={daySaving || !canEditPermissions}
                        onChange={(e) => {
                          setWindowCustomDraft(e.target.value);
                          setDaySaved(false);
                          setDayError(null);
                        }}
                        className="w-16 rounded-md border border-slate-300 bg-white px-2 py-2 text-sm disabled:opacity-50"
                      />
                      hours
                    </span>
                  )}
                </div>
              </div>
              <div className="mt-3">
                <span className="block text-xs font-medium text-slate-600">
                  Arrival windows
                </span>
                <div className="mt-1 flex flex-wrap gap-2">
                  {(
                    [
                      { value: "window" as const, label: "Give customers an arrival window" },
                      { value: "day_only" as const, label: "Day only, no arrival windows" },
                    ]
                  ).map((opt) => (
                    <button
                      key={opt.value}
                      type="button"
                      data-testid={`settings-day-mode-${opt.value}`}
                      disabled={daySaving || !canEditPermissions}
                      onClick={() => {
                        setDayMode(opt.value);
                        setDaySaved(false);
                        setDayError(null);
                      }}
                      className={`rounded-md border px-3 py-1.5 text-sm ${
                        dayMode === opt.value
                          ? "border-brand-600 bg-brand-600 text-white"
                          : "border-slate-300 bg-white text-slate-600 hover:bg-slate-50"
                      } disabled:opacity-50`}
                    >
                      {opt.label}
                    </button>
                  ))}
                </div>
              </div>
              {canEditPermissions && (
                <button
                  type="button"
                  data-testid="settings-day-save"
                  disabled={daySaving || !dayFormDirty}
                  onClick={changeDaySettings}
                  className="mt-3 rounded-md bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                >
                  {daySaving ? "Saving…" : "Save"}
                </button>
              )}
              {daySaving && (
                <p className="mt-1 text-xs text-slate-400">Saving…</p>
              )}
              {daySaved && !daySaving && (
                <p className="mt-1 text-xs text-slate-500">Saved</p>
              )}
              {dayError && (
                <p className="mt-1 text-xs text-red-600">{dayError}</p>
              )}
              <p className="mt-1 text-xs text-slate-500">
                Used to suggest arrival windows. You can always set any window
                by hand.
                {!canEditPermissions && " Only owners and admins can change this."}
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

          {permGrants !== null && (
            <div className="border-t border-slate-200 pt-4">
              <h2 className="text-sm font-medium text-slate-700">
                Inventory and exchange permissions
              </h2>
              <p className="mt-1 text-xs text-slate-500">
                Who may settle and close exchanges, inspect returned
                mattresses, edit the inspection checklist, and confirm
                lowering on-hand stock below what open journeys have
                reserved.
                {!canEditPermissions &&
                  " Only owners and admins can change these."}
              </p>
              <div className="mt-2 space-y-2">
                {INVENTORY_PERMISSIONS.map((p) => (
                  <div
                    key={p.key}
                    className="flex flex-wrap items-center justify-between gap-3"
                  >
                    <span className="text-sm text-slate-700">{p.label}</span>
                    <div className="flex flex-wrap gap-3">
                      {PERMISSION_ROLES.map((r) => (
                        <label
                          key={r.value}
                          className="flex items-center gap-1.5 text-xs text-slate-600"
                        >
                          <input
                            type="checkbox"
                            checked={permGranted(r.value, p.key)}
                            disabled={
                              r.value === "owner" ||
                              !canEditPermissions ||
                              permSaving !== null
                            }
                            onChange={(e) =>
                              togglePermission(
                                r.value,
                                p.key,
                                e.target.checked
                              )
                            }
                            className="h-4 w-4 rounded border-slate-300 text-brand-600 focus:ring-brand-500 disabled:opacity-50"
                          />
                          {r.label}
                        </label>
                      ))}
                    </div>
                  </div>
                ))}
              </div>
              {permError && (
                <p className="mt-2 text-xs text-red-600">{permError}</p>
              )}
            </div>
          )}

          {stalledSupported && (
            <div className="border-t border-slate-200 pt-4">
              <label
                htmlFor="exchange-stalled-days"
                className="block text-sm font-medium text-slate-700"
              >
                Exchange stalled after (days)
              </label>
              <input
                id="exchange-stalled-days"
                type="number"
                min={1}
                step={1}
                value={stalledDraft}
                disabled={saving === "exchange_stalled_days"}
                onChange={(e) => setStalledDraft(e.target.value)}
                onBlur={() => {
                  const n = parseInt(stalledDraft, 10);
                  if (
                    !Number.isNaN(n) &&
                    n > 0 &&
                    n !== settings.exchange_stalled_days
                  ) {
                    handleSave("exchange_stalled_days", n);
                  } else {
                    setStalledDraft(String(settings.exchange_stalled_days));
                  }
                }}
                className="mt-2 w-32 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm"
              />
              <p className="mt-1 text-xs text-slate-500">
                A committed exchange with unfinished milestones shows as
                &quot;Exchange stalled&quot; in My Work after this many days.
              </p>
            </div>
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
