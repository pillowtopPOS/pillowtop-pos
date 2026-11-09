"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { ChevronLeft, ChevronRight } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import {
  fetchDeliveryCalendar,
  fetchDeliveryBusinessToday,
  fetchDeliveryManageTrucks,
  setTruckDateState,
  type DeliveryCalendar,
  type DeliveryCalendarDay,
  type DeliveryTruckDay,
  type DeliveryTruckInfo,
} from "@/lib/delivery/queries";

const WEEKDAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const MONTHS = [
  "Jan", "Feb", "Mar", "Apr", "May", "Jun",
  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

// All date math is done in UTC on YYYY-MM-DD strings so the browser's own
// timezone can never shift a day. The "today" anchor comes from the
// server-side business_today RPC (home store timezone), not the clock.
function parseDay(iso: string): Date {
  return new Date(`${iso}T00:00:00Z`);
}

function toISODay(d: Date): string {
  return d.toISOString().slice(0, 10);
}

function addDays(iso: string, n: number): string {
  const d = parseDay(iso);
  d.setUTCDate(d.getUTCDate() + n);
  return toISODay(d);
}

// Monday of the week containing iso.
function mondayOf(iso: string): string {
  const d = parseDay(iso);
  const dow = (d.getUTCDay() + 6) % 7; // Mon=0 .. Sun=6
  d.setUTCDate(d.getUTCDate() - dow);
  return toISODay(d);
}

function dayLabel(iso: string): { weekday: string; dayNum: number; month: string } {
  const d = parseDay(iso);
  return {
    weekday: WEEKDAYS[(d.getUTCDay() + 6) % 7],
    dayNum: d.getUTCDate(),
    month: MONTHS[d.getUTCMonth()],
  };
}

function rangeLabel(startIso: string, endIso: string): string {
  const s = parseDay(startIso);
  const e = parseDay(endIso);
  const sameMonth = s.getUTCMonth() === e.getUTCMonth();
  const sPart = `${MONTHS[s.getUTCMonth()]} ${s.getUTCDate()}`;
  const ePart = sameMonth
    ? `${e.getUTCDate()}`
    : `${MONTHS[e.getUTCMonth()]} ${e.getUTCDate()}`;
  return `${sPart} to ${ePart}, ${e.getUTCFullYear()}`;
}

function Cell({
  truck,
  iso,
  day,
  canManage,
  saving,
  onToggle,
}: {
  truck: DeliveryTruckInfo;
  iso: string;
  day?: DeliveryCalendarDay;
  canManage: boolean;
  saving: boolean;
  onToggle: (truckId: string, iso: string, entry: DeliveryTruckDay) => void;
}) {
  const entry: DeliveryTruckDay | undefined = day?.trucks.find(
    (t) => t.truck_id === truck.id
  );
  if (!entry) {
    return <td className="border border-slate-200 px-3 py-2 text-center text-slate-300">—</td>;
  }
  const tooltip = entry.source === "exception"
    ? "Click to go back to the usual schedule"
    : entry.on
      ? "Click to turn off for this day"
      : "Click to turn on for this day";
  return (
    <td className="border border-slate-200 p-0 text-center">
      <button
        type="button"
        disabled={!canManage || saving}
        title={canManage ? tooltip : undefined}
        onClick={() => onToggle(truck.id, iso, entry)}
        className={`flex w-full items-center justify-center gap-1.5 px-3 py-2 ${
          canManage
            ? "cursor-pointer hover:bg-slate-100"
            : "cursor-default"
        } ${saving ? "opacity-50" : ""}`}
      >
        {entry.source === "exception" && (
          <span
            className="inline-block h-2 w-2 rounded-full bg-amber-500"
            title="Changed for this date"
          />
        )}
        <span className={entry.on ? "font-medium text-slate-800" : "text-slate-400"}>
          {entry.on ? `On · ${entry.stop_cap}` : "Off"}
        </span>
      </button>
    </td>
  );
}

export default function DeliveryPage() {
  const router = useRouter();
  const [calendar, setCalendar] = useState<DeliveryCalendar | null>(null);
  const [weekStart, setWeekStart] = useState<string | null>(null);
  const [canManageTrucks, setCanManageTrucks] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [savingCells, setSavingCells] = useState<Set<string>>(new Set());
  const [cellError, setCellError] = useState<string | null>(null);
  const weekStartRef = useRef<string | null>(null);

  const load = useCallback(async (startIso: string) => {
    setLoading(true);
    setError(null);
    try {
      const cal = await fetchDeliveryCalendar(startIso, addDays(startIso, 6));
      setCalendar(cal);
    } catch {
      setError("We couldn't load the delivery calendar. Please try again.");
      setCalendar(null);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getSession().then(async ({ data: { session } }) => {
      if (!session?.user) {
        router.push("/login");
        return;
      }
      // Anchor the first week on the business date in the caller's home
      // store timezone — the browser clock is only a fallback.
      const today = (await fetchDeliveryBusinessToday()) ?? toISODay(new Date());
      const start = mondayOf(today);
      weekStartRef.current = start;
      setWeekStart(start);
      const [cal, canManage] = await Promise.all([
        fetchDeliveryCalendar(start, addDays(start, 6)).catch(() => null),
        fetchDeliveryManageTrucks(),
      ]);
      if (cal === null) {
        setError("We couldn't load the delivery calendar. Please try again.");
      } else {
        setCalendar(cal);
      }
      setCanManageTrucks(canManage);
      setLoading(false);
    });
  }, [router]);

  const goTo = (startIso: string) => {
    weekStartRef.current = startIso;
    setWeekStart(startIso);
    load(startIso);
  };

  // One click: exception -> clear back to pattern; pattern cell -> set the
  // opposite state. Refetches whatever week is on screen now (via the ref)
  // so a mid-save week change can't paint stale data onto the wrong week.
  const toggleCell = async (
    truckId: string,
    iso: string,
    entry: DeliveryTruckDay
  ) => {
    if (!canManageTrucks) return;
    const key = `${truckId}|${iso}`;
    if (savingCells.has(key)) return;
    setCellError(null);
    setSavingCells((prev) => new Set(prev).add(key));
    try {
      await setTruckDateState(
        truckId,
        iso,
        entry.source === "exception" ? null : !entry.on
      );
      const current = weekStartRef.current;
      if (current) await load(current);
    } catch {
      setCellError("Couldn't update that day. Please try again.");
    } finally {
      setSavingCells((prev) => {
        const next = new Set(prev);
        next.delete(key);
        return next;
      });
    }
  };

  const days: string[] = weekStart
    ? Array.from({ length: 7 }, (_, i) => addDays(weekStart, i))
    : [];
  const dayByDate = new Map<string, DeliveryCalendarDay>(
    (calendar?.days ?? []).map((d) => [d.date, d])
  );
  const trucks = calendar?.trucks ?? [];
  const weekEnd = days[days.length - 1] ?? "";

  return (
    <div className="mx-auto max-w-6xl px-4 py-6">
      <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-xl font-semibold text-slate-900">Delivery</h1>
        <div className="flex items-center gap-2">
          <button
            onClick={() => weekStart && goTo(addDays(weekStart, -7))}
            disabled={!weekStart || loading}
            className="rounded-md border border-slate-300 p-1.5 text-slate-600 hover:bg-slate-50 disabled:opacity-40"
            aria-label="Previous week"
          >
            <ChevronLeft className="h-4 w-4" />
          </button>
          <button
            onClick={() => {
              const today = toISODay(new Date());
              // Prefer the business date when we can get it cheaply; the
              // week already on screen is fine otherwise.
              fetchDeliveryBusinessToday().then((t) =>
                goTo(mondayOf(t ?? today))
              );
            }}
            disabled={loading}
            className="rounded-md border border-slate-300 px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50 disabled:opacity-40"
          >
            Today
          </button>
          <button
            onClick={() => weekStart && goTo(addDays(weekStart, 7))}
            disabled={!weekStart || loading}
            className="rounded-md border border-slate-300 p-1.5 text-slate-600 hover:bg-slate-50 disabled:opacity-40"
            aria-label="Next week"
          >
            <ChevronRight className="h-4 w-4" />
          </button>
          <span className="ml-2 text-sm font-medium text-slate-700">
            {weekStart ? rangeLabel(weekStart, weekEnd) : ""}
          </span>
        </div>
      </div>

      {loading && (
        <p className="py-10 text-center text-sm text-slate-500">Loading…</p>
      )}

      {!loading && error && (
        <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-6 text-center">
          <p className="text-sm text-red-700">{error}</p>
          {weekStart && (
            <button
              onClick={() => load(weekStart)}
              className="mt-3 rounded-md border border-red-300 px-3 py-1.5 text-sm text-red-700 hover:bg-red-100"
            >
              Try again
            </button>
          )}
        </div>
      )}

      {!loading && !error && trucks.length === 0 && (
        <div className="rounded-lg border border-dashed border-slate-300 bg-white px-6 py-12 text-center">
          <p className="text-sm text-slate-600">
            No delivery trucks yet. Add your first truck to start planning
            delivery days.
          </p>
          {canManageTrucks && (
            <button
              type="button"
              title="Coming in the next update"
              className="mt-4 rounded-md bg-slate-900 px-4 py-2 text-sm font-medium text-white opacity-60"
            >
              Add truck
            </button>
          )}
        </div>
      )}

      {!loading && !error && trucks.length > 0 && (
        <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
          <table className="w-full min-w-[720px] border-collapse text-sm">
            <thead>
              <tr className="bg-slate-50">
                <th className="border border-slate-200 px-3 py-2 text-left font-medium text-slate-600">
                  Truck
                </th>
                {days.map((iso) => {
                  const d = dayByDate.get(iso);
                  const l = dayLabel(iso);
                  return (
                    <th
                      key={iso}
                      className="border border-slate-200 px-3 py-2 text-center font-medium text-slate-700"
                    >
                      <div>{l.weekday}</div>
                      <div className="text-xs font-normal text-slate-500">
                        {l.month} {l.dayNum}
                      </div>
                      {d && (
                        <div className="mt-0.5 text-xs font-normal text-slate-500">
                          {d.capacity} stop{d.capacity === 1 ? "" : "s"}, {d.booked_count} booked
                          {d.extra_slots !== 0 && (
                            <span className={d.extra_slots > 0 ? "text-emerald-600" : "text-red-600"}>
                              {" "}({d.extra_slots > 0 ? "+" : ""}
                              {d.extra_slots})
                            </span>
                          )}
                        </div>
                      )}
                    </th>
                  );
                })}
              </tr>
            </thead>
            <tbody>
              {trucks.map((truck) => (
                <tr key={truck.id}>
                  <td className="border border-slate-200 px-3 py-2">
                    <div className="font-medium text-slate-800">{truck.name}</div>
                    {truck.home_location_name && (
                      <div className="text-xs text-slate-500">
                        {truck.home_location_name}
                      </div>
                    )}
                  </td>
                  {days.map((iso) => (
                    <Cell
                      key={iso}
                      truck={truck}
                      iso={iso}
                      day={dayByDate.get(iso)}
                      canManage={canManageTrucks}
                      saving={savingCells.has(`${truck.id}|${iso}`)}
                      onToggle={toggleCell}
                    />
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {!loading && !error && trucks.length > 0 && (
        <div className="mt-3 space-y-1">
          {cellError && (
            <p className="text-xs text-red-600">{cellError}</p>
          )}
          <p className="flex items-center gap-1.5 text-xs text-slate-500">
            <span className="inline-block h-2 w-2 rounded-full bg-amber-500" />
            Amber dot = this day differs from the truck&apos;s usual weekly
            pattern.
            {!canManageTrucks && " Only managers can change the delivery calendar."}
          </p>
        </div>
      )}
    </div>
  );
}
