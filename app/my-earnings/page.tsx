"use client";

// Rep-facing commission and spiff statement. Every number comes from
// get_my_earnings / get_my_spiffs, which resolve the caller server-side
// and only ever return the signed-in employee's own rows. Detail columns
// (revenue, rate, profit, cost) render only when the company switch for
// them is on AND the response actually carries the key, so a hidden
// field can never be implied client-side.

import { useCallback, useEffect, useMemo, useState } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { localDateISO, localTodayISO } from "@/lib/dates";

type EarningsLine = {
  entry_id: string;
  earned_date: string;
  journey_id: string | null;
  journey_number: string | null;
  item_name: string | null;
  kind: string;
  amount_cents: number | null;
  pending: boolean;
  revenue_cents?: number | null;
  rate_bp?: number | null;
  credit_share_bp?: number | null;
  profit_cents?: number | null;
  cost_cents?: number | null;
};

type MyEarnings = {
  period_start: string;
  period_end: string;
  is_closed: boolean;
  lines: EarningsLine[];
  total_cents: number;
  pending_count: number;
  draw_progress: {
    draw_cents: number;
    commission_cents: number;
  } | null;
  visibility: {
    earnings_show_revenue: boolean;
    earnings_show_rate: boolean;
    earnings_show_profit: boolean;
    earnings_show_cost: boolean;
    earnings_show_draw_progress: boolean;
  };
};

type SpiffLine = {
  entry_id: string;
  earned_date: string;
  label: string | null;
  journey_number: string | null;
  amount_cents: number | null;
};

type MySpiffs = {
  month_start: string;
  month_end: string;
  lines: SpiffLine[];
  total_cents: number;
};

type SpiffSettings = {
  spiffs_enabled: boolean;
  google_reviews_enabled: boolean;
};

function money(cents: number | null | undefined): string {
  if (cents == null) return "-";
  const sign = cents < 0 ? "-" : "";
  return `${sign}$${(Math.abs(cents) / 100).toFixed(2)}`;
}

function shortDate(iso: string | null | undefined): string {
  if (!iso) return "";
  return new Date(`${iso.slice(0, 10)}T00:00:00`).toLocaleDateString(
    undefined,
    { month: "short", day: "numeric", year: "numeric" }
  );
}

function addDaysISO(iso: string, days: number): string {
  const d = new Date(`${iso}T00:00:00`);
  d.setDate(d.getDate() + days);
  return localDateISO(d);
}

function bpToPct(bp: number | null | undefined): string {
  if (bp == null) return "-";
  return `${Number((bp / 100).toFixed(2))}%`;
}

