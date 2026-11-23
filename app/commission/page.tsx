"use client";

// C1c: commission ledger + settings for commission.manage (owner/admin by
// default grant, or anyone the permission is extended to). The page checks
// has_permission first and never touches a commission RPC without it; the
// functions themselves enforce the same gate server-side.
//
// Ledger reads list_commission_entries (175). Settings reads
// get_commission_settings and writes through save_commission_plan /
// set_commission_settings. Everything else here is display only.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { hasPermission } from "@/lib/inventory/queries";
import { localDateISO, localTodayISO } from "@/lib/dates";

type CommissionEntry = {
  entry_id: string;
  earned_date: string;
  pay_period_start: string;
  employee_id: string;
  employee_name: string | null;
  journey_id: string;
  journey_number: string | null;
  item_name: string | null;
  kind: string;
  amount_cents: number | null;
  revenue_cents: number | null;
  cost_cents: number | null;
  rate_bp: number | null;
  credit_share_bp: number | null;
  flags: string[] | null;
};

type CommissionSettings = {
  commission_earned_on: string;
  commission_partial_mode: string;
  commission_basis: string;
  commission_cost_basis: string;
  pay_period_days: number;
  pay_period_anchor: string | null;
  default_plan_id: string | null;
  default_plan_name: string | null;
  default_plan_rate_bp: number | null;
};

const FLAG_META: Record<string, { label: string; className: string }> = {
  MISSING_COST: {
    label: "Missing cost",
    className: "bg-amber-100 text-amber-800",
  },
  NO_PLAN: {
    label: "No plan",
    className: "bg-amber-100 text-amber-800",
  },
  NEGATIVE_PROFIT: {
    label: "Below cost",
    className: "bg-red-100 text-red-700",
  },
};

function money(cents: number | null): string {
  if (cents == null) return "";
  const dollars = (Math.abs(cents) / 100).toFixed(2);
  return cents < 0 ? `-$${dollars}` : `$${dollars}`;
}

function pct(bp: number | null): string {
  if (bp == null) return "";
  return `${parseFloat((bp / 100).toFixed(2))}%`;
}

function addDaysISO(iso: string, days: number): string {
  const d = new Date(`${iso}T00:00:00`);
  d.setDate(d.getDate() + days);
  return localDateISO(d);
}

function daysBetweenInclusive(from: string, to: string): number {
  const ms =
    new Date(`${to}T00:00:00`).getTime() -
    new Date(`${from}T00:00:00`).getTime();
  return Math.round(ms / 86400000) + 1;
}

function FlagPills({ flags }: { flags: string[] | null }) {
  if (!flags || flags.length === 0) return null;
  return (
    <span className="flex flex-wrap gap-1">
      {flags.map((f) => {
        const meta = FLAG_META[f] ?? {
          label: f,
          className: "bg-slate-100 text-slate-600",
        };
        return (
          <span
            key={f}
            className={`rounded-full px-2 py-0.5 text-xs font-medium ${meta.className}`}
          >
            {meta.label}
          </span>
        );
      })}
    </span>
  );
}

