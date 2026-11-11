"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { ChevronLeft, ChevronRight, Truck } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import TrucksPanel from "@/components/delivery/TrucksPanel";
import {
  fetchDeliveryCalendar,
  fetchDeliveryBusinessToday,
  fetchDeliveryManageTrucks,
  fetchDeliveryManageCalendar,
  setTruckDateState,
  setDayExtraSlots,
  fetchCompanyWeekStart,
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

// Start of the week containing iso. startDay is the ISO weekday the
// company's calendar week begins on: 1 = Monday, 7 = Sunday.
function weekStartOf(iso: string, startDay: number): string {
  const d = parseDay(iso);
  const isoDow = ((d.getUTCDay() + 6) % 7) + 1; // Mon=1 .. Sun=7
  d.setUTCDate(d.getUTCDate() - ((isoDow - startDay + 7) % 7));
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
  highlight,
  dimmed,
  onToggle,
}: {
  truck: DeliveryTruckInfo;
  iso: string;
  day?: DeliveryCalendarDay;
  canManage: boolean;
  saving: boolean;
  highlight?: boolean;
  dimmed?: boolean;
  onToggle: (truckId: string, iso: string, entry: DeliveryTruckDay) => void;
}) {
  const entry: DeliveryTruckDay | undefined = day?.trucks.find(
    (t) => t.truck_id === truck.id
  );
  const tdClass = `border border-slate-200 p-0 text-center${
    highlight ? " bg-amber-50" : ""
  }`;
  if (!entry) {
    return (
      <td className={`${tdClass} text-slate-300`}>
        <div className="px-3 py-2">—</div>
      </td>
    );
  }
  const tooltip = entry.source === "exception"
    ? "Click to go back to the usual schedule"
    : entry.on
      ? "Click to turn off for this day"
      : "Click to turn on for this day";
  return (
    <td className={tdClass}>
      <button
        type="button"
        disabled={!canManage || saving}
        title={canManage ? tooltip : undefined}
        onClick={() => onToggle(truck.id, iso, entry)}
        className={`flex w-full items-center justify-center gap-1.5 px-3 py-2 ${
          canManage
            ? "cursor-pointer hover:bg-slate-100"
            : "cursor-default"
        } ${saving ? "opacity-50" : ""} ${
          dimmed ? "opacity-60" : ""
        }`}
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

type ViewMode = "rolling" | "week";

export default function DeliveryPage() {
  const router = useRouter();
  const [calendar, setCalendar] = useState<DeliveryCalendar | null>(null);
  const [viewStart, setViewStart] = useState<string | null>(null);
  const [viewMode, setViewMode] = useState<ViewMode>("rolling");
  const [todayIso, setTodayIso] = useState<string | null>(null);
  const [canManageTrucks, setCanManageTrucks] = useState(false);
  const [canManageCalendar, setCanManageCalendar] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [savingCells, setSavingCells] = useState<Set<string>>(new Set());
  const [savingDays, setSavingDays] = useState<Set<string>>(new Set());
  const [cellError, setCellError] = useState<string | null>(null);
  const [panelOpen, setPanelOpen] = useState(false);
  const [panelAddMode, setPanelAddMode] = useState(false);
  const [weekStartDay, setWeekStartDay] = useState<1 | 7>(1);
  const viewStartRef = useRef<string | null>(null);
  const viewModeRef = useRef<ViewMode>("rolling");
  const weekStartDayRef = useRef<1 | 7>(1);
  const userIdRef = useRef<string | null>(null);
  // Monotonic request id — a slow response for an old window/mode must
  // never paint over the window the user is looking at now.
  const loadSeq = useRef(0);

  const load = useCallback(async (startIso: string) => {
    const seq = ++loadSeq.current;
    setLoading(true);
    setError(null);
    try {
      const cal = await fetchDeliveryCalendar(startIso, addDays(startIso, 6));
      if (seq !== loadSeq.current) return;
      setCalendar(cal);
      try {
        const uid = userIdRef.current;
        // Last-viewed week is remembered only in Calendar week mode.
        if (uid && viewModeRef.current === "week") {
          window.localStorage.setItem(
            `delivery-calendar-anchor:${uid}`,
            JSON.stringify({ date: startIso, savedAt: Date.now() })
          );
        }
      } catch {
        // storage unavailable — fine
      }
    } catch {
      if (seq !== loadSeq.current) return;
      setError("We couldn't load the delivery calendar. Please try again.");
      setCalendar(null);
    } finally {
      if (seq === loadSeq.current) setLoading(false);
    }
  }, []);

  useEffect(() => {
    const supabase = createClient();
    supabase.auth.getSession().then(async ({ data: { session } }) => {
      if (!session?.user) {
        router.push("/login");
        return;
      }
      userIdRef.current = session.user.id;
      try {
        // Remove the pre-per-user key — no longer read.
        window.localStorage.removeItem("delivery-calendar-anchor");
      } catch {
        // storage unavailable — fine
      }
      // "Today" comes from the business timezone; the browser clock is
      // only a fallback. Both it and the week-start setting are fetched
      // before the first calendar call so there's no flash of the wrong
      // window.
      const [today, wkStart] = await Promise.all([
        fetchDeliveryBusinessToday(),
        fetchCompanyWeekStart(),
      ]);
      const businessToday = today ?? toISODay(new Date());
      setTodayIso(businessToday);
      const startDay = (wkStart === 7 ? 7 : 1) as 1 | 7; // null -> Monday
      weekStartDayRef.current = startDay;
      setWeekStartDay(startDay);
      // View mode is per user; default is the rolling "Next 7 days".
      let mode: ViewMode = "rolling";
      try {
        const savedMode = window.localStorage.getItem(
          `delivery-calendar-mode:${session.user.id}`
        );
        if (savedMode === "week" || savedMode === "rolling") mode = savedMode;
      } catch {
        // storage unavailable or unreadable — default rolling
      }
      viewModeRef.current = mode;
      setViewMode(mode);
      let start: string;
      if (mode === "week") {
        // Reopen on the week this user was last viewing in this mode;
        // fall back to today. Keyed per user (shared store computers)
        // and ignored when older than 14 days.
        let anchorDate = businessToday;
        try {
          const saved = window.localStorage.getItem(
            `delivery-calendar-anchor:${session.user.id}`
          );
          if (saved) {
            const { date, savedAt } = JSON.parse(saved) as {
              date?: string;
              savedAt?: number;
            };
            const fresh =
              typeof savedAt === "number" &&
              Date.now() - savedAt < 14 * 24 * 3600 * 1000;
            if (fresh && date && /^\d{4}-\d{2}-\d{2}$/.test(date)) {
              anchorDate = date;
            }
          }
        } catch {
          // storage unavailable or unreadable value — use today
        }
        start = weekStartOf(anchorDate, startDay);
      } else {
        // Rolling mode always opens on today.
        start = businessToday;
      }
      viewStartRef.current = start;
      setViewStart(start);
      const [cal, canManageTrucksPerm, canManageCalendarPerm] = await Promise.all([
        fetchDeliveryCalendar(start, addDays(start, 6)).catch(() => null),
        fetchDeliveryManageTrucks(),
        fetchDeliveryManageCalendar(),
      ]);
      if (cal === null) {
        setError("We couldn't load the delivery calendar. Please try again.");
      } else {
        setCalendar(cal);
      }
      setCanManageTrucks(canManageTrucksPerm);
      setCanManageCalendar(canManageCalendarPerm);
      setLoading(false);
    });
  }, [router]);

  // Navigation is instant in state and debounced for the fetch: every
  // arrow/Today/mode click counts even while a request is in flight,
  // and loadSeq makes sure only the latest window's data can paint.
  const navTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const goTo = (startIso: string) => {
    viewStartRef.current = startIso;
    setViewStart(startIso);
    setLoading(true);
    setError(null);
    if (navTimer.current) clearTimeout(navTimer.current);
    navTimer.current = setTimeout(() => {
      navTimer.current = null;
      const current = viewStartRef.current;
      if (current) load(current);
    }, 150);
  };

  // Switching modes re-anchors: Calendar week snaps to the week
  // containing the currently visible first day; rolling jumps back to
  // today. The mode itself is remembered per user.
  const switchMode = (mode: ViewMode) => {
    if (mode === viewModeRef.current) return;
    viewModeRef.current = mode;
    setViewMode(mode);
    try {
      const uid = userIdRef.current;
      if (uid) {
        window.localStorage.setItem(
          `delivery-calendar-mode:${uid}`,
          mode
        );
      }
    } catch {
      // storage unavailable — fine
    }
    const current = viewStartRef.current;
    if (!current) return;
    const target =
      mode === "week"
        ? weekStartOf(current, weekStartDayRef.current)
        : (todayIso ?? current);
    if (target !== current) goTo(target);
  };

  const goToday = () => {
    const t = todayIso ?? toISODay(new Date());
    goTo(viewModeRef.current === "week"
      ? weekStartOf(t, weekStartDayRef.current)
      : t);
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
      const current = viewStartRef.current;
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

  // +/- extra slots for one day. Sends the new ABSOLUTE value; refetches
  // whatever week is on screen now so a mid-save week change can't paint
  // stale data onto the wrong week.
  const adjustDay = async (iso: string, newExtra: number) => {
    if (!canManageCalendar) return;
    if (savingDays.has(iso)) return;
    setCellError(null);
    setSavingDays((prev) => new Set(prev).add(iso));
    try {
      await setDayExtraSlots(iso, newExtra);
      const current = viewStartRef.current;
      if (current) await load(current);
    } catch {
      setCellError("Couldn't update that day. Please try again.");
    } finally {
      setSavingDays((prev) => {
        const next = new Set(prev);
        next.delete(iso);
        return next;
      });
    }
  };

  const days: string[] = viewStart
    ? Array.from({ length: 7 }, (_, i) => addDays(viewStart, i))
    : [];
  const dayByDate = new Map<string, DeliveryCalendarDay>(
    (calendar?.days ?? []).map((d) => [d.date, d])
  );
  const trucks = calendar?.trucks ?? [];
  const weekEnd = days[days.length - 1] ?? "";
  const tomorrowIso = todayIso ? addDays(todayIso, 1) : null;

  return (
    <div className="mx-auto max-w-6xl px-4 py-6">
      <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-xl font-semibold text-slate-900">Delivery</h1>
        <div className="flex w-full flex-wrap items-center gap-2 sm:w-auto">
          <div
            className="flex rounded-md border border-slate-300 text-sm"
            role="group"
            aria-label="Calendar view"
          >
            {(
              [
                ["rolling", "Next 7 days"],
                ["week", "Calendar week"],
              ] as [ViewMode, string][]
            ).map(([mode, label]) => (
              <button
                key={mode}
                type="button"
                onClick={() => switchMode(mode)}
                aria-pressed={viewMode === mode}
                className={`whitespace-nowrap px-3 py-1.5 ${
                  viewMode === mode
                    ? "bg-slate-900 font-medium text-white"
                    : "text-slate-600 hover:bg-slate-50"
                } ${mode === "rolling" ? "rounded-l-md" : "rounded-r-md border-l border-slate-300"}`}
              >
                {label}
              </button>
            ))}
          </div>
          <button
            onClick={() => viewStart && goTo(addDays(viewStart, -7))}
            disabled={!viewStart}
            className="rounded-md border border-slate-300 p-1.5 text-slate-600 hover:bg-slate-50 disabled:opacity-40"
            aria-label="Previous week"
          >
            <ChevronLeft className="h-4 w-4" />
          </button>
          <button
            onClick={goToday}
            disabled={!viewStart}
            className="rounded-md border border-slate-300 px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50 disabled:opacity-40"
          >
            Today
          </button>
          <button
            onClick={() => viewStart && goTo(addDays(viewStart, 7))}
            disabled={!viewStart}
            className="rounded-md border border-slate-300 p-1.5 text-slate-600 hover:bg-slate-50 disabled:opacity-40"
            aria-label="Next week"
          >
            <ChevronRight className="h-4 w-4" />
          </button>
          <span className="ml-2 whitespace-nowrap text-sm font-medium text-slate-700">
            {viewStart ? rangeLabel(viewStart, weekEnd) : ""}
          </span>
          {canManageTrucks && (
            <button
              type="button"
              onClick={() => {
                setPanelAddMode(false);
                setPanelOpen(true);
              }}
              className="ml-3 inline-flex items-center gap-1.5 whitespace-nowrap rounded-md border border-slate-300 px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50"
            >
              <Truck className="h-4 w-4" />
              Manage trucks
            </button>
          )}
        </div>
      </div>

      {loading && (
        <p className="py-10 text-center text-sm text-slate-500">Loading…</p>
      )}

      {!loading && error && (
        <div className="rounded-lg border border-red-200 bg-red-50 px-4 py-6 text-center">
          <p className="text-sm text-red-700">{error}</p>
          {viewStart && (
            <button
              onClick={() => load(viewStart)}
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
              onClick={() => {
                setPanelAddMode(true);
                setPanelOpen(true);
              }}
              className="mt-4 rounded-md bg-slate-900 px-4 py-2 text-sm font-medium text-white"
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
                  const isToday = todayIso !== null && iso === todayIso;
                  const isPast = todayIso !== null && iso < todayIso;
                  // "Today"/"Tomorrow" are earned by the actual date,
                  // not the column position — a past or future window
                  // must never claim them.
                  const topLabel = isToday
                    ? "Today"
                    : viewMode === "rolling" &&
                        tomorrowIso !== null &&
                        iso === tomorrowIso
                      ? "Tomorrow"
                      : l.weekday;
                  const open = d
                    ? Math.max(0, d.capacity - d.booked_count)
                    : 0;
                  const availLabel = !d
                    ? ""
                    : d.capacity === 0
                      ? "Closed"
                      : open === 0
                        ? "Full"
                        : `${open} open`;
                  return (
                    <th
                      key={iso}
                      aria-current={isToday ? "date" : undefined}
                      className={`border border-slate-200 px-3 py-2 text-center font-medium text-slate-700 ${
                        isToday ? "bg-amber-100" : isPast ? "bg-slate-100 opacity-60" : ""
                      }`}
                    >
                      <div className={isToday ? "font-semibold text-amber-900" : ""}>
                        {topLabel}
                      </div>
                      <div className="text-xs font-normal text-slate-500">
                        {l.month} {l.dayNum}
                      </div>
                      {d && (
                        <div className="mt-0.5 space-y-0.5">
                          <div className="text-xs font-normal text-slate-500">
                            {availLabel}
                          </div>
                          {/* Reserved line — keeps the +/- controls
                              aligned whether or not anything is booked. */}
                          <div className="text-[11px] font-normal text-slate-400">
                            {d.booked_count > 0
                              ? `${d.booked_count} booked`
                              : "\u00a0"}
                          </div>
                          {canManageCalendar && (
                            <div className="text-[11px] font-normal text-slate-400">
                              {d.extra_slots !== 0
                                ? `includes ${d.extra_slots > 0 ? "+" : ""}${d.extra_slots} extra`
                                : "\u00a0"}
                            </div>
                          )}
                          {!canManageCalendar && d.extra_slots !== 0 && (
                            <div className="text-[11px] font-normal text-slate-400">
                              includes {d.extra_slots > 0 ? "+" : ""}
                              {d.extra_slots} extra
                            </div>
                          )}
                          {canManageCalendar && (
                            <div className="flex items-center justify-center gap-1 pt-0.5">
                              <button
                                type="button"
                                disabled={savingDays.has(iso) || d.capacity <= 0}
                                onClick={() => adjustDay(iso, d.extra_slots - 1)}
                                title="Remove one delivery spot for this day"
                                className="flex h-6 w-6 items-center justify-center rounded border border-slate-300 text-xs text-slate-600 hover:bg-slate-100 disabled:cursor-not-allowed disabled:opacity-40"
                              >
                                −
                              </button>
                              <span className="w-7 text-center text-[11px] text-slate-500">
                                {d.extra_slots > 0 ? "+" : ""}
                                {d.extra_slots}
                              </span>
                              <button
                                type="button"
                                disabled={savingDays.has(iso)}
                                onClick={() => adjustDay(iso, d.extra_slots + 1)}
                                title="Add one delivery spot for this day"
                                className="flex h-6 w-6 items-center justify-center rounded border border-slate-300 text-xs text-slate-600 hover:bg-slate-100 disabled:cursor-not-allowed disabled:opacity-40"
                              >
                                +
                              </button>
                            </div>
                          )}
                        </div>
                      )}
                      {d && d.booked_count > 0 && (
                        <div className="pt-0.5">
                          <Link
                            href={`/delivery/day?date=${iso}`}
                            className="text-[11px] font-medium text-blue-700 hover:underline"
                          >
                            Plan day
                          </Link>
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
                  </td>
                  {days.map((iso) => (
                    <Cell
                      key={iso}
                      truck={truck}
                      iso={iso}
                      day={dayByDate.get(iso)}
                      canManage={canManageTrucks}
                      saving={savingCells.has(`${truck.id}|${iso}`)}
                      highlight={todayIso !== null && iso === todayIso}
                      dimmed={todayIso !== null && iso < todayIso}
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
            {!canManageTrucks && !canManageCalendar &&
              " You don't have permission to change the delivery calendar. Ask an admin if you need it."}
          </p>
        </div>
      )}

      {panelOpen && canManageTrucks && (
        <TrucksPanel
          trucks={trucks}
          archivedTrucks={calendar?.archived_trucks ?? []}
          weekStartDay={weekStartDay}
          startInAddMode={panelAddMode}
          onClose={() => setPanelOpen(false)}
          onChanged={() => {
            const current = viewStartRef.current;
            if (current) load(current);
          }}
        />
      )}
    </div>
  );
}