export default function MyEarningsPage() {
  // undefined means still loading; null means the RPC answered with no
  // data (no employee row for this account).
  const [earnings, setEarnings] = useState<MyEarnings | null | undefined>(
    undefined
  );
  const [earningsError, setEarningsError] = useState<string | null>(null);
  const [spiffs, setSpiffs] = useState<MySpiffs | null | undefined>(
    undefined
  );
  const [spiffsError, setSpiffsError] = useState<string | null>(null);
  const [spiffSettings, setSpiffSettings] = useState<
    SpiffSettings | null | undefined
  >(undefined);

  const supabase = useMemo(() => createClient(), []);
  const today = localTodayISO();

  const loadEarnings = useCallback(
    async (d: string) => {
      setEarnings(undefined);
      setEarningsError(null);
      const { data, error } = await supabase.rpc("get_my_earnings", {
        p_date: d,
      });
      if (error) {
        setEarnings(null);
        setEarningsError(error.message);
      } else {
        setEarnings((data as MyEarnings | null) ?? null);
      }
    },
    [supabase]
  );

  const loadSpiffs = useCallback(
    async (d: string) => {
      setSpiffs(undefined);
      setSpiffsError(null);
      const { data, error } = await supabase.rpc("get_my_spiffs", {
        p_month: d,
      });
      if (error) {
        setSpiffs(null);
        setSpiffsError(error.message);
      } else {
        setSpiffs((data as MySpiffs | null) ?? null);
      }
    },
    [supabase]
  );

  useEffect(() => {
    loadEarnings(today);
    loadSpiffs(today);
    supabase.rpc("get_spiff_settings").then(({ data, error }) => {
      setSpiffSettings(
        error ? null : ((data as SpiffSettings | null) ?? null)
      );
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const vis = earnings?.visibility;
  const hasKey = (key: keyof EarningsLine) =>
    (earnings?.lines ?? []).some((l) => key in l);
  const showRevenue =
    vis?.earnings_show_revenue === true && hasKey("revenue_cents");
  const showRate = vis?.earnings_show_rate === true && hasKey("rate_bp");
  const showProfit =
    vis?.earnings_show_profit === true && hasKey("profit_cents");
  const showCost = vis?.earnings_show_cost === true && hasKey("cost_cents");

  const containsToday =
    earnings != null &&
    today >= earnings.period_start &&
    today <= earnings.period_end;

  const showSpiffsSection =
    spiffSettings?.spiffs_enabled === true ||
    spiffSettings?.google_reviews_enabled === true ||
    (spiffs?.lines?.length ?? 0) > 0;

  return (
    <div className="mx-auto max-w-3xl p-6">
      <h1 className="mb-4 text-xl font-semibold text-slate-900">
        My Earnings
      </h1>

      {earningsError && (
        <div className="mb-4 rounded-lg border border-red-200 bg-red-50 px-4 py-6 text-center">
          <p className="text-sm text-red-700">{earningsError}</p>
          <button
            onClick={() => loadEarnings(today)}
            className="mt-3 rounded-md border border-red-300 px-3 py-1.5 text-sm text-red-700 hover:bg-red-100"
          >
            Try again
          </button>
        </div>
      )}

      {!earningsError && earnings === undefined && (
        <p className="py-10 text-center text-sm text-slate-500">Loading…</p>
      )}

      {!earningsError && earnings === null && (
        <p className="py-10 text-center text-sm text-slate-500">
          No earnings to show for this account.
        </p>
      )}

      {!earningsError && earnings != null && (
        <>
          {/* ---------- period bar ---------- */}
          <div className="mb-4 flex flex-wrap items-center gap-3">
            <button
              onClick={() =>
                loadEarnings(addDaysISO(earnings.period_start, -1))
              }
              className="rounded-md border border-slate-300 px-2.5 py-1.5 text-sm text-slate-600 hover:bg-slate-50"
            >
              Prev
            </button>
            <span className="text-sm font-medium text-slate-900">
              {shortDate(earnings.period_start)} -{" "}
              {shortDate(earnings.period_end)}
            </span>
            <button
              onClick={() =>
                loadEarnings(addDaysISO(earnings.period_end, 1))
              }
              disabled={containsToday}
              className="rounded-md border border-slate-300 px-2.5 py-1.5 text-sm text-slate-600 hover:bg-slate-50 disabled:opacity-40"
            >
              Next
            </button>
            <span
              className={`rounded-full px-2.5 py-0.5 text-xs font-medium ${
                earnings.is_closed
                  ? "bg-slate-200 text-slate-700"
                  : "bg-green-100 text-green-800"
              }`}
            >
              {earnings.is_closed ? "Closed" : "Open"}
            </span>
          </div>

          {/* ---------- lines ---------- */}
          <div className="overflow-hidden rounded-lg border border-slate-200 bg-white">
            <table className="min-w-full divide-y divide-slate-200 text-sm">
              <thead className="bg-slate-50 text-left text-xs font-medium uppercase tracking-wide text-slate-500">
                <tr>
                  <th className="px-4 py-2">Date</th>
                  <th className="px-4 py-2">Order</th>
                  <th className="px-4 py-2">Item</th>
                  {showRevenue && (
                    <th className="px-4 py-2 text-right">Revenue</th>
                  )}
                  {showRate && <th className="px-4 py-2 text-right">Rate</th>}
                  {showProfit && (
                    <th className="px-4 py-2 text-right">Profit</th>
                  )}
                  {showCost && <th className="px-4 py-2 text-right">Cost</th>}
                  <th className="px-4 py-2 text-right">Amount</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {earnings.lines.length === 0 && (
                  <tr>
                    <td
                      colSpan={8}
                      className="px-4 py-10 text-center text-sm text-slate-500"
                    >
                      No sales earned in this period yet.
                    </td>
                  </tr>
                )}
                {earnings.lines.map((l) => (
                  <tr key={l.entry_id}>
                    <td className="px-4 py-2 text-slate-600">
                      {shortDate(l.earned_date)}
                    </td>
                    <td className="px-4 py-2 text-slate-600">
                      {l.journey_id ? (
                        <Link
                          href={`/board?journey=${l.journey_id}`}
                          className="text-brand-700 hover:underline"
                        >
                          {l.journey_number}
                        </Link>
                      ) : (
                        (l.journey_number ?? "-")
                      )}
                    </td>
                    <td className="px-4 py-2 text-slate-600">
                      {l.item_name ??
                        (l.kind === "ADJUSTMENT" ? "Adjustment" : "-")}
                    </td>
                    {showRevenue && (
                      <td className="px-4 py-2 text-right tabular-nums text-slate-600">
                        {l.pending ? "-" : money(l.revenue_cents)}
                      </td>
                    )}
                    {showRate && (
                      <td className="px-4 py-2 text-right tabular-nums text-slate-600">
                        {l.pending ? (
                          "-"
                        ) : (
                          <>
                            {bpToPct(l.rate_bp)}
                            {l.credit_share_bp != null &&
                              l.credit_share_bp !== 10000 && (
                                <span className="text-slate-400">
                                  {" "}
                                  ({bpToPct(l.credit_share_bp)} share)
                                </span>
                              )}
                          </>
                        )}
                      </td>
                    )}
                    {showProfit && (
                      <td className="px-4 py-2 text-right tabular-nums text-slate-600">
                        {l.pending ? "-" : money(l.profit_cents)}
                      </td>
                    )}
                    {showCost && (
                      <td className="px-4 py-2 text-right tabular-nums text-slate-600">
                        {l.pending ? "-" : money(l.cost_cents)}
                      </td>
                    )}
                    <td className="px-4 py-2 text-right tabular-nums text-slate-800">
                      {l.pending ? (
                        <span className="rounded-full bg-slate-200 px-2.5 py-0.5 text-xs font-medium text-slate-600">
                          Not calculated yet
                        </span>
                      ) : (
                        money(l.amount_cents)
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
              {earnings.lines.length > 0 && (
                <tfoot className="border-t border-slate-200 bg-slate-50">
                  <tr>
                    <td
                      colSpan={3}
                      className="px-4 py-2 text-sm font-medium text-slate-700"
                    >
                      Period total
                    </td>
                    {showRevenue && <td />}
                    {showRate && <td />}
                    {showProfit && <td />}
                    {showCost && <td />}
                    <td className="px-4 py-2 text-right font-semibold tabular-nums text-slate-900">
                      {money(earnings.total_cents)}
                    </td>
                  </tr>
                </tfoot>
              )}
            </table>
          </div>
          {earnings.pending_count > 0 && (
            <p className="mt-2 text-xs text-slate-500">
              {earnings.pending_count}{" "}
              {earnings.pending_count === 1 ? "sale" : "sales"} not
              calculated yet. Your total will update.
            </p>
          )}

          {/* ---------- draw progress ---------- */}
          {earnings.draw_progress != null &&
            earnings.draw_progress.draw_cents > 0 && (
              <div className="mt-4 max-w-sm">
                <div className="h-1.5 w-full rounded-full bg-slate-100">
                  <div
                    className={`h-1.5 rounded-full ${
                      earnings.draw_progress.commission_cents >=
                      earnings.draw_progress.draw_cents
                        ? "bg-green-500"
                        : "bg-slate-400"
                    }`}
                    style={{
                      width: `${
                        Math.min(
                          Math.max(
                            earnings.draw_progress.commission_cents,
                            0
                          ) / earnings.draw_progress.draw_cents,
                          1
                        ) * 100
                      }%`,
                    }}
                  />
                </div>
                <p className="mt-1 text-xs text-slate-500">
                  {earnings.draw_progress.commission_cents >=
                  earnings.draw_progress.draw_cents
                    ? `Over draw by ${money(
                        earnings.draw_progress.commission_cents -
                          earnings.draw_progress.draw_cents
                      )}`
                    : `${money(
                        earnings.draw_progress.draw_cents -
                          earnings.draw_progress.commission_cents
                      )} to cover draw`}
                </p>
              </div>
            )}
        </>
      )}

      {/* ---------- spiffs this month ---------- */}
      {showSpiffsSection && (
        <div className="mt-8">
          <div className="mb-3 flex flex-wrap items-center gap-3">
            <h2 className="text-sm font-semibold text-slate-900">
              Spiffs this month
            </h2>
            {spiffs != null && (
              <>
                <button
                  onClick={() =>
                    loadSpiffs(addDaysISO(spiffs.month_start, -1))
                  }
                  className="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-600 hover:bg-slate-50"
                >
                  Prev
                </button>
                <span className="text-xs text-slate-500">
                  {shortDate(spiffs.month_start)} -{" "}
                  {shortDate(spiffs.month_end)}
                </span>
                <button
                  onClick={() => loadSpiffs(addDaysISO(spiffs.month_end, 1))}
                  disabled={
                    today >= spiffs.month_start && today <= spiffs.month_end
                  }
                  className="rounded-md border border-slate-300 px-2 py-1 text-xs text-slate-600 hover:bg-slate-50 disabled:opacity-40"
                >
                  Next
                </button>
              </>
            )}
          </div>
          {spiffsError ? (
            <p className="rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700">
              {spiffsError}
            </p>
          ) : spiffs === undefined ? (
            <p className="py-4 text-sm text-slate-500">Loading…</p>
          ) : spiffs === null || spiffs.lines.length === 0 ? (
            <p className="py-4 text-sm text-slate-500">
              No spiffs earned this month.
            </p>
          ) : (
            <div className="overflow-hidden rounded-lg border border-slate-200 bg-white">
              <table className="min-w-full divide-y divide-slate-200 text-sm">
                <thead className="bg-slate-50 text-left text-xs font-medium uppercase tracking-wide text-slate-500">
                  <tr>
                    <th className="px-4 py-2">Date</th>
                    <th className="px-4 py-2">Order</th>
                    <th className="px-4 py-2">Label</th>
                    <th className="px-4 py-2 text-right">Amount</th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-slate-100">
                  {spiffs.lines.map((l) => (
                    <tr key={l.entry_id}>
                      <td className="px-4 py-2 text-slate-600">
                        {shortDate(l.earned_date)}
                      </td>
                      <td className="px-4 py-2 text-slate-600">
                        {l.journey_number ?? "-"}
                      </td>
                      <td className="px-4 py-2 text-slate-600">
                        {l.label ?? "Spiff"}
                      </td>
                      <td className="px-4 py-2 text-right tabular-nums text-slate-800">
                        {money(l.amount_cents)}
                      </td>
                    </tr>
                  ))}
                </tbody>
                <tfoot className="border-t border-slate-200 bg-slate-50">
                  <tr>
                    <td
                      colSpan={3}
                      className="px-4 py-2 text-sm font-medium text-slate-700"
                    >
                      Month total
                    </td>
                    <td className="px-4 py-2 text-right font-semibold tabular-nums text-slate-900">
                      {money(spiffs.total_cents)}
                    </td>
                  </tr>
                </tfoot>
              </table>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