export default function CommissionPage() {
  const router = useRouter();
  const [allowed, setAllowed] = useState<boolean | null>(null);
  const [tab, setTab] = useState<"ledger" | "settings">("ledger");

  // ---------------- ledger state ----------------
  const [range, setRange] = useState<{ from: string; to: string } | null>(
    null
  );
  const [periodDays, setPeriodDays] = useState(14);
  // True once the user picks a From/To date by hand: saving new pay-period
  // settings must not yank their chosen range out from under them.
  const datesEditedRef = useRef(false);
  const [employeeId, setEmployeeId] = useState<string | null>(null);
  const [employeeOptions, setEmployeeOptions] = useState<
    { id: string; name: string }[]
  >([]);
  const [rows, setRows] = useState<CommissionEntry[] | null>(null);
  const [entriesLoading, setEntriesLoading] = useState(false);
  const [entriesError, setEntriesError] = useState<string | null>(null);

  // ---------------- settings state ----------------
  const [settings, setSettings] = useState<CommissionSettings | null>(null);
  const [settingsLoading, setSettingsLoading] = useState(false);
  const [settingsError, setSettingsError] = useState<string | null>(null);
  const [settingsRequested, setSettingsRequested] = useState(false);
  const [planName, setPlanName] = useState("Standard");
  const [ratePct, setRatePct] = useState("");
  const [periodDaysInput, setPeriodDaysInput] = useState("");
  const [anchorInput, setAnchorInput] = useState("");
  const [savingPlan, setSavingPlan] = useState(false);
  const [savingPeriod, setSavingPeriod] = useState(false);
  const [planMessage, setPlanMessage] = useState<{
    ok?: string;
    err?: string;
  } | null>(null);
  const [periodMessage, setPeriodMessage] = useState<{
    ok?: string;
    err?: string;
  } | null>(null);

  // Permission gate: the sidebar only shows this page to commission.manage,
  // and the same check runs here so a direct URL visit gets the same answer
  // without a single commission RPC firing.
  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getSession().then(async ({ data: { session } }) => {
      if (!session?.user) {
        router.push("/login");
        return;
      }
      setAllowed(await hasPermission("commission.manage"));
    });
  }, [router]);

  // Default range: the current pay period; last 14 days when the period
  // RPC fails or returns nothing (fresh company, no anchor data). Also
  // rerun after a pay-period settings save so the ledger lands on the
  // new period, unless the user picked dates by hand this visit.
  const resolveCurrentPeriod = useCallback(async () => {
    const supabase = createClient();
    try {
      const { data, error } = await supabase.rpc("commission_pay_period", {
        p_date: localTodayISO(),
      });
      const row = Array.isArray(data) ? data[0] : null;
      if (error || !row?.period_start || !row?.period_end) {
        throw error ?? new Error("no pay period");
      }
      setPeriodDays(daysBetweenInclusive(row.period_start, row.period_end));
      setRange({ from: row.period_start, to: row.period_end });
    } catch {
      const to = localTodayISO();
      setPeriodDays(14);
      setRange({ from: addDaysISO(to, -13), to });
    }
  }, []);

  useEffect(() => {
    if (allowed !== true || range !== null) return;
    resolveCurrentPeriod();
  }, [allowed, range, resolveCurrentPeriod]);

  const loadEntries = useCallback(
    async (from: string, to: string, empId: string | null) => {
      setEntriesLoading(true);
      setEntriesError(null);
      const supabase = createClient();
      const { data, error } = await supabase.rpc("list_commission_entries", {
        p_from: from,
        p_to: to,
        p_employee_id: empId,
      });
      if (error) {
        setRows(null);
        setEntriesError(error.message);
      } else {
        const list = (data as CommissionEntry[]) ?? [];
        setRows(list);
        // The dropdown is built from the unfiltered result so it lists
        // every employee that appears in the range without a second query.
        if (empId == null) {
          const seen = new Map<string, string>();
          for (const r of list) {
            if (!seen.has(r.employee_id)) {
              seen.set(r.employee_id, r.employee_name ?? "Unknown");
            }
          }
          setEmployeeOptions(
            Array.from(seen.entries())
              .map(([id, name]) => ({ id, name }))
              .sort((a, b) => a.name.localeCompare(b.name))
          );
        }
      }
      setEntriesLoading(false);
    },
    []
  );

  useEffect(() => {
    if (allowed !== true || range === null) return;
    loadEntries(range.from, range.to, employeeId);
  }, [allowed, range, employeeId, loadEntries]);

  const shiftPeriod = (dir: -1 | 1) => {
    setRange((r) =>
      r
        ? {
            from: addDaysISO(r.from, dir * periodDays),
            to: addDaysISO(r.to, dir * periodDays),
          }
        : r
    );
  };

  // ---------------- settings load/save ----------------

  const loadSettings = useCallback(async () => {
    setSettingsLoading(true);
    setSettingsError(null);
    const supabase = createClient();
    const { data, error } = await supabase.rpc("get_commission_settings");
    if (error) {
      setSettings(null);
      setSettingsError(error.message);
    } else {
      const row = (Array.isArray(data) ? data[0] : data) as
        | CommissionSettings
        | undefined;
      const s = row ?? null;
      setSettings(s);
      if (s) {
        setPlanName(s.default_plan_name ?? "Standard");
        setRatePct(
          s.default_plan_rate_bp == null
            ? ""
            : String(parseFloat((s.default_plan_rate_bp / 100).toFixed(2)))
        );
        setPeriodDaysInput(String(s.pay_period_days));
        setAnchorInput(s.pay_period_anchor ?? "");
      }
    }
    setSettingsLoading(false);
  }, []);

  useEffect(() => {
    if (allowed === true && tab === "settings" && !settingsRequested) {
      setSettingsRequested(true);
      loadSettings();
    }
  }, [allowed, tab, settingsRequested, loadSettings]);

  const savePlan = async () => {
    setPlanMessage(null);
    const rate = Number(ratePct);
    if (ratePct.trim() === "" || !Number.isFinite(rate)) {
      setPlanMessage({ err: "Enter the default commission rate." });
      return;
    }
    if (rate < 0 || rate > 100) {
      setPlanMessage({ err: "The rate must be between 0 and 100." });
      return;
    }
    setSavingPlan(true);
    const supabase = createClient();
    const { error } = await supabase.rpc("save_commission_plan", {
      p_name: planName.trim() || "Standard",
      p_rate_bp: Math.round(rate * 100),
      p_make_default: true,
    });
    setSavingPlan(false);
    if (error) {
      setPlanMessage({ err: error.message });
    } else {
      setPlanMessage({ ok: "Commission plan saved." });
      loadSettings();
    }
  };

  const savePeriod = async () => {
    setPeriodMessage(null);
    const days = Number(periodDaysInput);
    if (
      periodDaysInput.trim() === "" ||
      !Number.isInteger(days) ||
      days < 7 ||
      days > 31
    ) {
      setPeriodMessage({
        err: "Enter a pay period length between 7 and 31 days.",
      });
      return;
    }
    setSavingPeriod(true);
    const supabase = createClient();
    const { error } = await supabase.rpc("set_commission_settings", {
      p_pay_period_days: days,
      p_pay_period_anchor: anchorInput || null,
    });
    setSavingPeriod(false);
    if (error) {
      setPeriodMessage({ err: error.message });
    } else {
      setPeriodMessage({ ok: "Pay period settings saved." });
      loadSettings();
      if (!datesEditedRef.current) {
        resolveCurrentPeriod();
      }
    }
  };

  // ---------------- derived ledger data ----------------

  const summary = useMemo(() => {
    const m = new Map<
      string,
      { name: string; total: number; notCalculated: number }
    >();
    for (const r of rows ?? []) {
      const cur =
        m.get(r.employee_id) ??
        ({ name: r.employee_name ?? "Unknown", total: 0, notCalculated: 0 } as {
          name: string;
          total: number;
          notCalculated: number;
        });
      if (r.amount_cents == null) {
        cur.notCalculated += 1;
      } else {
        cur.total += r.amount_cents;
      }
      m.set(r.employee_id, cur);
    }
    return Array.from(m.values()).sort((a, b) =>
      a.name.localeCompare(b.name)
    );
  }, [rows]);

  // ---------------- render ----------------

  if (allowed === null) {
    return (
      <div className="mx-auto max-w-6xl px-4 py-6">
        <p className="py-10 text-center text-sm text-slate-500">Loading…</p>
      </div>
    );
  }

  if (allowed === false) {
    return (
      <div className="mx-auto max-w-6xl px-4 py-6">
        <p className="rounded-lg border border-slate-200 bg-white px-6 py-10 text-center text-sm text-slate-600">
          You do not have access to commission.
        </p>
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-6xl px-4 py-6" data-testid="commission-page">
      <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-xl font-semibold text-slate-900">Commission</h1>
        <div
          className="flex rounded-md border border-slate-300 text-sm"
          role="group"
          aria-label="Commission sections"
        >
          {(
            [
              ["ledger", "Ledger"],
              ["settings", "Settings"],
            ] as ["ledger" | "settings", string][]
          ).map(([value, label]) => (
            <button
              key={value}
              type="button"
              onClick={() => setTab(value)}
              aria-pressed={tab === value}
              className={`px-3 py-1.5 ${
                tab === value
                  ? "bg-slate-900 font-medium text-white"
                  : "text-slate-600 hover:bg-slate-50"
              } ${value === "ledger" ? "rounded-l-md" : "rounded-r-md border-l border-slate-300"}`}
            >
              {label}
            </button>
          ))}
        </div>
      </div>

      {tab === "ledger" ? (
        <>
          <div className="mb-4 flex flex-wrap items-end gap-3">
            <button
              type="button"
              onClick={() => shiftPeriod(-1)}
              className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50"
            >
              Previous period
            </button>
            <button
              type="button"
              onClick={() => shiftPeriod(1)}
              className="rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50"
            >
              Next period
            </button>
            <label className="text-sm text-slate-600">
              <span className="mb-1 block text-xs text-slate-500">From</span>
              <input
                type="date"
                value={range?.from ?? ""}
                onChange={(e) => {
                  if (!e.target.value) return;
                  datesEditedRef.current = true;
                  setRange((r) => ({
                    from: e.target.value,
                    to: r?.to ?? e.target.value,
                  }));
                }}
                className="rounded-md border border-slate-300 px-2 py-1.5 text-sm"
              />
            </label>
            <label className="text-sm text-slate-600">
              <span className="mb-1 block text-xs text-slate-500">To</span>
              <input
                type="date"
                value={range?.to ?? ""}
                onChange={(e) => {
                  if (!e.target.value) return;
                  datesEditedRef.current = true;
                  setRange((r) => ({
                    from: r?.from ?? e.target.value,
                    to: e.target.value,
                  }));
                }}
                className="rounded-md border border-slate-300 px-2 py-1.5 text-sm"
              />
            </label>
            <label className="text-sm text-slate-600">
              <span className="mb-1 block text-xs text-slate-500">
                Employee
              </span>
              <select
                value={employeeId ?? ""}
                onChange={(e) => setEmployeeId(e.target.value || null)}
                className="rounded-md border border-slate-300 px-2 py-1.5 text-sm"
              >
                <option value="">All employees</option>
                {employeeOptions.map((o) => (
                  <option key={o.id} value={o.id}>
                    {o.name}
                  </option>
                ))}
              </select>
            </label>
          </div>

          {entriesLoading && rows === null ? (
            <p className="py-10 text-center text-sm text-slate-500">
              Loading…
            </p>
          ) : entriesError ? (
            <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-6 text-center">
              <p className="text-sm text-red-700">{entriesError}</p>
              <button
                onClick={() =>
                  range && loadEntries(range.from, range.to, employeeId)
                }
                className="mt-3 rounded-md border border-red-300 px-3 py-1.5 text-sm text-red-700 hover:bg-red-100"
              >
                Try again
              </button>
            </div>
          ) : rows === null ? (
            <p className="py-10 text-center text-sm text-slate-500">
              Loading…
            </p>
          ) : rows.length === 0 ? (
            <p className="rounded-lg border border-slate-200 bg-white px-6 py-10 text-center text-sm text-slate-600">
              No commission entries for these dates. Entries appear when an
              item is picked up or delivered.
            </p>
          ) : (
            <>
              {rows.length >= 2000 && (
                <p className="mb-3 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-800">
                  Showing the newest 2000 entries. Narrow the dates.
                </p>
              )}

              <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
                {summary.length > 0 && (
                  <div className="border-b border-slate-200 bg-slate-50 px-4 py-2 text-sm text-slate-700">
                    {summary.map((s) => (
                      <span key={s.name} className="mr-6 inline-block py-0.5">
                        <span className="font-medium">{s.name}:</span>{" "}
                        <span
                          className={s.total < 0 ? "text-red-600" : undefined}
                        >
                          {money(s.total)}
                        </span>
                        {s.notCalculated > 0 && (
                          <span className="text-amber-700">
                            {" "}
                            ({s.notCalculated} not calculated)
                          </span>
                        )}
                      </span>
                    ))}
                  </div>
                )}
                <table className="min-w-full divide-y divide-slate-200 text-sm">
                  <thead>
                    <tr className="text-left text-xs font-medium uppercase tracking-wide text-slate-500">
                      <th className="px-3 py-2">Date</th>
                      <th className="px-3 py-2">Employee</th>
                      <th className="px-3 py-2">Order</th>
                      <th className="px-3 py-2">Item</th>
                      <th className="px-3 py-2 text-right">Revenue</th>
                      <th className="px-3 py-2 text-right">Cost</th>
                      <th className="px-3 py-2 text-right">Profit</th>
                      <th className="px-3 py-2 text-right">Rate</th>
                      <th className="px-3 py-2 text-right">Share</th>
                      <th className="px-3 py-2 text-right">Commission</th>
                      <th className="px-3 py-2">Flags</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {entriesLoading && (
                      <tr>
                        <td
                          colSpan={11}
                          className="px-3 py-3 text-center text-sm text-slate-500"
                        >
                          Loading…
                        </td>
                      </tr>
                    )}
                    {rows.map((r) => {
                      const profit =
                        r.cost_cents == null || r.revenue_cents == null
                          ? null
                          : r.revenue_cents - r.cost_cents;
                      return (
                        <tr key={r.entry_id} className="align-top">
                          <td className="whitespace-nowrap px-3 py-2 text-slate-700">
                            {r.earned_date}
                          </td>
                          <td className="px-3 py-2 text-slate-700">
                            {r.employee_name ?? "Unknown"}
                          </td>
                          <td className="whitespace-nowrap px-3 py-2">
                            <Link
                              href={`/board?journey=${r.journey_id}`}
                              className="text-brand-600 hover:text-brand-700 hover:underline"
                            >
                              {r.journey_number ?? "View order"}
                            </Link>
                          </td>
                          <td className="px-3 py-2 text-slate-700">
                            {r.item_name ?? ""}
                          </td>
                          <td className="whitespace-nowrap px-3 py-2 text-right text-slate-700">
                            {money(r.revenue_cents)}
                          </td>
                          <td className="whitespace-nowrap px-3 py-2 text-right text-slate-700">
                            {money(r.cost_cents)}
                          </td>
                          <td
                            className={`whitespace-nowrap px-3 py-2 text-right ${
                              profit != null && profit < 0
                                ? "text-red-600"
                                : "text-slate-700"
                            }`}
                          >
                            {profit == null ? "" : money(profit)}
                          </td>
                          <td className="whitespace-nowrap px-3 py-2 text-right text-slate-700">
                            {pct(r.rate_bp)}
                          </td>
                          <td className="whitespace-nowrap px-3 py-2 text-right text-slate-700">
                            {pct(r.credit_share_bp)}
                          </td>
                          <td
                            className={`whitespace-nowrap px-3 py-2 text-right ${
                              r.amount_cents != null && r.amount_cents < 0
                                ? "text-red-600"
                                : "text-slate-700"
                            }`}
                          >
                            {r.amount_cents == null ? (
                              <span className="text-slate-500">
                                Not calculated
                              </span>
                            ) : (
                              money(r.amount_cents)
                            )}
                          </td>
                          <td className="px-3 py-2">
                            <FlagPills flags={r.flags} />
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>

              <div className="mt-2 space-y-0.5 text-xs text-slate-500">
                <p>
                  Missing cost: the product had no cost when it was sold, so
                  commission could not be calculated.
                </p>
                <p>No plan: no commission plan was set up.</p>
                <p>Below cost: sold for less than it cost.</p>
              </div>
            </>
          )}
        </>
      ) : (
        <div className="max-w-2xl space-y-6">
          {settingsLoading && settings === null ? (
            <p className="py-10 text-center text-sm text-slate-500">
              Loading…
            </p>
          ) : settingsError ? (
            <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-6 text-center">
              <p className="text-sm text-red-700">{settingsError}</p>
              <button
                onClick={loadSettings}
                className="mt-3 rounded-md border border-red-300 px-3 py-1.5 text-sm text-red-700 hover:bg-red-100"
              >
                Try again
              </button>
            </div>
          ) : settings === null ? (
            <p className="py-10 text-center text-sm text-slate-500">
              Loading…
            </p>
          ) : (
            <>
              <section className="rounded-lg border border-slate-200 bg-white p-4">
                <h2 className="mb-3 text-sm font-semibold text-slate-900">
                  Default commission rate
                </h2>
                {settings.default_plan_id === null &&
                  !savingPlan &&
                  !settingsLoading && (
                    <p className="mb-3 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-800">
                      No commission plan yet. Entries are recorded without
                      an amount until you set one.
                    </p>
                  )}
                {settings.default_plan_id !== null && (
                  <p className="mb-3 text-sm text-slate-600">
                    Current plan: {settings.default_plan_name} (
                    {pct(settings.default_plan_rate_bp)})
                  </p>
                )}
                <div className="flex flex-wrap items-end gap-3">
                  <label className="text-sm text-slate-600">
                    <span className="mb-1 block text-xs text-slate-500">
                      Plan name
                    </span>
                    <input
                      type="text"
                      value={planName}
                      onChange={(e) => setPlanName(e.target.value)}
                      placeholder="Standard"
                      className="w-48 rounded-md border border-slate-300 px-2 py-1.5 text-sm"
                    />
                  </label>
                  <label className="text-sm text-slate-600">
                    <span className="mb-1 block text-xs text-slate-500">
                      Rate (percent)
                    </span>
                    <input
                      type="number"
                      min={0}
                      max={100}
                      step={0.01}
                      value={ratePct}
                      onChange={(e) => setRatePct(e.target.value)}
                      placeholder="10"
                      className="w-28 rounded-md border border-slate-300 px-2 py-1.5 text-sm"
                    />
                  </label>
                  <button
                    type="button"
                    onClick={savePlan}
                    disabled={savingPlan}
                    className="rounded-md bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                  >
                    {savingPlan ? "Saving…" : "Save"}
                  </button>
                </div>
                {planMessage?.ok && (
                  <p className="mt-3 text-sm text-green-700">
                    {planMessage.ok}
                  </p>
                )}
                {planMessage?.err && (
                  <p className="mt-3 text-sm text-red-700">
                    {planMessage.err}
                  </p>
                )}
              </section>

              <section className="rounded-lg border border-slate-200 bg-white p-4">
                <h2 className="mb-3 text-sm font-semibold text-slate-900">
                  Pay period
                </h2>
                <div className="flex flex-wrap items-end gap-3">
                  <label className="text-sm text-slate-600">
                    <span className="mb-1 block text-xs text-slate-500">
                      Pay period length (days)
                    </span>
                    <input
                      type="number"
                      min={7}
                      max={31}
                      step={1}
                      value={periodDaysInput}
                      onChange={(e) => setPeriodDaysInput(e.target.value)}
                      className="w-28 rounded-md border border-slate-300 px-2 py-1.5 text-sm"
                    />
                  </label>
                  <label className="text-sm text-slate-600">
                    <span className="mb-1 block text-xs text-slate-500">
                      A pay period starts on
                    </span>
                    <input
                      type="date"
                      value={anchorInput}
                      onChange={(e) => setAnchorInput(e.target.value)}
                      className="rounded-md border border-slate-300 px-2 py-1.5 text-sm"
                    />
                    {anchorInput === "" && (
                      <span className="mt-1 block text-xs text-slate-500">
                        Not set (using Jan 1, 2024)
                      </span>
                    )}
                  </label>
                  <button
                    type="button"
                    onClick={savePeriod}
                    disabled={savingPeriod}
                    className="rounded-md bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
                  >
                    {savingPeriod ? "Saving…" : "Save"}
                  </button>
                </div>
                {periodMessage?.ok && (
                  <p className="mt-3 text-sm text-green-700">
                    {periodMessage.ok}
                  </p>
                )}
                {periodMessage?.err && (
                  <p className="mt-3 text-sm text-red-700">
                    {periodMessage.err}
                  </p>
                )}
              </section>

              <section className="rounded-lg border border-slate-200 bg-white p-4">
                <h2 className="mb-2 text-sm font-semibold text-slate-900">
                  How commission is calculated
                </h2>
                <p className="text-sm text-slate-600">
                  Commission is earned when an item is picked up or
                  delivered. It is a percent of profit (price after
                  discounts minus cost). Cost used:{" "}
                  {settings.commission_cost_basis === "COMMISSION_COST"
                    ? "commission cost"
                    : "wholesale cost"}
                  .
                </p>
              </section>
            </>
          )}
        </div>
      )}
    </div>
  );
}
