"use client";

// C3c/C3d: payout report for commission.payouts_view (bookkeeper-grade
// read) with manage actions behind a separate commission.payouts_manage
// check. The page checks has_permission first and never touches a payout
// RPC without it; the functions enforce the same gate server-side.
//
// Reads: get_payout_period, get_payout_report, list_commission_closes,
// list_employee_draws. Writes: set_employee_draw,
// close_commission_period, reopen_commission_period. No commission
// ledger RPC is ever called and no cost field exists on this page.
//
// Period boundaries, closed state and closed_at come from
// get_payout_period (177): the report can return zero rows for an empty
// period, so nothing on this page derives dates itself.

import { useCallback, useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import Modal from "@/components/Modal";
import { createClient } from "@/lib/supabase/client";
import { hasPermission } from "@/lib/inventory/queries";
import { fetchEmployees, type Employee } from "@/lib/journeys/queries";
import { localDateISO, localTodayISO } from "@/lib/dates";

type PayoutRow = {
  employee_id: string;
  employee_name: string | null;
  period_start: string;
  period_end: string;
  entry_count: number;
  not_calculated_count: number;
  commission_cents: number;
  draw_cents: number;
  spiff_cents: number;
  pay_cents: number;
  draw_covers_cents: number;
  is_closed: boolean;
  closed_at: string | null;
  late_entry_count: number;
  pay_date: string | null;
  spiff_month_start: string | null;
  spiff_month_end: string | null;
  spiffs_cents: number;
  spiffs_negative_not_deducted: boolean;
};

type CloseRow = {
  close_id: string;
  period_start: string;
  period_end: string;
  closed_at: string;
  closed_by_name: string | null;
  reopened_at: string | null;
  reopen_reason: string | null;
  total_pay_cents: number;
};

type DrawRow = {
  draw_id: string;
  employee_id: string;
  employee_name: string | null;
  amount_cents: number;
  effective_from: string;
  note: string | null;
  created_at: string;
  created_by_name: string | null;
};

function money(cents: number | null): string {
  if (cents == null) return "";
  const dollars = (Math.abs(cents) / 100).toFixed(2);
  return cents < 0 ? `-$${dollars}` : `$${dollars}`;
}

function addDaysISO(iso: string, days: number): string {
  const d = new Date(`${iso}T00:00:00`);
  d.setDate(d.getDate() + days);
  return localDateISO(d);
}

function shortDate(iso: string | null): string {
  if (!iso) return "";
  return new Date(`${iso.slice(0, 10)}T00:00:00`).toLocaleDateString(
    undefined,
    { month: "short", day: "numeric", year: "numeric" }
  );
}

function payDateFmt(iso: string | null | undefined): string {
  if (!iso) return "";
  return new Date(`${iso.slice(0, 10)}T00:00:00`).toLocaleDateString(
    undefined,
    { weekday: "short", month: "short", day: "numeric", year: "numeric" }
  );
}

function monthName(iso: string | null | undefined): string {
  if (!iso) return "";
  return new Date(`${iso.slice(0, 10)}T00:00:00`).toLocaleDateString(
    undefined,
    { month: "long" }
  );
}

function csvEscape(v: string): string {
  return `"${v.replace(/"/g, '""')}"`;
}

// Same typed-string handling as UnitPriceInput on the new order page: the
// raw string stays while the field has focus so digits are never
// reformatted away, the dollar value updates on every valid keystroke,
// and blur snaps to 2 decimals. null means the field is empty or
// half-typed ("" or ".") so the caller can refuse to save.
function DollarInput({
  value,
  onChange,
  autoFocus = false,
}: {
  value: number | null;
  onChange: (v: number | null) => void;
  autoFocus?: boolean;
}) {
  const [text, setText] = useState<string | null>(null);
  return (
    <input
      type="text"
      inputMode="decimal"
      autoFocus={autoFocus}
      value={text ?? (value == null ? "" : value.toFixed(2))}
      onFocus={() => setText(value == null ? "" : value.toFixed(2))}
      onChange={(e) => {
        const s = e.target.value;
        // Digits with at most one dot: "", "9", "9.", ".5" all stay legal.
        if (!/^\d*\.?\d*$/.test(s)) return;
        setText(s);
        const n = parseFloat(s);
        onChange(Number.isFinite(n) ? n : null);
      }}
      onBlur={() => setText(null)}
      className="w-full rounded-md border border-slate-300 px-2 py-1 text-sm focus:border-brand-500 focus:outline-none focus:ring-1 focus:ring-brand-500"
    />
  );
}

type DrawTarget = { employee_id: string; name: string; draw_cents: number };

export default function PayoutsPage() {
  const router = useRouter();
  const [allowed, setAllowed] = useState<boolean | null>(null);
  const [canManage, setCanManage] = useState<boolean | null>(null);
  // undefined until get_spiff_settings answers, so the Spiffs column
  // never flashes in for a company that has the feature off.
  const [spiffSettings, setSpiffSettings] = useState<
    | { spiffs_enabled: boolean; google_reviews_enabled: boolean }
    | null
    | undefined
  >(undefined);

  // pDate: the p_date last sent (kept only so saves can refetch the same
  // period). period: boundaries and closed state from get_payout_period,
  // present even when the report below it is empty.
  const [pDate, setPDate] = useState<string>(localTodayISO());
  const [period, setPeriod] = useState<{
    start: string;
    end: string;
    isClosed: boolean;
    closedAt: string | null;
  } | null>(null);

  const [rows, setRows] = useState<PayoutRow[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [closes, setCloses] = useState<CloseRow[] | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  // Manage modals.
  const [drawTarget, setDrawTarget] = useState<DrawTarget | "pick" | null>(
    null
  );
  const [confirmClose, setConfirmClose] = useState(false);
  const [confirmReopen, setConfirmReopen] = useState(false);
  const [employees, setEmployees] = useState<Employee[] | null>(null);

  // ---------------- permission gate ----------------
  // The sidebar hides this page without payouts_view and the same check
  // runs here, so a direct URL visit gets the message without one payout
  // RPC firing. payouts_manage is checked separately (a bookkeeper has
  // view only) before any manage button renders.
  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getSession().then(async ({ data: { session } }) => {
      if (!session?.user) {
        router.push("/login");
        return;
      }
      const [view, manage, spiffRes] = await Promise.all([
        hasPermission("commission.payouts_view"),
        hasPermission("commission.payouts_manage"),
        supabase.rpc("get_spiff_settings"),
      ]);
      setAllowed(view === true);
      setCanManage(manage === true);
      setSpiffSettings(
        spiffRes.error
          ? null
          : (spiffRes.data as {
              spiffs_enabled: boolean;
              google_reviews_enabled: boolean;
            } | null)
      );
    });
  }, [router]);

  // ---------------- loads ----------------

  // get_payout_period and get_payout_report always go together: the
  // period call is what carries boundaries for an empty period.
  const loadPeriod = useCallback(async (d: string) => {
    setPDate(d);
    setLoading(true);
    setError(null);
    const supabase = createClient();
    const [periodRes, reportRes] = await Promise.all([
      supabase.rpc("get_payout_period", { p_date: d }),
      supabase.rpc("get_payout_report", { p_date: d }),
    ]);
    const rpcError = periodRes.error ?? reportRes.error;
    if (rpcError) {
      setRows(null);
      setError(rpcError.message);
    } else {
      const prow = (Array.isArray(periodRes.data)
        ? periodRes.data[0]
        : null) as {
        period_start: string;
        period_end: string;
        is_closed: boolean;
        closed_at: string | null;
      } | null;
      setPeriod(
        prow?.period_start && prow?.period_end
          ? {
              start: prow.period_start,
              end: prow.period_end,
              isClosed: prow.is_closed === true,
              closedAt: prow.closed_at,
            }
          : null
      );
      setRows((reportRes.data as PayoutRow[]) ?? []);
    }
    setLoading(false);
  }, []);

  const loadCloses = useCallback(async () => {
    const supabase = createClient();
    const { data, error: rpcError } = await supabase.rpc(
      "list_commission_closes",
      { p_limit: 24 }
    );
    if (!rpcError) {
      setCloses((data as CloseRow[]) ?? []);
    }
  }, []);

  useEffect(() => {
    if (allowed === true) {
      loadPeriod(localTodayISO());
      loadCloses();
    }
  }, [allowed, loadPeriod, loadCloses]);

  const refetchAll = useCallback(() => {
    loadPeriod(pDate);
    loadCloses();
  }, [loadPeriod, loadCloses, pDate]);

  const navigate = (dir: -1 | 1) => {
    if (!period) return;
    loadPeriod(addDaysISO(dir < 0 ? period.start : period.end, dir));
  };

  // ---------------- derived ----------------

  const isClosed = period?.isClosed === true;
  const closedAt = period?.closedAt ?? null;
  const lateEntries = useMemo(
    () => (rows ?? []).reduce((s, r) => s + r.late_entry_count, 0),
    [rows]
  );
  const totals = useMemo(
    () =>
      (rows ?? []).reduce(
        (t, r) => ({
          commission: t.commission + r.commission_cents,
          draw: t.draw + r.draw_cents,
          spiffs: t.spiffs + r.spiff_cents,
          pay: t.pay + r.pay_cents,
        }),
        { commission: 0, draw: 0, spiffs: 0, pay: 0 }
      ),
    [rows]
  );

  // The Spiffs column hides only when the company has both switches off
  // AND this period has no spiff money. It also stays hidden while the
  // settings call is in flight so the column never flashes.
  const spiffsOff =
    spiffSettings == null ||
    (!spiffSettings.spiffs_enabled &&
      !spiffSettings.google_reviews_enabled);
  const showSpiffsCol =
    spiffSettings !== undefined && (!spiffsOff || totals.spiffs !== 0);

  const exportCsv = () => {
    if (!rows || rows.length === 0 || !period) return;
    const header = [
      "Employee",
      "Period start",
      "Period end",
      "Status",
      "Entries",
      "Commission",
      "Draw",
      ...(showSpiffsCol ? ["Spiffs"] : []),
      "Pay",
      "Not calculated",
      "Pay date",
      "Spiff month",
    ];
    const money2 = (c: number) => (c / 100).toFixed(2);
    const lines = rows.map((r) =>
      [
        r.employee_name ?? "Unknown",
        r.period_start,
        r.period_end,
        r.is_closed ? "Closed" : "Open",
        String(r.entry_count),
        money2(r.commission_cents),
        money2(r.draw_cents),
        ...(showSpiffsCol ? [money2(r.spiff_cents)] : []),
        money2(r.pay_cents),
        String(r.not_calculated_count),
        r.pay_date ?? "",
        r.spiff_month_start
          ? new Date(`${r.spiff_month_start}T00:00:00`).toLocaleDateString(
              undefined,
              { month: "short", year: "numeric" }
            )
          : "",
      ]
        .map(csvEscape)
        .join(",")
    );
    const blob = new Blob([[header.map(csvEscape).join(","), ...lines].join("\n")], {
      type: "text/csv",
    });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `payouts_${period.start}_to_${period.end}.csv`;
    a.click();
    URL.revokeObjectURL(url);
  };

  const ensureEmployees = useCallback(async () => {
    if (employees !== null) return;
    setEmployees(await fetchEmployees());
  }, [employees]);

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
          You do not have access to payouts.
        </p>
      </div>
    );
  }

  return (
    <div className="mx-auto max-w-6xl px-4 py-6" data-testid="payouts-page">
      <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-xl font-semibold text-slate-900">Payouts</h1>
        <div className="flex items-center gap-2 text-sm">
          <button
            onClick={() => navigate(-1)}
            className="rounded-md border border-slate-300 px-2.5 py-1 text-slate-700 hover:bg-slate-50"
          >
            Previous period
          </button>
          <span className="min-w-40 text-center font-medium text-slate-700">
            {period
              ? `${shortDate(period.start)} - ${shortDate(period.end)}`
              : `Period containing ${shortDate(pDate)}`}
          </span>
          <button
            onClick={() => navigate(1)}
            className="rounded-md border border-slate-300 px-2.5 py-1 text-slate-700 hover:bg-slate-50"
          >
            Next period
          </button>
        </div>
        <div className="flex items-center gap-2">
          <button
            onClick={exportCsv}
            disabled={!rows || rows.length === 0}
            className="rounded-md border border-slate-300 px-2.5 py-1 text-sm text-slate-700 hover:bg-slate-50 disabled:opacity-50"
          >
            Export CSV
          </button>
          {canManage === true && !isClosed && period && (
            <button
              onClick={() => setConfirmClose(true)}
              className="rounded-md bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700"
            >
              Close period
            </button>
          )}
          {canManage === true && isClosed && (
            <button
              onClick={() => setConfirmReopen(true)}
              className="rounded-md border border-amber-300 bg-amber-50 px-3 py-1.5 text-sm font-medium text-amber-800 hover:bg-amber-100"
            >
              Reopen period
            </button>
          )}
        </div>
      </div>

      {notice && (
        <p className="mb-3 rounded-md border border-green-200 bg-green-50 px-3 py-2 text-sm text-green-800">
          {notice}
        </p>
      )}

      {period && (
        <div className="mb-3 text-sm">
          <p className={isClosed ? "text-slate-700" : "text-slate-500"}>
            {isClosed
              ? `Closed on ${shortDate(closedAt)}. These numbers are frozen.`
              : "Open. These numbers are live until you close the period."}
          </p>
          {rows?.[0]?.pay_date && (
            <p className="mt-1 text-slate-500">
              Pay date: {payDateFmt(rows[0].pay_date)}
            </p>
          )}
          {showSpiffsCol && rows?.[0]?.spiff_month_start && (
            <p className="mt-1 text-slate-500">
              Includes {monthName(rows[0].spiff_month_start)} spiffs
            </p>
          )}
          {isClosed && lateEntries > 0 && (
            <p className="mt-1 inline-block rounded-md border border-amber-200 bg-amber-50 px-2 py-1 text-amber-800">
              {lateEntries}{" "}
              {lateEntries === 1 ? "entry was" : "entries were"} added after
              this period closed and {lateEntries === 1 ? "is" : "are"} not
              in these numbers.
            </p>
          )}
        </div>
      )}

      <div className="overflow-hidden rounded-lg border border-slate-200 bg-white">
        {loading ? (
          <p className="px-4 py-10 text-center text-sm text-slate-500">
            Loading…
          </p>
        ) : error ? (
          <p className="px-4 py-10 text-center text-sm text-red-600">
            {error}
          </p>
        ) : !rows || rows.length === 0 ? (
          <p className="px-4 py-10 text-center text-sm text-slate-500">
            No payout activity for this pay period.
          </p>
        ) : (
          <table className="min-w-full divide-y divide-slate-200 text-sm">
            <thead className="bg-slate-50 text-left text-xs font-medium uppercase tracking-wide text-slate-500">
              <tr>
                <th className="px-4 py-2">Employee</th>
                <th className="px-4 py-2 text-right">Entries</th>
                <th className="px-4 py-2 text-right">Commission</th>
                <th className="px-4 py-2 text-right">Draw</th>
                {showSpiffsCol && (
                  <th className="px-4 py-2 text-right">Spiffs</th>
                )}
                <th className="px-4 py-2 text-right">Pay</th>
                {canManage === true && <th className="px-4 py-2" />}
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {rows.map((r) => (
                <tr key={r.employee_id}>
                  <td className="px-4 py-2 font-medium text-slate-800">
                    {r.employee_name ?? "Unknown"}
                  </td>
                  <td className="px-4 py-2 text-right tabular-nums text-slate-600">
                    {r.entry_count}
                  </td>
                  <td className="px-4 py-2 text-right tabular-nums">
                    <span
                      className={
                        r.commission_cents < 0
                          ? "text-red-600"
                          : "text-slate-800"
                      }
                    >
                      {money(r.commission_cents)}
                    </span>
                    {r.not_calculated_count > 0 && (
                      <span
                        className="ml-2 rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-800"
                        title="These items had no cost or no plan, so no commission could be calculated."
                      >
                        {r.not_calculated_count} not calculated
                      </span>
                    )}
                  </td>
                  <td className="px-4 py-2 text-right tabular-nums text-slate-800">
                    {money(r.draw_cents)}
                    {r.draw_cents > 0 && (
                      <span className="mt-1 block">
                        <span className="block h-1.5 w-full rounded-full bg-slate-100">
                          <span
                            className={`block h-1.5 rounded-full ${
                              r.commission_cents >= r.draw_cents
                                ? "bg-green-500"
                                : "bg-slate-400"
                            }`}
                            style={{
                              width: `${Math.min(Math.max(r.commission_cents, 0) / r.draw_cents, 1) * 100}%`,
                            }}
                          />
                        </span>
                        <span className="block text-xs text-slate-400">
                          {r.commission_cents >= r.draw_cents
                            ? `Over draw by ${money(r.commission_cents - r.draw_cents)}`
                            : `${money(r.draw_cents - r.commission_cents)} to cover draw`}
                        </span>
                      </span>
                    )}
                    {r.draw_covers_cents > 0 && (
                      <span className="block text-xs text-slate-400">
                        Draw covers {money(r.draw_covers_cents)}
                      </span>
                    )}
                  </td>
                  {showSpiffsCol && (
                    <td className="px-4 py-2 text-right tabular-nums text-slate-800">
                      {r.spiff_month_start ? money(r.spiffs_cents) : "-"}
                      {r.spiffs_negative_not_deducted && (
                        <span className="block text-xs font-normal text-slate-400">
                          Net negative, not deducted
                        </span>
                      )}
                    </td>
                  )}
                  <td className="px-4 py-2 text-right font-semibold tabular-nums text-slate-900">
                    {money(r.pay_cents)}
                  </td>
                  {canManage === true && (
                    <td className="px-4 py-2 text-right">
                      <button
                        onClick={() =>
                          setDrawTarget({
                            employee_id: r.employee_id,
                            name: r.employee_name ?? "this employee",
                            draw_cents: r.draw_cents,
                          })
                        }
                        className="text-sm font-medium text-brand-600 hover:underline"
                      >
                        Set draw
                      </button>
                    </td>
                  )}
                </tr>
              ))}
              <tr className="bg-slate-50 font-medium text-slate-800">
                <td className="px-4 py-2">Total</td>
                <td className="px-4 py-2 text-right" />
                <td className="px-4 py-2 text-right tabular-nums">
                  {money(totals.commission)}
                </td>
                <td className="px-4 py-2 text-right tabular-nums">
                  {money(totals.draw)}
                </td>
                {showSpiffsCol && (
                  <td className="px-4 py-2 text-right tabular-nums">
                    {money(totals.spiffs)}
                  </td>
                )}
                <td className="px-4 py-2 text-right font-semibold tabular-nums">
                  {money(totals.pay)}
                </td>
                {canManage === true && <td className="px-4 py-2" />}
              </tr>
            </tbody>
          </table>
        )}
      </div>

      {canManage === true && (
        <button
          onClick={() => {
            ensureEmployees();
            setDrawTarget("pick");
          }}
          className="mt-3 text-sm font-medium text-brand-600 hover:underline"
        >
          Set draw for another employee
        </button>
      )}

      {closes && closes.length > 0 && (
        <div className="mt-6">
          <h2 className="mb-2 text-sm font-semibold text-slate-700">
            Past periods
          </h2>
          <div className="overflow-hidden rounded-lg border border-slate-200 bg-white">
            <table className="min-w-full divide-y divide-slate-200 text-sm">
              <tbody className="divide-y divide-slate-100">
                {closes.map((c) => (
                  <tr
                    key={c.close_id}
                    onClick={() => loadPeriod(c.period_start)}
                    className="cursor-pointer hover:bg-slate-50"
                  >
                    <td className="px-4 py-2 text-slate-800">
                      {shortDate(c.period_start)} -{" "}
                      {shortDate(c.period_end)}
                    </td>
                    <td className="px-4 py-2 text-slate-500">
                      Closed by {c.closed_by_name ?? "unknown"}
                    </td>
                    <td className="px-4 py-2">
                      {c.reopened_at && (
                        <span
                          className="rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600"
                          title={c.reopen_reason ?? undefined}
                        >
                          Reopened
                          {c.reopen_reason ? `: ${c.reopen_reason}` : ""}
                        </span>
                      )}
                    </td>
                    <td className="px-4 py-2 text-right tabular-nums font-medium text-slate-800">
                      {money(c.total_pay_cents)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {drawTarget !== null && (
        <DrawModal
          target={drawTarget}
          periodStart={period?.start ?? null}
          employees={employees ?? []}
          onClose={() => setDrawTarget(null)}
          onSaved={(msg) => {
            setDrawTarget(null);
            setNotice(msg);
            refetchAll();
          }}
        />
      )}

      {confirmClose && period && (
        <Modal onClose={() => setConfirmClose(false)}>
          <ClosePeriodModalBody
            periodStart={period.start}
            periodEnd={period.end}
            onClose={() => setConfirmClose(false)}
            onSaved={(msg) => {
              setConfirmClose(false);
              setNotice(msg);
              refetchAll();
            }}
          />
        </Modal>
      )}

      {confirmReopen && period && (
        <Modal onClose={() => setConfirmReopen(false)}>
          <ReopenPeriodModalBody
            periodStart={period.start}
            onClose={() => setConfirmReopen(false)}
            onSaved={(msg) => {
              setConfirmReopen(false);
              setNotice(msg);
              refetchAll();
            }}
          />
        </Modal>
      )}
    </div>
  );
}

// ----------------------------------------------------------------------------
// Set draw modal. "pick" mode (from "Set draw for another employee") shows
// an employee dropdown first and prefills the amount from that employee's
// newest draw row once selected.
// ----------------------------------------------------------------------------

function DrawModal({
  target,
  periodStart,
  employees,
  onClose,
  onSaved,
}: {
  target: DrawTarget | "pick";
  periodStart: string | null;
  employees: Employee[];
  onClose: () => void;
  onSaved: (msg: string) => void;
}) {
  const isPick = target === "pick";
  const [picked, setPicked] = useState<DrawTarget | null>(
    isPick ? null : target
  );
  const [amount, setAmount] = useState<number | null>(
    isPick ? null : target.draw_cents / 100
  );
  const [effectiveFrom, setEffectiveFrom] = useState(
    periodStart ?? localTodayISO()
  );
  const [note, setNote] = useState("");
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [history, setHistory] = useState<DrawRow[] | null>(null);
  const [historyLoading, setHistoryLoading] = useState(false);
  const [historyError, setHistoryError] = useState<string | null>(null);

  const loadHistory = useCallback(async (employeeId: string) => {
    setHistoryLoading(true);
    setHistoryError(null);
    const supabase = createClient();
    const { data, error } = await supabase.rpc("list_employee_draws", {
      p_employee_id: employeeId,
    });
    if (error) {
      setHistory(null);
      setHistoryError(error.message);
    } else {
      setHistory((data as DrawRow[]) ?? []);
    }
    setHistoryLoading(false);
  }, []);

  // Pick mode: when an employee is chosen, pull their draw history to
  // prefill the amount from the newest row and prime the history list.
  const pickEmployee = async (employeeId: string) => {
    const emp = employees.find((e) => e.id === employeeId);
    if (!emp) return;
    setPicked({ employee_id: emp.id, name: emp.name, draw_cents: 0 });
    setHistoryLoading(true);
    const supabase = createClient();
    const { data } = await supabase.rpc("list_employee_draws", {
      p_employee_id: emp.id,
    });
    const list = (data as DrawRow[]) ?? [];
    setHistory(list);
    setHistoryLoading(false);
    if (list.length > 0) {
      setAmount(list[0].amount_cents / 100);
    }
  };

  const save = async () => {
    if (!picked || amount == null || amount < 0 || !effectiveFrom) return;
    setSaving(true);
    setErr(null);
    const supabase = createClient();
    const { error } = await supabase.rpc("set_employee_draw", {
      p_employee_id: picked.employee_id,
      p_amount_cents: Math.round(amount * 100),
      p_effective_from: effectiveFrom,
      p_note: note.trim() === "" ? null : note.trim(),
    });
    setSaving(false);
    if (error) {
      setErr(error.message);
      return;
    }
    onSaved(`Draw saved for ${picked.name}.`);
  };

  return (
    <Modal onClose={onClose} dirty saving={saving}>
      <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-xl">
        <h3 className="mb-3 text-base font-semibold text-slate-900">
          Set draw{isPick ? "" : ` for ${picked?.name ?? ""}`}
        </h3>

        {isPick && (
          <label className="mb-3 block text-sm">
            <span className="mb-1 block font-medium text-slate-700">
              Employee
            </span>
            <select
              value={picked?.employee_id ?? ""}
              onChange={(e) => pickEmployee(e.target.value)}
              className="w-full rounded-md border border-slate-300 px-2 py-1.5 text-sm"
            >
              <option value="" disabled>
                Choose an employee
              </option>
              {employees.map((e) => (
                <option key={e.id} value={e.id}>
                  {e.name}
                </option>
              ))}
            </select>
          </label>
        )}

        <label className="mb-3 block text-sm">
          <span className="mb-1 block font-medium text-slate-700">
            Draw per pay period ($)
          </span>
          <DollarInput
            value={amount}
            onChange={setAmount}
            autoFocus={!isPick}
          />
        </label>

        <label className="mb-1 block text-sm">
          <span className="mb-1 block font-medium text-slate-700">
            Effective from
          </span>
          <input
            type="date"
            value={effectiveFrom}
            onChange={(e) => setEffectiveFrom(e.target.value)}
            className="w-full rounded-md border border-slate-300 px-2 py-1 text-sm"
          />
        </label>
        <p className="mb-3 text-xs text-slate-500">
          A draw applies to pay periods that start on or after this date.
          Earlier periods are not changed.
        </p>

        <label className="mb-3 block text-sm">
          <span className="mb-1 block font-medium text-slate-700">
            Note <span className="font-normal text-slate-400">(optional)</span>
          </span>
          <input
            type="text"
            value={note}
            onChange={(e) => setNote(e.target.value)}
            className="w-full rounded-md border border-slate-300 px-2 py-1 text-sm"
          />
        </label>

        {picked && (
          <button
            onClick={() => loadHistory(picked.employee_id)}
            className="mb-3 text-sm font-medium text-brand-600 hover:underline"
          >
            Draw history
          </button>
        )}

        {historyLoading && (
          <p className="mb-3 text-xs text-slate-500">Loading history…</p>
        )}
        {historyError && (
          <p className="mb-3 text-xs text-red-600">{historyError}</p>
        )}
        {history && history.length === 0 && !historyLoading && (
          <p className="mb-3 text-xs text-slate-500">
            No draws on record for this employee.
          </p>
        )}
        {history && history.length > 0 && (
          <ul className="mb-3 max-h-40 space-y-1 overflow-y-auto rounded-md border border-slate-200 p-2 text-xs text-slate-600">
            {history.map((d) => (
              <li key={d.draw_id}>
                <span className="font-medium text-slate-800">
                  {money(d.amount_cents)}
                </span>{" "}
                from {shortDate(d.effective_from)}
                {d.note ? ` - ${d.note}` : ""}
                <span className="text-slate-400">
                  {" "}
                  (by {d.created_by_name ?? "unknown"},{" "}
                  {shortDate(d.created_at)})
                </span>
              </li>
            ))}
          </ul>
        )}

        {err && <p className="mb-3 text-sm text-red-600">{err}</p>}

        <div className="flex justify-end gap-2">
          <button
            onClick={onClose}
            className="rounded-md border border-slate-300 px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50"
          >
            Cancel
          </button>
          <button
            onClick={save}
            disabled={
              saving || !picked || amount == null || amount < 0 || !effectiveFrom
            }
            className="rounded-md bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
          >
            {saving ? "Saving…" : "Save draw"}
          </button>
        </div>
      </div>
    </Modal>
  );
}

function ClosePeriodModalBody({
  periodStart,
  periodEnd,
  onClose,
  onSaved,
}: {
  periodStart: string;
  periodEnd: string;
  onClose: () => void;
  onSaved: (msg: string) => void;
}) {
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const notEnded = localTodayISO() < periodEnd;

  const close = async () => {
    setSaving(true);
    setErr(null);
    const supabase = createClient();
    const { error } = await supabase.rpc("close_commission_period", {
      p_date: periodStart,
    });
    setSaving(false);
    if (error) {
      setErr(error.message);
      return;
    }
    onSaved("Pay period closed. The numbers are now frozen.");
  };

  return (
    <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-xl">
      <h3 className="mb-3 text-base font-semibold text-slate-900">
        Close pay period
      </h3>
      <p className="mb-4 text-sm text-slate-600">
        {notEnded
          ? "This pay period has not ended yet. Items picked up later will not be included. Close anyway?"
          : "Close this pay period? The numbers will be frozen."}
      </p>
      {err && <p className="mb-3 text-sm text-red-600">{err}</p>}
      <div className="flex justify-end gap-2">
        <button
          onClick={onClose}
          className="rounded-md border border-slate-300 px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50"
        >
          Cancel
        </button>
        <button
          onClick={close}
          disabled={saving}
          className="rounded-md bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
        >
          {saving ? "Closing…" : "Close period"}
        </button>
      </div>
    </div>
  );
}

function ReopenPeriodModalBody({
  periodStart,
  onClose,
  onSaved,
}: {
  periodStart: string;
  onClose: () => void;
  onSaved: (msg: string) => void;
}) {
  const [reason, setReason] = useState("");
  const [saving, setSaving] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  const reopen = async () => {
    if (reason.trim() === "") return;
    setSaving(true);
    setErr(null);
    const supabase = createClient();
    const { error } = await supabase.rpc("reopen_commission_period", {
      p_date: periodStart,
      p_reason: reason.trim(),
    });
    setSaving(false);
    if (error) {
      setErr(error.message);
      return;
    }
    onSaved("Pay period reopened. Live numbers are showing again.");
  };

  return (
    <div className="w-full max-w-md rounded-lg bg-white p-5 shadow-xl">
      <h3 className="mb-3 text-base font-semibold text-slate-900">
        Reopen pay period
      </h3>
      <p className="mb-3 text-sm text-slate-600">
        Reopening shows live numbers again. The earlier close stays in
        history.
      </p>
      <label className="mb-3 block text-sm">
        <span className="mb-1 block font-medium text-slate-700">
          Reason <span className="text-red-600">*</span>
        </span>
        <input
          type="text"
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          autoFocus
          className="w-full rounded-md border border-slate-300 px-2 py-1 text-sm"
        />
      </label>
      {err && <p className="mb-3 text-sm text-red-600">{err}</p>}
      <div className="flex justify-end gap-2">
        <button
          onClick={onClose}
          className="rounded-md border border-slate-300 px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50"
        >
          Cancel
        </button>
        <button
          onClick={reopen}
          disabled={saving || reason.trim() === ""}
          className="rounded-md bg-brand-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-brand-700 disabled:opacity-50"
        >
          {saving ? "Reopening…" : "Reopen period"}
        </button>
      </div>
    </div>
  );
}
